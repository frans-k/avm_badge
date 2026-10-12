defmodule Badge.Updater do
  @moduledoc """
  Installs firmware updates into `main.avm`, then hands the badge back to it.

  The firmware asks for an update by pointing NVS `atomvm/boot_path` at
  `updater.avm` and restarting. This joins NervesHub as the firmware in
  `main.avm`, installs whatever update is waiting, clears `boot_path` and
  restarts into the firmware.

  There is one application slot and no rollback. Once a download has started
  erasing `main.avm`, the badge stays in the updater (`boot_path` still points
  here) and every restart tries again, until an update lands or someone
  flashes the badge by cable. The screen says not to turn the badge off from
  the moment an update is found until the firmware is whole again.
  """

  alias Badge.Identity
  alias Badge.Nvs
  alias Badge.Updater.Screen

  @compile {:no_warn_undefined, [:esp, :network, :nh_flash, :ssl, NervesHubLink]}

  @slot "main.avm"
  @host "devices.nervescloud.com"
  @sntp_host "pool.ntp.org"

  # The badge's own product credentials, so a firmware anyone built updates
  # itself without provisioning. NVS wins when a badge carries its own.
  @key "nhp_M2JlScHNMgHq2mulr1yUlHUW0XYQDPkTSnjQ72ZZw80"
  @secret "KfQ9UVgb6724Jqpo2oITeRXnwgQuXOBTwy0TVtLkFNE"

  @wifi_timeout 30_000
  @clock_timeout 30_000
  @join_timeout 60_000
  # After the join, how long an offer may take to arrive before the badge
  # counts as up to date.
  @quiet 20_000
  @retry_delay 30_000
  @message_hold 3_000

  def start do
    :io.format(~c"Updater: starting~n")
    installed = installed()

    ui = %{
      display: Screen.open(),
      footer: footer(installed),
      from: version(installed),
      whole: installed != nil
    }

    show(ui, %{status: "Starting"})

    # The download's TLS session needs it; nothing else starts it here.
    :ssl.start()

    result = run(ui, installed)
    :io.format(~c"Updater: ~p~n", [result])

    case {result, app_intact?()} do
      {{:updated, to}, true} -> leave(ui, "Update installed", to, nil)
      {:current, true} -> leave(ui, "Already up to date", ui.from, nil)
      {{:error, reason}, true} -> leave(ui, "Could not update", describe(reason), :error)
      {_result, false} -> retry(ui, result)
    end
  end

  # The firmware is whole, so the badge goes back to it whatever happened.
  defp leave(ui, status, detail, tone) do
    show(ui, %{status: status, detail: detail, tone: tone})
    Process.sleep(@message_hold)
    show(ui, %{status: "Restarting", detail: detail, tone: tone})

    :esp.nvs_erase_key(:atomvm, :boot_path)

    # Left by A/B updates before the updater existed.
    for key <- [:pending_slot, :previous_slot, :boot_attempts, :reverted] do
      :esp.nvs_erase_key(:nerves_hub, key)
    end

    :io.format(~c"Updater: restarting into ~s~n", [@slot])
    :esp.restart()
  end

  # `main.avm` is partly written or empty: nothing else can run, so try again
  # from a clean boot.
  defp retry(ui, result) do
    reason =
      case result do
        {:error, reason} -> describe(reason)
        _other -> "No firmware installed"
      end

    show(ui, %{status: "Update did not finish", detail: reason, tone: :error, warn: true})
    Process.sleep(div(@retry_delay, 2))
    show(ui, %{status: "Trying again shortly", detail: reason, tone: :error, warn: true})
    Process.sleep(div(@retry_delay, 2))

    :esp.restart()
  end

  defp run(ui, installed) do
    with :ok <- wifi(ui),
         :ok <- clock(ui) do
      hub(ui, installed)
    end
  end

  defp show(ui, view) do
    view = Map.put(view, :footer, ui.footer)

    # A badge that started without whole firmware is mid-update whatever this
    # screen says. Read once at the start: hashing the slot takes a while.
    view = if ui.whole, do: view, else: Map.put(view, :warn, true)

    Screen.show(ui.display, view)
  end

  defp app_intact?, do: installed() != nil

  defp installed do
    case :nh_flash.read_metadata(@slot) do
      {:ok, metadata} -> metadata
      {:error, _reason} -> nil
    end
  end

  @doc "The footer naming what is installed."
  @spec footer(map | nil) :: binary
  def footer(nil), do: "No firmware installed"
  def footer(metadata), do: "Installed: " <> name(metadata) <> " " <> version(metadata)

  defp name(metadata), do: field(metadata, :app_name, "firmware")

  @doc "The version in firmware metadata, or `nil`."
  @spec version(map | nil) :: binary | nil
  def version(nil), do: nil
  def version(metadata), do: field(metadata, :app_version, nil)

  defp field(metadata, key, default) do
    case Map.get(metadata, key) do
      value when is_binary(value) -> value
      _absent -> default
    end
  end

  # ------------------------------------------------------------------ network

  # Checked before anything else: with no network there is nothing to ask.
  defp wifi(ui) do
    case {Nvs.get(:wifi_ssid), Nvs.get(:wifi_psk)} do
      {ssid, psk} when is_binary(ssid) and is_binary(psk) ->
        show(ui, %{status: "Connecting to Wi-Fi", detail: ssid})
        updater = self()

        {:ok, _network} =
          :network.start(
            sta: [
              ssid: ssid,
              psk: psk,
              got_ip: fn _ip -> send(updater, :got_ip) end,
              disconnected: fn -> send(updater, :wifi_disconnected) end
            ],
            sntp: [host: @sntp_host, synchronized: fn _time -> send(updater, :clock_synced) end]
          )

        await(:got_ip, @wifi_timeout, :wifi_timeout)

      _absent ->
        {:error, :no_wifi_credentials}
    end
  end

  # NervesHub refuses a shared-secret signature from a clock still at 1970.
  defp clock(ui) do
    show(ui, %{status: "Setting the clock"})
    await(:clock_synced, @clock_timeout, :clock_timeout)
  end

  defp await(message, timeout, error) do
    receive do
      ^message -> :ok
    after
      timeout -> {:error, error}
    end
  end

  # ---------------------------------------------------------------- NervesHub

  defp hub(ui, installed) do
    show(ui, %{status: "Contacting NervesHub"})
    {key, secret} = credentials()

    options = [
      handler: self(),
      identifier: Identity.format(Identity.chip_id()),
      shared_secret: {key, secret},
      host: host(),
      updates: :auto,
      reboot: :manual,
      firmware_trial: :off,
      firmware: firmware(installed),
      update_slot: @slot,
      transport: Badge.Update.Transport
    ]

    case NervesHubLink.start(options) do
      {:ok, agent} ->
        listen(ui, agent, %{phase: :joining, asked: false, checked: false, to: nil})

      {:error, reason} ->
        {:error, reason}
    end
  end

  # NervesHub identifies firmware by what this says about `main.avm`. With
  # nothing valid there, it is told nothing and offers what the deployment has.
  defp firmware(nil), do: :none
  defp firmware(metadata), do: {:metadata, metadata}

  defp listen(ui, agent, state) do
    receive do
      {:nerves_hub, event} ->
        continue(event(event, ui, agent, state), ui, agent)

      {:asked, what, reply} ->
        continue(answered(what, reply, ui, agent, state), ui, agent)
    after
      timeout(state.phase) ->
        case state.phase do
          :joining -> {:error, :join_timeout}
          :joined -> :current
        end
    end
  end

  defp continue({:cont, state}, ui, agent), do: listen(ui, agent, state)
  defp continue(result, _ui, _agent), do: result

  # A download has its own idle timeout in the agent, reported as a failure.
  defp timeout(:joining), do: @join_timeout
  defp timeout(:joined), do: @quiet
  defp timeout(_busy), do: :infinity

  # The join reply carries any offer waiting, so it is installed without a
  # second round trip.
  defp event({:joined, response}, ui, agent, state) do
    available = Map.get(response, "update_available")
    :io.format(~c"Updater: joined, update available ~p~n", [available])

    if available == true do
      NervesHubLink.apply_update(agent, response)
      {:cont, offered(ui, response, state)}
    else
      show(ui, %{status: "Checking for updates"})
      {:cont, %{state | phase: :joined}}
    end
  end

  # Pushed while the device is in automatic mode; the agent starts it itself.
  defp event({:message, "update", payload}, ui, _agent, state) do
    :io.format(~c"Updater: update offered~n")
    {:cont, offered(ui, payload, state)}
  end

  defp event({:update_mode, mode, allowed}, _ui, agent, state) do
    :io.format(~c"Updater: mode ~p, managed updates allowed ~p~n", [mode, allowed])

    cond do
      mode == :device_managed and not state.checked ->
        ask(:check, &NervesHubLink.check_for_update/1, agent)
        {:cont, %{state | checked: true}}

      allowed and not state.asked ->
        ask(:mode, &NervesHubLink.set_update_mode(&1, :device_managed), agent)
        {:cont, %{state | asked: true}}

      true ->
        {:cont, state}
    end
  end

  defp event({:update_started, _pid}, ui, _agent, state) do
    downloading(ui, state, 0)
    {:cont, %{state | phase: :downloading}}
  end

  defp event({:update_progress, 100}, ui, _agent, state) do
    show(ui, %{status: "Verifying", detail: change(ui.from, state.to), progress: 100, warn: true})
    {:cont, state}
  end

  defp event({:update_progress, percent}, ui, _agent, state) do
    downloading(ui, state, percent)
    {:cont, state}
  end

  defp event({:update_ready, slot}, _ui, _agent, state) do
    :io.format(~c"Updater: written to ~s~n", [slot])
    {:updated, state.to}
  end

  defp event({:update_failed, reason}, _ui, _agent, _state), do: {:error, reason}
  defp event({:join_error, reason}, _ui, _agent, _state), do: {:error, {:join, reason}}

  defp event(event, _ui, _agent, state) do
    :io.format(~c"Updater: hub ~p~n", [event])
    {:cont, state}
  end

  defp answered(:check, {:ok, %{available: true} = result}, ui, agent, state) do
    ask(:request, &NervesHubLink.request_update/1, agent)
    {:cont, offered(ui, %{"firmware_meta" => Map.get(result, :firmware_meta)}, state)}
  end

  defp answered(:check, {:ok, _none}, _ui, _agent, _state), do: :current
  defp answered(:request, :ok, _ui, _agent, state), do: {:cont, state}
  defp answered(:request, {:error, :no_update}, _ui, _agent, _state), do: :current
  defp answered(:mode, _reply, _ui, _agent, state), do: {:cont, state}
  defp answered(_what, {:error, reason}, _ui, _agent, _state), do: {:error, reason}

  # From here until the firmware is whole again the badge must stay on.
  defp offered(ui, payload, state) do
    to = offered_version(payload)
    show(ui, %{status: "Update found", detail: change(ui.from, to), warn: true})
    %{state | phase: :offered, to: to}
  end

  defp downloading(ui, state, percent) do
    show(ui, %{
      status: "Downloading " <> :erlang.integer_to_binary(percent) <> "%",
      detail: change(ui.from, state.to),
      progress: percent,
      warn: true
    })
  end

  @doc "The version NervesHub names in an offer's firmware metadata, or `nil`."
  @spec offered_version(map) :: binary | nil
  def offered_version(payload) do
    case Map.get(payload, "firmware_meta") do
      %{"version" => version} when is_binary(version) -> version
      _absent -> nil
    end
  end

  @doc "The line saying what changes to what."
  @spec change(binary | nil, binary | nil) :: binary | nil
  def change(_from, nil), do: nil
  def change(nil, to), do: "Installing " <> to
  def change(from, to), do: from <> " -> " <> to

  # The agent answers these once NervesHub has, so they wait in a process of
  # their own.
  defp ask(what, call, agent) do
    updater = self()
    spawn(fn -> send(updater, {:asked, what, call.(agent)}) end)
  end

  defp credentials do
    case {Nvs.get(:nh_key), Nvs.get(:nh_secret)} do
      {key, secret} when is_binary(key) and is_binary(secret) -> {key, secret}
      _absent -> {@key, @secret}
    end
  end

  defp host do
    case Nvs.get(:nh_host) do
      host when is_binary(host) -> host
      _absent -> @host
    end
  end

  @doc "What went wrong, in words that fit on the screen."
  @spec describe(term) :: binary
  def describe(:no_wifi_credentials), do: "No Wi-Fi set up on this badge"
  def describe(:wifi_timeout), do: "Could not join the Wi-Fi"
  def describe(:clock_timeout), do: "Could not set the clock"
  def describe(:join_timeout), do: "NervesHub did not answer"
  def describe({:join, _reason}), do: "NervesHub refused the badge"
  def describe(:download_stalled), do: "The download stalled"
  def describe({:checksum_mismatch, _digest, _expected}), do: "The download was corrupt"
  def describe({:signature_rejected, _reason}), do: "The update was not signed"
  def describe({:clock_not_set, _now}), do: "Could not set the clock"
  def describe(reason) when is_binary(reason), do: reason
  def describe(reason) when is_atom(reason), do: :erlang.atom_to_binary(reason)
  def describe(reason), do: :erlang.iolist_to_binary(:io_lib.format(~c"~p", [reason]))
end
