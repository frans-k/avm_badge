defmodule Raycaster.Omen do
  @moduledoc """
  The badge's four LEDs, telling you the goat is near before you see it.

  `level/2` turns where you and the goat are into a level of dread, through walls too, and
  `pattern/1` is what `Badge.Pixels.pattern/2` plays for it. The page only asks when the level
  changes.

    * 0: no goat, or more than seven cells off: the owner's LED mode, as set in the LED page
    * 1: within seven cells, a dark red ember crawls across the four
    * 2: within four, red, purple and orange shift round them
    * 3: within two, and it is after you: a red and white strobe
    * `:caught`: steady blood red, under the game over screen

  The colours are dim on purpose: four LEDs at full brightness hurt to look at, and draw a
  lot more current.
  """

  # Squared, in the map's fixed point (256 to a cell), so no square root is taken.
  @far 7 * 256 * (7 * 256)
  @near 4 * 256 * (4 * 256)
  @close 2 * 256 * (2 * 256)

  @doc "How much to dread a goat, `{x, y, hunting}` or nil, from where the player stands."
  def level(_player, nil), do: 0

  def level(%{x: x, y: y}, {gx, gy, hunting}) do
    dx = gx - x
    dy = gy - y
    far = dx * dx + dy * dy

    cond do
      far <= @close and hunting -> 3
      far <= @near -> 2
      far <= @far -> 1
      true -> 0
    end
  end

  @doc "The pattern for a level above 0: `{ms a frame, [four {r, g, b}, ...]}`."
  def pattern(1) do
    ember = {40, 0, 0}
    dark = {5, 0, 0}

    {500,
     [
       [ember, dark, dark, dark],
       [dark, ember, dark, dark],
       [dark, dark, ember, dark],
       [dark, dark, dark, ember]
     ]}
  end

  def pattern(2) do
    red = {56, 0, 0}
    purple = {24, 0, 36}
    orange = {48, 14, 0}
    bruise = {8, 0, 16}

    {250,
     [
       [red, purple, orange, bruise],
       [bruise, red, purple, orange],
       [orange, bruise, red, purple],
       [purple, orange, bruise, red]
     ]}
  end

  def pattern(3) do
    red = {64, 0, 0}
    white = {40, 40, 40}

    {100, [[red, white, red, white], [white, red, white, red]]}
  end

  def pattern(:caught), do: {:infinity, [[{64, 0, 0}, {64, 0, 0}, {64, 0, 0}, {64, 0, 0}]]}
end
