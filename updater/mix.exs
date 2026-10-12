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

  # The NervesHub components come from the protolux forks, pinned. The agent
  # is overridden because the wrapper asks Hex for it, and the fork carries
  # `update_slot`.
  defp deps do
    [
      {:atomvm, "~> 0.7.0-beta.0", runtime: false},
      {:exatomvm,
       github: "atomvm/ExAtomVM", ref: "a99323a1054adda1ec00e9997bc41bc7317a3826", runtime: false},
      {:atomvm_packbeam, "~> 0.8.2", runtime: false},
      {:atomvm_websocket_client,
       github: "protolux-electronics/atomvm_websocket_client",
       ref: "c877b3643144674b6b14ac612a9e29a8cbe6fcd4",
       manager: :rebar3},
      {:nerves_hub_link_atomvm_esp32_ex,
       github: "protolux-electronics/nerves_hub_link_atomvm_esp32_ex",
       ref: "13185594f8149a905ded7e5650bae923e285ea6b"},
      {:nerves_hub_link_atomvm_esp32,
       github: "protolux-electronics/nerves_hub_link_atomvm_esp32",
       ref: "3a037580dc171399a7805a3d2f25156d9a08e1ab",
       manager: :rebar3,
       override: true}
    ]
  end
end
