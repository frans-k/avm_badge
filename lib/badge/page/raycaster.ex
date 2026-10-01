defmodule Badge.Page.Raycaster do
  @moduledoc """
  A Wolfenstein-style 3D view of a small map, drawn by `Raycaster.Engine`, with the other
  badges walking around in it.

  Arrows or W A S D move and turn, Q and E strafe, Esc leaves. The keys are read as held
  rather than tapped, with `Badge.Keyboard.held/0` on every tick: key events only arrive
  on press and auto-repeat, which is no way to walk.

  Every badge that has this page open tells a relay server where it stands twice a second,
  see `Badge.Raycaster.Link`, and is told where the others are: they are drawn as coloured
  figures. The line at the bottom says whether the link is up, how many are playing and how
  long this life has lasted. Without wifi it is a room to walk around in on your own.

  The relay also has an evil goat in every room, which hunts the players. When it catches
  this badge the page shows `Raycaster.GameOver` until a key is pressed, tells the relay
  the badge is back and starts again where the goat is farthest. The four LEDs warn
  of the goat before it is seen, see `Raycaster.Omen`, and are the badge's own LED mode again
  when it is far off and on leaving.

  The map is fetched with `Raycaster.Engine.grid/0` once per call and never kept in the
  state: AtomVM copies a module literal onto the heap each time it is looked up, so the
  lookup must not be in a per-ray loop, and a term that size does not belong in the state
  `Badge.UI` holds either.
  """

  use Badge.Page

  alias Badge.Keyboard
  alias Badge.Pixels
  alias Badge.Raycaster.Link
  alias Badge.Theme
  alias Raycaster.Engine
  alias Raycaster.GameOver
  alias Raycaster.Omen

  # The view fills what is under the title bar.
  @view_w Theme.width()
  @view_h Theme.height() - Theme.content_top()

  # The most one step may move, so a long stall does not fling the player through a wall
  # in a single go. The engine's own clamp is per axis.
  @max_dt 250

  # How often to say where we are. The relay hands out one snapshot a second and forgets
  # a badge that is quiet for five seconds, but its goat judges a catch on the last
  # position it heard, so twice a second keeps that fairer.
  @announce_ms 500

  # How long the game over screen stays whatever is pressed, so a key held while running
  # from the goat does not skip it.
  @over_ms 1_500

  @impl true
  def title, do: "Goat game"

  @impl true
  def icon, do: :clover

  @impl true
  def refresh(_state), do: 100

  # `at` is when the player last moved, or nil while standing still. `others` is what the
  # relay last said, ready for the engine, and `goat` is where it says the goat is, or
  # nil. `sent` is when we last said where we are, `born` when this life began, and
  # `caught` is nil, or `{when, seconds lasted}` while the game over screen is up.
  @impl true
  def init do
    %{
      player: Engine.new(),
      at: nil,
      others: [],
      goat: nil,
      link: :off,
      sent: nil,
      born: now(),
      caught: nil,
      dread: 0
    }
  end

  @impl true
  def tick(state) do
    Link.open()
    now = now()

    case state.caught do
      nil -> state |> walk(now) |> tell(now) |> feel()
      caught -> state |> revive(caught, now) |> feel()
    end
  end

  @impl true
  def handle_info({:raycaster, :up}, state), do: {:ok, %{state | link: :up, sent: nil}}

  def handle_info({:raycaster, :down}, state),
    do: {:ok, %{state | link: :off, others: [], goat: nil}}

  def handle_info({:raycaster, {:players, others, goat}}, state),
    do: {:ok, %{state | others: others, goat: goat}}

  def handle_info({:raycaster, :caught}, %{caught: nil, born: born} = state) do
    now = now()
    {:ok, %{state | caught: {now, div(now - born, 1000)}}}
  end

  def handle_info(_message, _state), do: :ignore

  @impl true
  def leave(_state) do
    Pixels.pattern_off()
    Link.close()
  end

  @impl true
  def render(%{caught: {_when, lasted}}) do
    scene = GameOver.items(Engine.grid(), lasted, @view_w, @view_h)

    shift(scene, Theme.content_top(), [])
  end

  def render(%{player: player, others: others, goat: goat, link: link, born: born}) do
    grid = Engine.grid()
    figures = Engine.sprites(grid, player, goat(goat, others), @view_w, @view_h)
    walls = Engine.frame(grid, player, @view_w, @view_h)
    scene = shift(:lists.append(figures, walls), Theme.content_top(), [])

    [status(link, length(others), goat, born) | scene]
  end

  defp goat(nil, others), do: others
  defp goat({x, y, hunting}, others), do: [{:goat, x, y, hunting} | others]

  defp walk(%{player: player, at: at} = state, now) do
    case Keyboard.held() do
      [] ->
        %{state | at: nil}

      held ->
        dt = if at == nil, do: 100, else: min(now - at, @max_dt)

        %{state | player: Engine.step(Engine.grid(), player, held, dt), at: now}
    end
  end

  defp tell(%{link: :up, sent: sent, player: player} = state, now) do
    if sent == nil or now - sent >= @announce_ms do
      Link.publish(player.x, player.y)
      %{state | sent: now}
    else
      state
    end
  end

  defp tell(state, _now), do: state

  # After the game over screen a key press brings the badge back, once the screen has
  # been up for a while. The relay is told, and the badge starts again where the goat is
  # not.
  defp revive(%{goat: goat} = state, {since, _lasted}, now) do
    if now - since >= @over_ms and Keyboard.held() != [] do
      Link.respawn()

      %{state | player: Engine.respawn(goat), at: nil, sent: nil, born: now, caught: nil}
    else
      state
    end
  end

  # The LEDs say how near the goat is, and are told only when that changes. Level 0 gives them
  # back to the LED mode the badge is set to.
  defp feel(%{dread: level} = state) do
    new = if state.caught == nil, do: Omen.level(state.player, state.goat), else: :caught

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

  defp status(:off, _others, _goat, _born), do: line("offline")

  defp status(:up, others, nil, _born),
    do: line("online, " <> :erlang.integer_to_binary(others + 1) <> " playing")

  defp status(:up, others, _goat, born) do
    line(
      "online, " <>
        :erlang.integer_to_binary(others + 1) <>
        " playing, alive " <> :erlang.integer_to_binary(div(now() - born, 1000)) <> " s"
    )
  end

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
