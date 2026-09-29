defmodule Badge.Raycaster.Room do
  @moduledoc """
  What a badge says to the raycaster relay and what it says back, as Phoenix channel
  frames built and read with `Badge.Chat.Wire`, the module the chat already uses.

    * to join: `phx_join` on `raycaster:lobby`; the answer says which slot this badge has
    * to say where it stands: `pos`, `{"x": .., "y": ..}`; no answer
    * once a second the server sends `snap`, `{"p": [[slot, x, y], ...]}`: everyone in
      the room, this badge too, by slot
    * `heartbeat` on `phoenix` now and then, or Phoenix drops a quiet connection

  The server is open to anyone who has its address, so a snapshot with anything odd in
  it is refused whole: a position must be a whole number inside the 16 by 16 map.
  """

  alias Badge.Chat.Wire

  @topic "raycaster:lobby"

  # The map is 16 cells across, 256 to a cell.
  @limit 4_096

  # More than a room holds is not a snapshot of a room.
  @room_max 16

  @colours {0xE0433A, 0x3AA0E0, 0x3AE07A, 0xE0C93A, 0xB03AE0, 0xE07A3A, 0x3AE0D4, 0xE03A9A}

  @spec join(binary) :: binary
  def join(ref), do: Wire.encode(ref, ref, @topic, "phx_join", %{})

  @spec pos(binary, binary, integer, integer) :: binary
  def pos(join_ref, ref, x, y), do: Wire.encode(join_ref, ref, @topic, "pos", %{"x" => x, "y" => y})

  @spec heartbeat() :: binary
  def heartbeat, do: Wire.encode(nil, "0", "phoenix", "heartbeat", %{})

  @doc "The colour a slot is drawn in."
  @spec colour(pos_integer) :: non_neg_integer
  def colour(slot), do: elem(@colours, rem(slot - 1, tuple_size(@colours)))

  @doc """
  Reads a frame from the server, given this badge's own slot (nil before it has one):
  `{:joined, slot}`, `{:players, [{x, y, colour}]}` without this badge in it, or `:ignore`.
  """
  @spec interpret(binary, integer | nil) ::
          {:joined, pos_integer} | {:players, [{integer, integer, integer}]} | :ignore
  def interpret(frame, own_slot) do
    case Wire.decode_frame(frame) do
      {:ok, %{topic: @topic, event: "phx_reply", payload: %{"status" => "ok", "response" => %{"slot" => slot, "max" => max}}}}
      when is_integer(slot) and is_integer(max) and slot > 0 and slot <= max ->
        {:joined, slot}

      {:ok, %{topic: @topic, event: "snap", payload: %{"p" => players}}}
      when is_list(players) and length(players) <= @room_max ->
        players(players, own_slot, [])

      _other ->
        :ignore
    end
  end

  defp players([], _own, acc), do: {:players, :lists.reverse(acc)}

  defp players([[slot, x, y] | rest], own, acc)
       when is_integer(slot) and is_integer(x) and is_integer(y) and slot > 0 and x >= 0 and
              x < @limit and y >= 0 and y < @limit do
    if slot == own,
      do: players(rest, own, acc),
      else: players(rest, own, [{x, y, colour(slot)} | acc])
  end

  defp players(_odd, _own, _acc), do: :ignore
end
