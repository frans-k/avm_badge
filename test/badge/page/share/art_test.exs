defmodule Badge.Page.Share.ArtTest do
  use ExUnit.Case, async: true

  alias Badge.Page.Share.Art

  describe "items/3" do
    test "is rectangles in the colour given, inside the art's size, from the corner given" do
      {width, height} = Art.size()
      items = Art.items(10, 20, 0x123456)

      assert length(items) > 100

      for {:rect, x, y, w, h, colour} <- items do
        assert colour == 0x123456
        assert w >= 1 and h >= 1
        assert x >= 10 and x + w <= 10 + width
        assert y >= 20 and y + h <= 20 + height
      end
    end

    test "no two rectangles overlap" do
      pixels =
        for {:rect, x, y, w, h, _colour} <- Art.items(0, 0, 0),
            px <- x..(x + w - 1),
            py <- y..(y + h - 1),
            do: {px, py}

      assert length(pixels) == length(Enum.uniq(pixels))
    end
  end
end
