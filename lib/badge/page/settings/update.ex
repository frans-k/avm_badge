defmodule Badge.Page.Settings.Update do
  @moduledoc """
  Firmware updates. Shows what is running and restarts into the updater, which
  installs whatever NervesHub offers and comes back here.

  The updater needs the network and must not lose power while it writes, so
  the check is only offered once Wi-Fi is connected and the battery is not
  nearly flat (or USB is in). The restart is confirmed, because the badge is
  on someone.
  """

  use Badge.Page

  alias Badge.Battery
  alias Badge.Identity
  alias Badge.Page.Settings
  alias Badge.Power
  alias Badge.Readout
  alias Badge.Theme
  alias Badge.Wifi

  @row_x 8
  @help_y 216

  # Below this, on battery, an update could run the badge flat half-written.
  @min_battery 20

  @running_y Settings.content_top()
  @id_y @running_y + Readout.pitch()
  @wifi_y @id_y + Readout.pitch()
  @battery_y @wifi_y + Readout.pitch()
  @about_y @battery_y + Readout.pitch() + 8

  @impl true
  def title, do: "Update"

  @impl true
  def init, do: %{confirm: false, updater: Badge.Update.available?(), wifi: nil, power: nil}

  @impl true
  def tick(state), do: %{state | wifi: Wifi.status(), power: Power.status()}

  @impl true
  def handle_key({:edit, :newline}, %{confirm: false} = state) do
    case blocker(state) do
      nil -> {:ok, %{state | confirm: true}}
      _reason -> :ignore
    end
  end

  def handle_key({:edit, :newline}, %{confirm: true} = state) do
    Badge.Update.start()

    {:ok, state}
  end

  def handle_key({:nav, :home}, %{confirm: true} = state), do: {:ok, %{state | confirm: false}}

  # A confirm owns the arrows, so nobody slides off a question they were asked.
  def handle_key({:move, _direction}, %{confirm: true} = state), do: {:ok, state}
  def handle_key(_event, _state), do: :ignore

  @doc """
  What keeps the badge from checking for updates right now, or `nil`. The
  updater joins the network itself, but one that cannot reach it only comes
  back here with an error.
  """
  @spec blocker(map) :: binary | nil
  def blocker(%{updater: false}), do: "Reflash it by cable first."
  def blocker(%{wifi: nil}), do: "Checking Wi-Fi..."
  def blocker(%{wifi: %{radio: radio}}) when radio != :connected, do: "Connect to Wi-Fi first."

  def blocker(%{power: %{usb: false, battery_mv: mv}}) do
    if Battery.percent(mv) < @min_battery, do: "Charge the battery first.", else: nil
  end

  def blocker(_state), do: nil

  @impl true
  def render(state) do
    :lists.flatten([
      Readout.right_row(
        "running",
        "avm_badge " <> Badge.Update.version(),
        @running_y,
        Theme.fg()
      ),
      Readout.right_row("id", Identity.format(Identity.chip_id()), @id_y, Theme.fg()),
      wifi_row(state),
      battery_row(state),
      about(state),
      help(state)
    ])
  end

  defp wifi_row(%{wifi: nil}), do: Readout.right_row("wifi", "...", @wifi_y, Theme.dim())

  defp wifi_row(%{wifi: %{radio: :connected, ssid: ssid}}) when is_binary(ssid),
    do: Readout.right_row("wifi", ssid, @wifi_y, Theme.ok())

  defp wifi_row(%{wifi: %{radio: :connected}}),
    do: Readout.right_row("wifi", "connected", @wifi_y, Theme.ok())

  defp wifi_row(_state), do: Readout.right_row("wifi", "not connected", @wifi_y, Theme.warn())

  defp battery_row(%{power: nil}),
    do: Readout.right_row("battery", "...", @battery_y, Theme.dim())

  defp battery_row(%{power: %{usb: true}}),
    do: Readout.right_row("battery", "on USB", @battery_y, Theme.ok())

  defp battery_row(%{power: %{battery_mv: mv}}) do
    percent = Battery.percent(mv)
    colour = if percent < @min_battery, do: Theme.warn(), else: Theme.fg()

    Readout.right_row("battery", :erlang.integer_to_binary(percent) <> "%", @battery_y, colour)
  end

  defp about(%{updater: false}) do
    text(@about_y, "This badge has no updater.", Theme.warn())
  end

  defp about(_state) do
    [
      text(@about_y, "Checking restarts into the updater.", Theme.dim()),
      text(@about_y + Readout.pitch(), "It installs any update, then", Theme.dim()),
      text(@about_y + 2 * Readout.pitch(), "restarts back here.", Theme.dim())
    ]
  end

  defp help(%{confirm: true}),
    do: text(@help_y, "restart now?   Enter yes   Esc cancel", Theme.accent())

  defp help(state) do
    case blocker(state) do
      nil -> text(@help_y, "Enter check for updates", Theme.dim())
      reason -> text(@help_y, reason, Theme.warn())
    end
  end

  defp text(y, body, colour), do: {:text, @row_x, y, :default16px, colour, Theme.bg(), body}
end
