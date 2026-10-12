defmodule Badge.Updater.ScreenTest do
  use ExUnit.Case, async: true

  alias Badge.Updater.Screen

  defp texts(items), do: for({:text, _x, _y, _f, colour, _bg, body} <- items, do: {body, colour})

  test "the background is drawn last, under everything else" do
    assert {:rect, 0, 0, 320, 240, 0x000000} = List.last(Screen.items("Title", "status", nil))
  end

  test "title and status are both on screen" do
    bodies =
      for {body, _colour} <- texts(Screen.items("Firmware update", "Up to date", nil)), do: body

    assert bodies == ["Firmware update", "Up to date"]
  end

  test "a download shows a bar filled to its percentage" do
    [_title, _status, fill, track, _bg] = Screen.items("t", "s", 50)

    assert {:rect, 16, _y, 144, _h, _colour} = fill
    assert {:rect, 16, _y2, 288, _h2, _colour2} = track
  end

  test "no bar without a percentage" do
    assert length(Screen.items("t", "s", nil)) == 3
  end

  test "an error colours the status line" do
    [{"t", _title}, {"oops", colour}] = texts(Screen.items("t", "oops", :error))

    assert colour == 0xFF5050
  end
end
