defmodule Badge.Raycaster.Link do
  @moduledoc """
  The Raycaster page's websocket to the relay server, open only while the page is.

  The connection is `Badge.Chat.Socket`'s, the ESP-IDF component that does the TCP, the
  TLS and the framing on a task of its own and reconnects by itself, so `:connected`
  arrives on every reconnection and the room is joined each time. `open/0` and
  `close/0` are casts and safe to repeat: the page calls `open/0` from every tick.

  It sends `Badge.UI`, which hands them to the page on screen:

    * `{:raycaster, :up}` once the server has put this badge in a room, and
      `{:raycaster, :down}` when the connection is lost
    * `{:raycaster, {:players, [{x, y, colour}]}}` once a second: everyone else

  The relay is the `raycaster_url` NVS key, or a default, and the token it asks for
  the `raycaster_token` key.
  """

  use GenServer

  alias Badge.Chat.Socket
  alias Badge.Identity
  alias Badge.Nvs
  alias Badge.Raycaster.Room
  alias Badge.Wifi

  @default_url "wss://evilgoat-relay.fly.dev"

  # The token the relay asks for, when there is no `raycaster_token` key: read while
  # compiling, like the secret the update link has built in. It ends up in the image,
  # so it keeps casual visitors out and nobody who reads the firmware.
  @default_token System.get_env("RAYCASTER_RELAY_TOKEN")

  @tick 2_000
  # A heartbeat about every 24 seconds; Phoenix drops a connection that goes quiet.
  @beats 12

  def start_link(_arg), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @spec open() :: :ok
  def open, do: GenServer.cast(__MODULE__, :open)

  @spec close() :: :ok
  def close, do: GenServer.cast(__MODULE__, :close)

  @doc "Tells the server where this badge stands. Dropped while not in a room."
  @spec publish(integer, integer) :: :ok
  def publish(x, y), do: GenServer.cast(__MODULE__, {:publish, x, y})

  @impl true
  def init(:ok) do
    start_ticker()

    {:ok, %{want: false, port: nil, slot: nil, joins: 0, ref: 0, beat: 0}}
  end

  @impl true
  def handle_call(_message, _from, state), do: {:reply, :error, state}

  @impl true
  def handle_cast(:open, %{want: true} = state), do: {:noreply, state}
  def handle_cast(:open, state), do: {:noreply, connect(%{state | want: true})}
  def handle_cast(:close, state), do: {:noreply, shut(%{state | want: false})}

  def handle_cast({:publish, x, y}, %{slot: slot, port: port} = state) when slot != nil do
    state = %{state | ref: state.ref + 1}
    send_frame(port, Room.pos(join_ref(state), Integer.to_string(state.ref), x, y))

    {:noreply, state}
  end

  def handle_cast({:publish, _x, _y}, state), do: {:noreply, state}

  @impl true
  def handle_info(:tick, state), do: {:noreply, state |> connect() |> beat()}

  # The port in these messages is not matched, and is not the one to send on: the
  # driver's port term is not the one open/4 returned, so a pinned match drops every
  # message without a word.
  def handle_info({:websocket, _port, :connected}, %{want: true} = state) do
    state = %{state | joins: state.joins + 1, slot: nil}
    send_frame(state.port, Room.join(join_ref(state)))

    {:noreply, state}
  end

  def handle_info({:websocket, _port, {:text, frame}}, state) do
    {:noreply, heard(Room.interpret(frame, state.slot), state)}
  end

  def handle_info({:websocket, _port, {:closed, _reason}}, state), do: {:noreply, down(state)}
  def handle_info({:websocket, _port, {:error, _reason}}, state), do: {:noreply, down(state)}
  def handle_info(_message, state), do: {:noreply, state}

  defp heard({:joined, slot}, state) do
    :io.format(~c"Raycaster: joined the relay, slot ~p~n", [slot])
    send(Badge.UI, {:raycaster, :up})
    %{state | slot: slot}
  end

  defp heard({:players, players}, state) do
    send(Badge.UI, {:raycaster, {:players, players}})
    state
  end

  defp heard(:ignore, state), do: state

  # A certificate is not yet valid at the epoch, so this waits for the clock as well as
  # for an address, as the chat does.
  defp connect(%{want: true, port: nil} = state) do
    case Wifi.status() do
      %{radio: :connected, synced: true} -> opening(state)
      _not_ready -> state
    end
  end

  defp connect(state), do: state

  defp opening(state) do
    chip = Identity.format(Identity.chip_id())
    base = Socket.base_url(Nvs.get(:raycaster_url) || @default_url)

    case Socket.open(base, chip, "raycaster", token(Nvs.get(:raycaster_token) || @default_token)) do
      {:ok, port} -> %{state | port: port}
      {:error, _reason} -> state
    end
  end

  defp token(nil), do: []
  defp token(value), do: [{"token", value}]

  defp down(state) do
    if state.slot != nil, do: send(Badge.UI, {:raycaster, :down})
    %{state | slot: nil}
  end

  defp shut(%{port: nil} = state), do: state

  defp shut(state) do
    Socket.close(state.port)
    down(%{state | port: nil})
  end

  defp beat(%{beat: beat, slot: slot} = state) when beat >= @beats and slot != nil do
    send_frame(state.port, Room.heartbeat())
    %{state | beat: 0}
  end

  defp beat(%{beat: beat} = state), do: %{state | beat: beat + 1}

  defp join_ref(state), do: Integer.to_string(state.joins)

  defp send_frame(port, frame) do
    case Socket.send_frame(port, frame) do
      :ok -> :ok
      {:error, reason} -> :io.format(~c"Raycaster: refused ~p~n", [reason])
    end
  end

  defp start_ticker do
    link = self()
    spawn_link(fn -> tick_loop(link) end)
  end

  defp tick_loop(link) do
    Process.sleep(@tick)
    send(link, :tick)
    tick_loop(link)
  end
end
