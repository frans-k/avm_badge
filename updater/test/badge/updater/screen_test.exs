defmodule Badge.Updater.ScreenTest do
  use ExUnit.Case, async: true

  alias Badge.Updater.Screen

  defp texts(view),
    do: for({:text, _x, _y, _f, colour, _bg, body} <- Screen.items(view), do: {body, colour})

  defp bodies(view), do: for({body, _colour} <- texts(view), do: body)

  test "the background is drawn last, under everything else" do
    assert {:rect, 0, 0, 320, 240, 0x000000} = List.last(Screen.items(%{status: "s"}))
  end

  test "the title and status are always shown" do
    assert bodies(%{status: "Checking for updates"}) == [
             "Firmware update",
             "Checking for updates"
           ]
  end

  test "detail and footer are shown when given" do
    view = %{
      status: "Update found",
      detail: "0.1.5 -> 0.1.6",
      footer: "Installed: avm_badge 0.1.5"
    }

    assert bodies(view) == [
             "Firmware update",
             "Update found",
             "0.1.5 -> 0.1.6",
             "Installed: avm_badge 0.1.5"
           ]
  end

  test "the warning only shows while flash is being written" do
    assert "Do not turn off your badge" in bodies(%{status: "Downloading 5%", warn: true})
    refute "Do not turn off your badge" in bodies(%{status: "Checking for updates"})
  end

  test "a download shows a bar filled to its percentage" do
    rects =
      for {:rect, _x, _y, _w, _h, _c} = r <- Screen.items(%{status: "s", progress: 50}), do: r

    assert [{:rect, 16, _, 144, _, _}, {:rect, 16, _, 288, _, _}, {:rect, 0, 0, 320, 240, _}] =
             rects
  end

  test "the bar never overruns its track" do
    [{:rect, _x, _y, fill, _h, _c} | _] =
      for {:rect, _, _, _, _, _} = r <- Screen.items(%{status: "s", progress: 140}), do: r

    assert fill == 288
  end

  test "an error colours the status line" do
    assert {"Could not update", 0xFF5050} in texts(%{status: "Could not update", tone: :error})
  end

  test "every line fits the panel" do
    view = %{
      status: String.duplicate("s", 60),
      detail: String.duplicate("d", 60),
      footer: String.duplicate("f", 60),
      warn: true,
      progress: 10
    }

    for {:text, x, y, _f, _c, _b, body} <- Screen.items(view) do
      assert x >= 0 and y >= 0 and y < 240
      assert x + 8 * byte_size(body) <= 320
    end
  end
end
