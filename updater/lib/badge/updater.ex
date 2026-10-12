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
  flashes the badge by cable.
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

  @title "Firmware update"
  @status_width 38

  def start do
    :io.format(~c"Updater: starting~n")
    display = Screen.open()

    # The download's TLS session needs it; nothing else starts it here.
    :ssl.start()

    result = run(display)
    :io.format(~c"Updater: ~p~n", [result])

    case {result, app_intact?()} do
      {:updated, true} -> leave(display, "Update installed")
      {:current, true} -> leave(display, "Up to date")
      {{:error, reason}, true} -> leave(display, describe(reason), :error)
      {_result, false} -> retry(display, result)
    end
  end

  # The firmware is still whole, so the badge goes back to it whatever happened.
  defp leave(display, status, progress \\ nil) do
    Screen.show(display, @title, status, progress)
    Process.sleep(@message_hold)

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
  defp retry(display, result) do
    reason =
      case result do
        {:error, reason} -> describe(reason)
        _other -> "no firmware installed"
      end

    Screen.show(display, "Update failed, retrying", reason, :error)
    Process.sleep(@retry_delay)

    :esp.restart()
  end

  defp run(display) do
    metadata = installed()

    with :ok <- wifi(display),
         :ok <- clock(display) do
      hub(display, metadata)
    end
  end

  defp app_intact?, do: installed() != nil

  defp installed do
    case :nh_flash.read_metadata(@slot) do
      {:ok, metadata} -> metadata
      {:error, _reason} -> nil
    end
  end

  # ------------------------------------------------------------------ network

  defp wifi(display) do
    case {Nvs.get(:wifi_ssid), Nvs.get(:wifi_psk)} do
      {ssid, psk} when is_binary(ssid) and is_binary(psk) ->
        Screen.show(display, @title, fit("Joining " <> ssid))
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
  defp clock(display) do
    Screen.show(display, @title, "Setting the clock")
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

  defp hub(display, metadata) do
    Screen.show(display, @title, "Contacting NervesHub")
    {key, secret} = credentials()

    options = [
      handler: self(),
      identifier: Identity.format(Identity.chip_id()),
      shared_secret: {key, secret},
      host: host(),
      updates: :auto,
      reboot: :manual,
      firmware_trial: :off,
      firmware: firmware(metadata),
      update_slot: @slot,
      transport: Badge.Update.Transport
    ]

    case NervesHubLink.start(options) do
      {:ok, agent} ->
        listen(display, agent, %{phase: :joining, asked: false, checked: false})

      {:error, reason} ->
        {:error, reason}
    end
  end

  # NervesHub identifies firmware by what this says about `main.avm`. With
  # nothing valid there, it is told nothing and offers what the deployment has.
  defp firmware(nil), do: :none
  defp firmware(metadata), do: {:metadata, metadata}

  defp listen(display, agent, state) do
    receive do
      {:nerves_hub, event} ->
        continue(event(event, display, agent, state), display, agent)

      {:asked, what, reply} ->
        continue(answered(what, reply, agent, state), display, agent)
    after
      timeout(state.phase) ->
        case state.phase do
          :joining -> {:error, :join_timeout}
          :joined -> :current
        end
    end
  end

  defp continue({:cont, state}, display, agent), do: listen(display, agent, state)
  defp continue(result, _display, _agent), do: result

  # A download has its own idle timeout in the agent, reported as a failure.
  defp timeout(:joining), do: @join_timeout
  defp timeout(:joined), do: @quiet
  defp timeout(_busy), do: :infinity

  # The join reply carries any offer waiting, so it is installed without a
  # second round trip.
  defp event({:joined, response}, _display, agent, state) do
    :io.format(~c"Updater: joined, update available ~p~n", [
      Map.get(response, "update_available")
    ])

    if Map.get(response, "update_available") == true do
      NervesHubLink.apply_update(agent, response)
      {:cont, %{state | phase: :offered}}
    else
      {:cont, %{state | phase: :joined}}
    end
  end

  # Pushed while the device is in automatic mode; the agent starts it itself.
  defp event({:message, "update", _payload}, _display, _agent, state) do
    :io.format(~c"Updater: update offered~n")
    {:cont, %{state | phase: :offered}}
  end

  defp event({:update_mode, mode, allowed}, _display, agent, state) do
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

  defp event({:update_started, _pid}, display, _agent, state) do
    Screen.show(display, @title, "Downloading", 0)
    {:cont, %{state | phase: :downloading}}
  end

  defp event({:update_progress, percent}, display, _agent, state) do
    Screen.show(display, @title, "Downloading", percent)
    {:cont, state}
  end

  defp event({:update_ready, slot}, _display, _agent, _state) do
    :io.format(~c"Updater: written to ~s~n", [slot])
    :updated
  end

  defp event({:update_failed, reason}, _display, _agent, _state), do: {:error, reason}
  defp event({:join_error, reason}, _display, _agent, _state), do: {:error, {:join, reason}}

  defp event(event, _display, _agent, state) do
    :io.format(~c"Updater: hub ~p~n", [event])
    {:cont, state}
  end

  defp answered(:check, {:ok, %{available: true}}, agent, state) do
    ask(:request, &NervesHubLink.request_update/1, agent)
    {:cont, %{state | phase: :offered}}
  end

  defp answered(:check, {:ok, _none}, _agent, _state), do: :current
  defp answered(:request, :ok, _agent, state), do: {:cont, state}
  defp answered(:request, {:error, :no_update}, _agent, _state), do: :current
  defp answered(:mode, _reply, _agent, state), do: {:cont, state}
  defp answered(_what, {:error, reason}, _agent, _state), do: {:error, reason}

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

  defp describe(reason) when is_atom(reason), do: fit(:erlang.atom_to_binary(reason))
  defp describe(reason) when is_binary(reason), do: fit(reason)
  defp describe(reason), do: fit(:erlang.iolist_to_binary(:io_lib.format(~c"~p", [reason])))

  defp fit(text) when byte_size(text) > @status_width, do: :binary.part(text, 0, @status_width)
  defp fit(text), do: text
end
