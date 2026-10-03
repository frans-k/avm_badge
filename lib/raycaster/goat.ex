defmodule Raycaster.Goat do
  @moduledoc """
  The evil goat, run on the badge: it wanders the map, and hunts the player once it sees them.

  It wanders from one random open cell to another until it sees the player, then goes straight
  at them while they are in sight, faster than it wanders but slower than the player walks
  (800), so running away works. It has three paces, `:calm`, then `:fast` and `:faster`, which
  the page asks for as the player lasts longer. When it loses sight of them it goes to where it
  last saw them and searches there for a few seconds before wandering again. Nearer than half a
  cell is a catch.

  It sees through open floor only, with the walk the engine uses to hide figures, so it sees
  the player exactly when they would see it. Positions are the engine's fixed point, 256 to a
  cell, kept as floats here.

  Pure, so it is checked on the laptop, and written for AtomVM: `:lists` and `:maps`, plain
  recursion, a small random number generator of its own, and the grid handed in as an argument
  (see `Raycaster.Engine.grid/0`). The way round a wall is the shortest through the cells, found
  by a breadth-first search from the goal that is kept until the goal moves to another cell.
  """

  import Bitwise

  alias Raycaster.Engine

  # Wandering and hunting, in the fixed point per second, by pace.
  @calm {250, 330}
  @fast {350, 450}
  @faster {400, 520}
  # How far it sees: eight cells.
  @sight 2_048
  @reach 128
  @search_ms 4_000

  @doc "A goat in the middle of `cell`, wandering. The seed makes its wandering repeatable."
  def new({cx, cy}, seed) do
    %{
      x: (cx * 256 + 128) * 1.0,
      y: (cy * 256 + 128) * 1.0,
      mode: :wander,
      goal: nil,
      lost_at: nil,
      seed: rem(abs(seed), 65_537),
      # `{goal cell, steps from it to every cell}`, for the way round walls.
      route: nil
    }
  end

  @doc "Where it stands, in whole numbers, and whether it is after the player."
  def where(%{x: x, y: y, mode: mode}), do: {round(x), round(y), mode != :wander}

  @doc """
  Moves the goat on by `dt_ms` at `now`, at `pace` (`:calm`, `:fast` or `:faster`). `prey` is
  where the player stands, `{x, y}`, or nil when it may not be hunted. Returns the goat and
  whether it has caught them.
  """
  def step(goat, grid, prey, dt_ms, now, pace) do
    {wander, hunt} = speeds(pace)
    goat = goat |> look(grid, prey, now) |> move(grid, dt_ms, wander, hunt)
    {goat, caught?(goat, prey)}
  end

  defp caught?(_goat, nil), do: false
  defp caught?(goat, {px, py}), do: distance(goat, px, py) < @reach

  defp speeds(:faster), do: @faster
  defp speeds(:fast), do: @fast
  defp speeds(_calm), do: @calm

  # Decides what it is doing: keeps after the player while it sees them, else searches where
  # it lost them, and then wanders.
  defp look(goat, grid, prey, now) do
    case sees(goat, grid, prey) do
      {px, py} ->
        %{goat | mode: :hunt, goal: {px, py}, lost_at: nil}

      nil ->
        case goat.mode do
          :hunt ->
            %{goat | mode: :search, lost_at: now}

          :search when now - goat.lost_at >= @search_ms ->
            %{goat | mode: :wander, goal: nil, lost_at: nil}

          _other ->
            goat
        end
    end
  end

  defp sees(_goat, _grid, nil), do: nil

  defp sees(goat, grid, {px, py}) do
    if distance(goat, px, py) <= @sight and
         Engine.visible?(grid, trunc(goat.x), trunc(goat.y), px, py),
       do: {px, py},
       else: nil
  end

  defp move(%{mode: :hunt, goal: {gx, gy}} = goat, grid, dt_ms, _wander, hunt) do
    step = hunt * dt_ms / 1000
    {x, y} = towards(goat.x, goat.y, gx, gy, step)

    # Straight at them, unless that clips a corner: then round it.
    if Engine.open?(grid, trunc(x), trunc(y)),
      do: %{goat | x: x, y: y},
      else: route(goat, grid, goat.goal, step)
  end

  defp move(%{mode: :search} = goat, grid, dt_ms, _wander, hunt),
    do: route(goat, grid, goat.goal, hunt * dt_ms / 1000)

  defp move(%{mode: :wander} = goat, grid, dt_ms, wander, _hunt) do
    goat = if arrived?(goat), do: wander_to(goat, grid), else: goat
    route(goat, grid, goat.goal, wander * dt_ms / 1000)
  end

  defp arrived?(%{goal: nil}), do: true
  defp arrived?(%{goal: {gx, gy}} = goat), do: distance(goat, gx, gy) < 1

  # Somewhere open to go next: a cell tried at random until it is floor, which most are.
  defp wander_to(goat, grid) do
    {cx, seed} = pick(goat.seed)
    {cy, seed} = pick(seed)

    if Engine.open_cell?(grid, cx, cy),
      do: %{goat | goal: {cx * 256 + 128, cy * 256 + 128}, seed: seed},
      else: wander_to(%{goat | seed: seed}, grid)
  end

  # A cell from 1 to 14, the map's ring being wall, and the next seed. A small linear
  # congruential generator, so no big integers and no :rand.
  defp pick(seed) do
    seed = rem(seed * 75 + 74, 65_537)
    {1 + rem(div(seed, 3), 14), seed}
  end

  # Along the shortest way through the cells, a cell's middle at a time; in the goal's own cell,
  # straight to it. Moving between the middles of neighbouring open cells never touches a wall.
  defp route(goat, grid, {gx, gy}, step) do
    here = {trunc(goat.x) >>> 8, trunc(goat.y) >>> 8}
    {goat, next} = next_cell(goat, grid, here, {gx >>> 8, gy >>> 8})

    {tx, ty} =
      case next do
        nil -> {gx, gy}
        {cx, cy} -> {cx * 256 + 128, cy * 256 + 128}
      end

    {x, y} = towards(goat.x, goat.y, tx, ty, step)
    if Engine.open?(grid, trunc(x), trunc(y)), do: %{goat | x: x, y: y}, else: goat
  end

  defp towards(x, y, tx, ty, step) do
    dx = tx - x
    dy = ty - y
    length = :math.sqrt(dx * dx + dy * dy)

    if length <= step,
      do: {tx * 1.0, ty * 1.0},
      else: {x + dx * step / length, y + dy * step / length}
  end

  defp distance(goat, x, y) do
    dx = goat.x - x
    dy = goat.y - y
    :math.sqrt(dx * dx + dy * dy)
  end

  @doc false
  # The next cell on a shortest way from `from` to `to`, moving across cell sides only, or
  # nil when `from` is `to` or there is no way; and the goat, with the search kept for the
  # next step toward the same cell.
  def next_cell(goat, _grid, to, to), do: {goat, nil}

  def next_cell(goat, grid, from, to) do
    {goat, steps} = distances(goat, grid, to)

    case :maps.find(from, steps) do
      :error -> {goat, nil}
      {:ok, _reachable} -> {goat, nearest(neighbours(from), steps, nil, :infinity)}
    end
  end

  # Searched from the goal, so the first step is the neighbour of `from` nearest to it.
  defp distances(%{route: {to, steps}} = goat, _grid, to), do: {goat, steps}

  defp distances(goat, grid, to) do
    steps = bfs(grid, [to], :maps.put(to, 0, %{}), 0)
    {%{goat | route: {to, steps}}, steps}
  end

  defp nearest([], _steps, best, _best_steps), do: best

  defp nearest([cell | rest], steps, best, best_steps) do
    case :maps.find(cell, steps) do
      {:ok, n} when best_steps == :infinity or n < best_steps ->
        nearest(rest, steps, cell, n)

      _no_better ->
        nearest(rest, steps, best, best_steps)
    end
  end

  defp neighbours({cx, cy}), do: [{cx + 1, cy}, {cx - 1, cy}, {cx, cy + 1}, {cx, cy - 1}]

  defp bfs(_grid, [], seen, _steps), do: seen

  defp bfs(grid, frontier, seen, steps) do
    {next, seen} = expand(grid, frontier, seen, steps + 1, [])
    bfs(grid, next, seen, steps + 1)
  end

  defp expand(_grid, [], seen, _steps, acc), do: {acc, seen}

  defp expand(grid, [cell | rest], seen, steps, acc) do
    {acc, seen} = visit(grid, neighbours(cell), seen, steps, acc)
    expand(grid, rest, seen, steps, acc)
  end

  defp visit(_grid, [], seen, _steps, acc), do: {acc, seen}

  defp visit(grid, [{cx, cy} = cell | rest], seen, steps, acc) do
    if Engine.open_cell?(grid, cx, cy) and not :maps.is_key(cell, seen),
      do: visit(grid, rest, :maps.put(cell, steps, seen), steps, [cell | acc]),
      else: visit(grid, rest, seen, steps, acc)
  end
end
