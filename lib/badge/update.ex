defmodule Badge.Update do
  @moduledoc """
  Firmware updates, by handing the badge to the updater.

  The updater is a packbeam of its own in the `updater.avm` partition (see
  `updater/`). Pointing NVS `atomvm/boot_path` at it and restarting runs it in
  place of this firmware: it joins NervesHub, installs any update into
  `main.avm`, clears `boot_path` and restarts back into the firmware. Nothing
  here talks to NervesHub.
  """

  @compile {:no_warn_undefined, :esp}

  @updater "/dev/partition/by-name/updater.avm"
  @version Mix.Project.config()[:version]

  @doc "This firmware's version, as NervesHub knows it."
  @spec version() :: binary
  def version, do: @version

  @doc "Restarts into the updater."
  @spec start() :: no_return
  def start do
    :io.format(~c"Update: restarting into the updater~n")
    :ok = :esp.nvs_set_binary(:atomvm, :boot_path, @updater)

    :esp.restart()
  end
end
