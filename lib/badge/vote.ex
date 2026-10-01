defmodule Badge.Vote do
  @moduledoc """
  The murder mystery ballot: the suspects, when voting opens, and the one
  vote this badge may cast.

  A suspect is `{id, name, colour}`. The vote is stored under the NVS
  key `vote` once the server has accepted it, and a badge holding one cannot
  vote again.

  `cast/2` blocks on the network and belongs in a process of its own; `start/3`
  runs it in one and reports back.
  """

  @compile {:no_warn_undefined, [:ahttp_client, :ssl]}

  @host "oban-murders.fly.dev"
  @port 443
  @path "/api/vote"
  @url "https://" <> @host <> @path

  # Zero reads whatever has arrived; a length waits for exactly that many bytes.
  @chunk 0
  @reads 16

  # 15:40 Stockholm summer time on 1 October 2026, until that day ends there.
  @opens_at DateTime.to_unix(~U[2026-10-01 13:40:00Z])
  @closes_at DateTime.to_unix(~U[2026-10-01 22:00:00Z])

  @suspects [
    {"journalist", "The Journalist", 0xFACC15},
    {"accountant", "The Accountant", 0x38BDF8},
    {"mechanic", "The Mechanic", 0xF97316},
    {"surveyor", "The Surveyor", 0x84CC16},
    {"postmaster", "The Postmaster", 0xC084FC},
    {"constable", "The Constable", 0x60A5FA},
    {"lineman", "The Lineman", 0x2DD4BF},
    {"doctor", "The Doctor", 0xF5F5F4},
    {"chief", "The Chief", 0xF472B6}
  ]

  # A wall clock before 2024 has not been synced.
  @floor 1_704_067_200

  @key :vote

  @doc "Every suspect, in ballot order."
  def suspects, do: @suspects

  @doc "How many suspects are on the ballot."
  def count, do: length(@suspects)

  @doc "The suspect at a zero-based ballot position."
  def at(index), do: :lists.nth(index + 1, @suspects)

  @doc "The ballot position of a suspect id, or nil for one not on it."
  def index(id), do: index(id, @suspects, 0)

  @doc "When voting opens, in UTC epoch seconds."
  def opens_at, do: @opens_at

  @doc "When voting closes, in UTC epoch seconds."
  def closes_at, do: @closes_at

  @doc "Where the vote is sent."
  def url, do: @url

  @doc """
  `:clock` until the clock is synced, then `:locked` before voting opens,
  `:open` while it runs and `:closed` after.
  """
  @spec phase(integer, integer, integer) :: :clock | :locked | :open | :closed
  def phase(now, _opens_at, _closes_at) when now < @floor, do: :clock
  def phase(now, opens_at, _closes_at) when now < opens_at, do: :locked
  def phase(now, _opens_at, closes_at) when now < closes_at, do: :open
  def phase(_now, _opens_at, _closes_at), do: :closed

  @doc "Seconds left as `2d 04:13:22`, or `04:13:22` under a day."
  @spec countdown(integer) :: binary
  def countdown(seconds) when seconds < 0, do: countdown(0)

  def countdown(seconds) when seconds < 86_400, do: Badge.Clock.format(seconds)

  def countdown(seconds) do
    :erlang.integer_to_binary(div(seconds, 86_400)) <> "d " <> Badge.Clock.format(seconds)
  end

  @doc "The name a vote is cast under: the badge's name, then its chip id."
  @spec voter(binary, binary) :: binary
  def voter(<<>>, chip), do: chip
  def voter(name, chip), do: name <> " " <> chip

  @doc "The JSON body of a vote for the suspect with this id."
  @spec body(binary, binary) :: binary
  def body(voter, id) do
    {^id, suspect, _colour} = at(index(id))

    :erlang.iolist_to_binary(:json.encode(%{"name" => voter, "suspect" => suspect}))
  end

  @doc "The suspect this badge already voted for, or nil."
  @spec load() :: binary | nil
  def load do
    case Badge.Nvs.get(@key) do
      nil -> nil
      id -> if index(id) == nil, do: nil, else: id
    end
  end

  @doc "Casts a vote in a new process, which sends `{:vote, pid, result}` to `owner`."
  @spec start(pid, binary, binary) :: pid
  def start(owner, voter, id) do
    spawn(fn -> send(owner, {:vote, self(), cast(voter, id)}) end)
  end

  @doc "Sends a vote, then stores it so it cannot be cast again."
  @spec cast(binary, binary) :: :ok | {:error, term}
  def cast(voter, id) do
    body = body(voter, id)
    started = now()
    log(started, ~c"POST ~s ~s", [@url, body])

    case post(body, started) do
      :ok ->
        log(started, ~c"accepted", [])
        stored = save(id)
        log(started, ~c"stored ~s: ~p", [id, stored])
        stored

      {:error, reason} = error ->
        log(started, ~c"failed ~p", [reason])
        error
    end
  end

  defp post(body, started) do
    log(started, ~c"ssl start ~p", [:ssl.start()])
    log(started, ~c"connecting to ~s:~p", [@host, @port])

    case :ahttp_client.connect(:https, @host, @port, active: false, verify: :verify_peer) do
      {:ok, conn} ->
        log(started, ~c"connected", [])
        request(conn, body, started)

      {:error, reason} ->
        log(started, ~c"connect failed ~p", [reason])
        {:error, {:connect, reason}}
    end
  catch
    kind, error ->
      log(started, ~c"crashed ~p ~p", [kind, error])
      {:error, {kind, error}}
  end

  defp request(conn, body, started) do
    headers = [{"Content-Type", "application/json"}]

    case :ahttp_client.request(conn, "POST", @path, headers, body) do
      {:ok, conn, _ref} ->
        log(started, ~c"request sent, ~p bytes", [byte_size(body)])
        collect(conn, nil, @reads, started)

      {:error, reason} ->
        log(started, ~c"request failed ~p", [reason])
        close(conn, {:error, {:request, reason}})
    end
  end

  defp collect(conn, _status, 0, _started), do: close(conn, {:error, :too_many_reads})

  defp collect(conn, status, left, started) do
    case :ahttp_client.recv(conn, @chunk) do
      {:ok, conn, responses} ->
        log(started, ~c"received ~p", [responses])

        case harvest(responses, status, false) do
          {status, true} -> close(conn, accepted(status))
          {status, false} -> collect(conn, status, left - 1, started)
        end

      {:error, reason} ->
        log(started, ~c"recv failed ~p", [reason])
        close(conn, {:error, {:recv, reason}})
    end
  end

  # Each line carries the time since the vote began and the free heap.
  defp log(started, format, args) do
    :io.format(~c"Vote: +~pms heap=~p " ++ format ++ ~c"~n", [now() - started, heap() | args])
  end

  defp now, do: :erlang.monotonic_time(:millisecond)

  defp heap do
    :erlang.system_info(:esp32_free_heap_size)
  catch
    _kind, _error -> :unknown
  end

  defp harvest([], status, done), do: {status, done}
  defp harvest([{:status, _ref, code} | rest], _status, done), do: harvest(rest, code, done)
  defp harvest([{:done, _ref} | rest], status, _done), do: harvest(rest, status, true)
  defp harvest([:done | rest], status, _done), do: harvest(rest, status, true)
  defp harvest([_other | rest], status, done), do: harvest(rest, status, done)

  @doc "Whether an HTTP status means the server holds this badge's vote; 409 is one it already had."
  @spec accepted(integer | nil) :: :ok | {:error, term}
  def accepted(code) when is_integer(code) and code >= 200 and code < 300, do: :ok
  def accepted(409), do: :ok
  def accepted(code), do: {:error, {:status, code}}

  defp close(conn, result) do
    :ahttp_client.close(conn)

    result
  end

  @doc "Stores the vote this badge cast."
  @spec save(binary) :: :ok | {:error, term}
  def save(id) do
    case Badge.Nvs.put(@key, id) do
      :ok ->
        :ok

      error ->
        :io.format(~c"Vote: cannot store vote: ~p~n", [error])
        error
    end
  end

  defp index(_id, [], _n), do: nil
  defp index(id, [{id, _name, _colour} | _rest], n), do: n
  defp index(id, [_suspect | rest], n), do: index(id, rest, n + 1)
end
