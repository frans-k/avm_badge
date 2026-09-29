defmodule Badge.Page.Raycaster do
  @moduledoc """
  A Wolfenstein-style 3D view of a small map, drawn by `Raycaster.Engine`, with the other
  badges walking around in it.

  Arrows or W A S D move and turn, Q and E strafe, Esc leaves. The keys are read as held
  rather than tapped, with `Badge.Keyboard.held/0` on every tick: key events only arrive
  on press and auto-repeat, which is no way to walk.

  Every badge that has this page open tells a relay server where it stands once a second,
  see `Badge.Raycaster.Link`, and is told where the others are: they are drawn as coloured
  figures. The line at the bottom says whether the link is up and how many are playing.
  Without wifi it is a room to walk around in on your own.

  The map is fetched with `Raycaster.Engine.grid/0` once per call and never kept in the
  state: AtomVM copies a module literal onto the heap each time it is looked up, so the
  lookup must not be in a per-ray loop, and a term that size does not belong in the state
  `Badge.UI` holds either.
  """

  use Badge.Page

  alias Badge.Keyboard
  alias Badge.Raycaster.Link
  alias Badge.Theme
  alias Raycaster.Engine

  # The view fills what is under the title bar.
  @view_w Theme.width()
  @view_h Theme.height() - Theme.content_top()

  # The most one step may move, so a long stall does not fling the player through a wall
  # in a single go. The engine's own clamp is per axis.
  @max_dt 250

  # How often to say where we are. The relay hands out one snapshot a second and forgets
  # a badge that is quiet for five seconds.
  @announce_ms 1_000

  @impl true
  def title, do: "Raycaster"

  @impl true
  def icon, do: :clover

  @impl true
  def refresh(_state), do: 100

  # `at` is when the player last moved, or nil while standing still. `others` is what the
  # relay last said, ready for the engine. `sent` is when we last said where we are.
  @impl true
  def init, do: %{player: Engine.new(), at: nil, others: [], link: :off, sent: nil}

  @impl true
  def tick(state) do
    Link.open()
    now = now()

    state
    |> walk(now)
    |> tell(now)
  end

  @impl true
  def handle_info({:raycaster, :up}, state), do: {:ok, %{state | link: :up, sent: nil}}
  def handle_info({:raycaster, :down}, state), do: {:ok, %{state | link: :off, others: []}}
  def handle_info({:raycaster, {:players, others}}, state), do: {:ok, %{state | others: others}}
  def handle_info(_message, _state), do: :ignore

  @impl true
  def leave(_state), do: Link.close()

  @impl true
  def render(%{player: player, others: others, link: link}) do
    grid = Engine.grid()
    figures = Engine.sprites(grid, player, others, @view_w, @view_h)
    walls = Engine.frame(grid, player, @view_w, @view_h)
    scene = shift(:lists.append(figures, walls), Theme.content_top(), [])

    [status(link, length(others)) | scene]
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

  defp tell(%{link: :up, sent: sent, player: player} = state, now) do
    if sent == nil or now - sent >= @announce_ms do
      Link.publish(player.x, player.y)
      %{state | sent: now}
    else
      state
    end
  end

  defp tell(state, _now), do: state

  defp status(:off, _others), do: line("offline")

  defp status(:up, others),
    do: line("online, " <> :erlang.integer_to_binary(others + 1) <> " playing")

  defp line(text), do: {:text, 4, Theme.height() - 18, :default16px, Theme.fg(), Theme.bg(), text}

  # The engine draws from y = 0; the title bar takes the top of the panel.
  defp shift([], _top, acc), do: :lists.reverse(acc)

  defp shift([{:rect, x, y, w, h, colour} | rest], top, acc) do
    shift(rest, top, [{:rect, x, y + top, w, h, colour} | acc])
  end

  defp now, do: :erlang.monotonic_time(:millisecond)
end
