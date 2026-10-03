defmodule Badge.Page.Raycaster do
  @moduledoc """
  A Wolfenstein-style 3D view of a small map, drawn by `Raycaster.Engine`, with an evil goat
  in it.

  Arrows or W A S D move and turn, Q and E strafe, Esc leaves. The keys are read as held
  rather than tapped, with `Badge.Keyboard.held/0` on every tick: key events only arrive
  on press and auto-repeat, which is no way to walk.

  The goat, `Raycaster.Goat`, runs on the badge, so there is nothing to connect to. It wanders
  until it sees you, hunts you while you are in sight, and is faster the longer this life has
  lasted. When it catches you the page shows `Raycaster.GameOver` until a key is pressed, and
  starts again at whichever of two places is farther from the goat, safe from it for a few
  seconds. The four LEDs warn of the goat before it is seen, see `Raycaster.Omen`, and are the
  badge's own LED mode again when it is far off and on leaving. The line at the bottom says how
  long this life has lasted.

  A frame is about 60 to 110 ms of ray casting, so the page asks for the shortest gap the ticker
  offers and lives with about 10 frames a second. The goat is stepped by the time since the
  last tick, so it keeps its speed whatever the frame rate.

  The map is fetched with `Raycaster.Engine.grid/0` once per call and never kept in the
  state: AtomVM copies a module literal onto the heap each time it is looked up, so the
  lookup must not be in a per-ray loop, and a term that size does not belong in the state
  `Badge.UI` holds either.
  """

  use Badge.Page

  alias Badge.Keyboard
  alias Badge.Pixels
  alias Badge.Theme
  alias Raycaster.Engine
  alias Raycaster.GameOver
  alias Raycaster.Goat
  alias Raycaster.Omen

  # The view fills what is under the title bar.
  @view_w Theme.width()
  @view_h Theme.height() - Theme.content_top()

  # The most one step may move, so a long stall does not fling the player through a wall
  # in a single go. The engine's own clamp is per axis.
  @max_dt 250

  # Farther than this (squared, in the engine's fixed point: ten cells) the goat is not drawn
  # in any way that is worth a repaint.
  @near 10 * 256 * (10 * 256)

  # The goat starts in the cell farthest from where the player does, by walking.
  @goat_start {14, 14}

  # How long the game over screen stays whatever is pressed, so a key held while running
  # from the goat does not skip it.
  @over_ms 1_500

  # After a catch the player is safe from the goat for this long, and the same at the start.
  @grace_ms 3_000

  # The goat goes faster once a life has lasted this long.
  @fast_after_ms 30_000
  @faster_after_ms 60_000

  @impl true
  def title, do: "Goat game"

  @impl true
  def icon, do: :clover

  @impl true
  def refresh(_state), do: 100

  # `at` is when the player last moved, or nil while standing still. `goat` is the goat's
  # own state and `goat_at` when it was last stepped. `born` is when this life began and
  # `safe_until` when the goat may hunt again. `caught` is nil, or `{when, seconds lasted}`
  # while the game over screen is up, and `dread` how much the LEDs say to dread the goat.
  @impl true
  def init do
    now = now()

    %{
      player: Engine.new(),
      at: nil,
      goat: Goat.new(@goat_start, now),
      goat_at: now,
      born: now,
      safe_until: now + @grace_ms,
      caught: nil,
      dread: 0,
      secs: 0
    }
  end

  # The goat moves every tick, but it only changes the picture when it is near enough to be
  # in it. Without this a standing player would be repainted ten times a second for a goat
  # on the other side of the map.
  @impl true
  def changed?(old, new) do
    old.caught != new.caught or old.player != new.player or old.secs != new.secs or
      goat_shows?(old, new)
  end

  defp goat_shows?(%{goat: old}, %{goat: new, player: %{x: px, y: py}}) do
    {gx, gy, hunting} = Goat.where(new)
    dx = gx - px
    dy = gy - py

    dx * dx + dy * dy <= @near and Goat.where(old) != {gx, gy, hunting}
  end

  @impl true
  def tick(state) do
    now = now()

    case state.caught do
      nil -> state |> walk(now) |> chase(now) |> count(now) |> feel()
      caught -> state |> revive(caught, now) |> feel()
    end
  end

  @impl true
  def leave(_state), do: Pixels.pattern_off()

  @impl true
  def render(%{caught: {_when, lasted}}) do
    scene = GameOver.items(Engine.grid(), lasted, @view_w, @view_h)

    shift(scene, Theme.content_top(), [])
  end

  def render(%{player: player, goat: goat, secs: secs}) do
    grid = Engine.grid()
    figures = Engine.sprites(grid, player, [goat_figure(goat)], @view_w, @view_h)
    walls = Engine.frame(grid, player, @view_w, @view_h)
    scene = shift(:lists.append(figures, walls), Theme.content_top(), [])

    [alive(secs) | scene]
  end

  defp goat_figure(goat) do
    {x, y, hunting} = Goat.where(goat)
    {:goat, x, y, hunting, Goat.in_sight?(goat)}
  end

  defp walk(%{player: player, at: at} = state, now) do
    case Keyboard.held() do
      [] ->
        %{state | at: nil}

      held ->
        dt = if at == nil, do: 100, else: min(now - at, @max_dt)

        %{state | player: Engine.step(Engine.grid(), player, held, dt), at: now}
    end
  end

  # The goat moves by the time since it last did, and a catch ends the life.
  defp chase(%{goat: goat, goat_at: goat_at, player: player, born: born} = state, now) do
    dt = min(now - goat_at, @max_dt)
    prey = if now >= state.safe_until, do: {player.x, player.y}

    {goat, caught} = Goat.step(goat, Engine.grid(), prey, dt, now, pace(now - born))
    state = %{state | goat: goat, goat_at: now}

    if caught, do: %{state | caught: {now, div(now - born, 1000)}}, else: state
  end

  # The whole seconds this life has lasted, kept in the state so that the picture only changes
  # when the number does.
  defp count(%{born: born, caught: nil} = state, now), do: %{state | secs: div(now - born, 1000)}
  defp count(state, _now), do: state

  defp pace(lasted) when lasted >= @faster_after_ms, do: :faster
  defp pace(lasted) when lasted >= @fast_after_ms, do: :fast
  defp pace(_lasted), do: :calm

  # After the game over screen a key press brings the player back, once the screen has been
  # up for a while: where the goat is not, and safe from it for a few seconds.
  defp revive(%{goat: goat} = state, {since, _lasted}, now) do
    if now - since >= @over_ms and Keyboard.held() != [] do
      %{
        state
        | player: Engine.respawn(Goat.where(goat)),
          at: nil,
          goat_at: now,
          born: now,
          safe_until: now + @grace_ms,
          caught: nil
      }
    else
      state
    end
  end

  # The LEDs say how near the goat is, and are told only when that changes. Level 0 gives them
  # back to the LED mode the badge is set to.
  defp feel(%{dread: level} = state) do
    new =
      if state.caught == nil, do: Omen.level(state.player, Goat.where(state.goat)), else: :caught

    if new == level do
      state
    else
      light(new)
      %{state | dread: new}
    end
  end

  defp light(0), do: Pixels.pattern_off()

  defp light(level) do
    {ms, frames} = Omen.pattern(level)
    Pixels.pattern(ms, frames)
  end

  defp alive(secs), do: line("alive " <> :erlang.integer_to_binary(secs) <> " s")

  defp line(text), do: {:text, 4, Theme.height() - 18, :default16px, Theme.fg(), Theme.bg(), text}

  # The engine draws from y = 0; the title bar takes the top of the panel.
  defp shift([], _top, acc), do: :lists.reverse(acc)

  defp shift([{:rect, x, y, w, h, colour} | rest], top, acc) do
    shift(rest, top, [{:rect, x, y + top, w, h, colour} | acc])
  end

  defp shift([{:text, x, y, font, fg, bg, text} | rest], top, acc) do
    shift(rest, top, [{:text, x, y + top, font, fg, bg, text} | acc])
  end

  defp now, do: :erlang.monotonic_time(:millisecond)
end
