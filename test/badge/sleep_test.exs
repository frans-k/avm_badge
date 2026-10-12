defmodule Badge.SleepTest do
  use ExUnit.Case, async: true

  alias Badge.Sleep

  test "the CPU sleeps thirty seconds after the screen does" do
    assert Sleep.ticks(100) == 300
  end

  test "a badge on battery may sleep" do
    assert Sleep.allowed?(%{usb: false})
  end

  test "USB power holds it back, since sleep drops the serial port" do
    refute Sleep.allowed?(%{usb: true})
  end
end
