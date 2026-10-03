defmodule Raycaster.OmenTest do
  use ExUnit.Case, async: true

  alias Raycaster.Omen

  @player %{x: 1000, y: 1000, a: 0}
  @cell 256

  defp goat(cells, hunting \\ false), do: {1000 + cells * @cell, 1000, hunting}

  describe "level/2" do
    test "no goat is no dread" do
      assert Omen.level(@player, nil) == 0
    end

    test "grows as the goat comes closer" do
      assert Omen.level(@player, goat(8)) == 0
      assert Omen.level(@player, goat(6)) == 1
      assert Omen.level(@player, goat(3)) == 2
    end

    test "the strobe is for a goat that is close and after you" do
      assert Omen.level(@player, goat(1, true)) == 3
      assert Omen.level(@player, goat(1, false)) == 2
    end

    test "a goat after you but farther than two cells is not the strobe" do
      assert Omen.level(@player, goat(3, true)) == 2
    end
  end

  describe "pattern/1" do
    test "every level has frames of one colour for each of the four LEDs, kept dim" do
      for level <- [1, 2, 3, :caught] do
        {ms, frames} = Omen.pattern(level)

        assert ms == :infinity or ms > 0
        assert frames != []

        for frame <- frames do
          assert length(frame) == 4
          for {r, g, b} <- frame, do: assert(r + g + b <= 128)
        end
      end
    end

    test "being caught holds still" do
      assert {:infinity, [_one]} = Omen.pattern(:caught)
    end
  end
end
