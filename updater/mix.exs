# The updater: a packbeam of its own in the `updater.avm` partition. The badge
# boots it instead of the firmware when NVS `atomvm/boot_path` points at it,
# and it installs whatever NervesHub offers into `main.avm`.
#
# `lib/shared/` links to firmware modules (pins, NVS, chip id, display, socket
# relay) so the two cannot drift apart.
defmodule Badge.Updater.MixProject do
  use Mix.Project

  def project do
    [
      app: :badge_updater,
      version: "0.1.0",
      elixir: "~> 1.13",
      deps: deps(),
      atomvm: [
        start: Badge.Updater,
        chip: "esp32s3"
      ]
    ]
  end

  def application, do: []

  # The NervesHub components come from the checkouts beside the firmware.
  defp deps do
    [
      {:atomvm, "~> 0.7.0-beta.0", runtime: false},
      {:exatomvm,
       github: "atomvm/ExAtomVM", ref: "a99323a1054adda1ec00e9997bc41bc7317a3826", runtime: false},
      {:atomvm_packbeam, "~> 0.8.2", runtime: false},
      {:atomvm_websocket_client, path: "../../atomvm_websocket_client", manager: :rebar3},
      {:nerves_hub_link_atomvm_esp32_ex, path: "../../nerves_hub_link_atomvm_esp32_ex"},
      {:nerves_hub_link_atomvm_esp32,
       path: "../../nerves_hub_link_atomvm_esp32", manager: :rebar3, override: true}
    ]
  end
end
