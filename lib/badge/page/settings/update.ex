defmodule Badge.Page.Settings.Update do
  @moduledoc """
  Firmware updates. Shows what is running and restarts into the updater, which
  installs whatever NervesHub offers and comes back here.

  The restart is confirmed, because the badge is on someone.
  """

  use Badge.Page

  alias Badge.Identity
  alias Badge.Page.Settings
  alias Badge.Readout
  alias Badge.Theme

  @row_x 8
  @help_y 216

  @running_y Settings.content_top()
  @id_y @running_y + Readout.pitch()
  @about_y @id_y + Readout.pitch() + 8

  @impl true
  def title, do: "Update"

  @impl true
  def init, do: %{confirm: false}

  @impl true
  def handle_key({:edit, :newline}, %{confirm: false} = state),
    do: {:ok, %{state | confirm: true}}

  def handle_key({:edit, :newline}, %{confirm: true} = state) do
    Badge.Update.start()

    {:ok, state}
  end

  def handle_key({:nav, :home}, %{confirm: true} = state), do: {:ok, %{state | confirm: false}}

  # A confirm owns the arrows, so nobody slides off a question they were asked.
  def handle_key({:move, _direction}, %{confirm: true} = state), do: {:ok, state}
  def handle_key(_event, _state), do: :ignore

  @impl true
  def render(%{confirm: confirm}) do
    [
      Readout.right_row(
        "running",
        "avm_badge " <> Badge.Update.version(),
        @running_y,
        Theme.fg()
      ),
      Readout.right_row("id", Identity.format(Identity.chip_id()), @id_y, Theme.fg()),
      text(@about_y, "Checking restarts into the updater.", Theme.dim()),
      text(@about_y + Readout.pitch(), "It installs any update, then", Theme.dim()),
      text(@about_y + 2 * Readout.pitch(), "restarts back here.", Theme.dim()),
      help(confirm)
    ]
    |> :lists.flatten()
  end

  defp help(false), do: text(@help_y, "Enter check for updates", Theme.dim())
  defp help(true), do: text(@help_y, "restart now?   Enter yes   Esc cancel", Theme.accent())

  defp text(y, body, colour), do: {:text, @row_x, y, :default16px, colour, Theme.bg(), body}
end
