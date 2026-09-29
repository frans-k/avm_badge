defmodule Badge.Chat.Socket do
  @moduledoc """
  The websocket the chat rides on.

  A thin wrapper over `websocket_client`, which is an ESP-IDF component: the
  TCP connection, the TLS session and the framing all live on its own FreeRTOS
  task, and Erlang sees whole messages. `Badge.Chat.Link` owns the port this
  hands back and receives:

      {:websocket, port, :connected}
      {:websocket, port, {:text, binary}}
      {:websocket, port, {:closed, reason}}
      {:websocket, port, {:error, reason}}

  The client reconnects on its own, so `:connected` arrives on every
  reconnection rather than once. Phoenix keeps channel state on the server and
  loses it with the socket, so the channel has to be re-joined every time.

  TLS is the component's, not AtomVM's. `:ssl` pins TLS 1.2, which is why the
  long poll this replaced ran in the clear; esp-tls does 1.3.

  The server is the `chat_url` NVS key, falling back to the compiled default.
  Its scheme chooses the transport: `wss://` verifies against the public CA
  bundle in the image, `ws://` runs in the clear for a server on the bench.
  """

  @compile {:no_warn_undefined, :websocket_client}

  @default_url "wss://badge-chat.protolux.io"
  @path "/badge/socket/websocket"
  @vsn "2.0.0"

  @network_timeout 30_000

  @doc "The server a badge talks to when nothing is provisioned."
  @spec default_url() :: binary
  def default_url, do: @default_url

  @doc "The provisioned server, or the compiled default when there is none."
  @spec base_url(binary | nil) :: binary
  def base_url(nil), do: @default_url
  def base_url(""), do: @default_url
  def base_url(url), do: url

  @doc """
  Where to connect, carrying the serializer version and who is asking, and any
  `extra` `{key, value}` pairs, such as a token.
  """
  @spec url(binary, binary, binary, [{binary, binary}]) :: binary
  def url(base, chip, name, extra \\ []) do
    trim(base) <> @path <> "?" <> query([{"vsn", @vsn}, {"chip", chip}, {"name", name} | extra])
  end

  @doc "Everything the driver is handed, so the transport choice can be read off."
  @spec opts(binary, binary, binary, [{binary, binary}]) :: map
  def opts(base, chip, name, extra \\ []) do
    %{
      url: url(base, chip, name, extra),
      owner: self(),
      # Without an explicit verify the driver disables verification and warns.
      verify: verify(base),
      # A TLS 1.3 handshake takes the badge past the ten second default, and a
      # timeout there looks like a dead server.
      network_timeout_ms: @network_timeout
    }
  end

  @doc """
  Opens the connection, answering once the port exists rather than once it is
  up. Wait for `:connected` before sending.
  """
  @spec open(binary, binary, binary, [{binary, binary}]) :: {:ok, port} | {:error, term}
  def open(base, chip, name, extra \\ []) do
    :websocket_client.open(opts(base, chip, name, extra))
  end

  defp verify("ws://" <> _), do: :none
  defp verify(_), do: :crt_bundle

  # binary_part rather than a sized pattern, which AtomVM is fussier about.
  defp trim(base) do
    last = byte_size(base) - 1

    case last >= 0 and binary_part(base, last, 1) == "/" do
      true -> binary_part(base, 0, last)
      false -> base
    end
  end

  @doc "Sends one frame, refusing rather than queueing while the link is down."
  @spec send_frame(port, binary) :: :ok | {:error, term}
  def send_frame(port, frame), do: :websocket_client.send_text(port, frame)

  @doc "Closes the connection and destroys the port."
  @spec close(port) :: :ok
  def close(port), do: :websocket_client.close(port)

  defp query(pairs), do: query(pairs, <<>>)

  defp query([], acc), do: acc

  defp query([{key, value} | rest], <<>>), do: query(rest, key <> "=" <> escape(value, <<>>))

  defp query([{key, value} | rest], acc),
    do: query(rest, acc <> "&" <> key <> "=" <> escape(value, <<>>))

  defp escape(<<>>, acc), do: acc

  defp escape(<<char, rest::binary>>, acc) when char >= ?a and char <= ?z,
    do: escape(rest, acc <> <<char>>)

  defp escape(<<char, rest::binary>>, acc) when char >= ?A and char <= ?Z,
    do: escape(rest, acc <> <<char>>)

  defp escape(<<char, rest::binary>>, acc) when char >= ?0 and char <= ?9,
    do: escape(rest, acc <> <<char>>)

  defp escape(<<char, rest::binary>>, acc)
       when char == ?- or char == ?_ or char == ?. or char == ?~,
       do: escape(rest, acc <> <<char>>)

  defp escape(<<char, rest::binary>>, acc) do
    escape(rest, acc <> "%" <> <<hex(div(char, 16)), hex(rem(char, 16))>>)
  end

  defp hex(value) when value < 10, do: ?0 + value
  defp hex(value), do: ?A + value - 10
end
