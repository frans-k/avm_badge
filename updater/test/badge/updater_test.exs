defmodule Badge.UpdaterTest do
  use ExUnit.Case, async: true

  alias Badge.Updater

  describe "the footer" do
    test "names what is installed" do
      assert Updater.footer(%{app_name: "avm_badge", app_version: "0.1.5"}) ==
               "Installed: avm_badge 0.1.5"
    end

    test "says when nothing is" do
      assert Updater.footer(nil) == "No firmware installed"
    end
  end

  describe "the version line" do
    test "reads the offered version from NervesHub's firmware metadata" do
      assert Updater.offered_version(%{"firmware_meta" => %{"version" => "0.1.6"}}) == "0.1.6"
      assert Updater.offered_version(%{}) == nil
    end

    test "shows the change from one version to the other" do
      assert Updater.change("0.1.5", "0.1.6") == "0.1.5 -> 0.1.6"
      assert Updater.change(nil, "0.1.6") == "Installing 0.1.6"
      assert Updater.change("0.1.5", nil) == nil
    end
  end

  describe "describing failures" do
    test "says what went wrong in plain words" do
      assert Updater.describe(:no_wifi_credentials) == "No Wi-Fi set up on this badge"
      assert Updater.describe(:wifi_timeout) == "Could not join the Wi-Fi"
      assert Updater.describe({:join, :unauthorized}) == "NervesHub refused the badge"
      assert Updater.describe(:download_stalled) == "The download stalled"
    end

    test "falls back to the raw reason" do
      assert Updater.describe({:weird, 1}) == "{weird,1}"
    end
  end
end
