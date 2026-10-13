defmodule Mix.Tasks.Badge.ContactsTest do
  use ExUnit.Case, async: true

  alias Badge.Peers
  alias Mix.Tasks.Badge.Contacts

  # ESP-IDF NVS, built by hand: a page is a header, a state bitmap and 126
  # entries of 32 bytes.
  @written 0b10
  @erased 0b00
  @empty 0b11

  defp entry(ns, type, span, chunk, key, data) do
    padded = key <> :binary.copy(<<0>>, 16 - byte_size(key))
    <<ns, type, span, chunk, 0::32, padded::binary, data::binary-8>>
  end

  defp continued(payload) do
    padding = rem(32 - rem(byte_size(payload), 32), 32)
    payload <> :binary.copy(<<0xFF>>, padding)
  end

  defp data_chunk(ns, key, chunk, payload) do
    span = 1 + div(byte_size(payload) + 31, 32)
    head = entry(ns, 0x42, span, chunk, key, <<byte_size(payload)::little-16, 0xFFFF::16, 0::32>>)
    {head <> continued(payload), span}
  end

  # `slots` are {binary, span, state}; anything unused is empty.
  defp page(slots, seq \\ 0) do
    {body, states} =
      Enum.reduce(slots, {<<>>, []}, fn {bytes, span, state}, {body, states} ->
        {body <> bytes, states ++ List.duplicate(state, span)}
      end)

    states = states ++ List.duplicate(@empty, 126 - length(states))

    bitmap =
      for group <- Enum.chunk_every(states, 4), into: <<>> do
        [a, b, c, d] = group ++ List.duplicate(@empty, 4 - length(group))
        <<d::2, c::2, b::2, a::2>>
      end

    body = body <> :binary.copy(<<0xFF>>, 126 * 32 - byte_size(body))

    <<0xFFFFFFFC::little-32, seq::little-32, 0xFE, 0::size(19 * 8), 0::32>> <> bitmap <> body
  end

  defp nvs(peers) do
    blob = Peers.encode(peers)
    {first, second} = String.split_at(blob, div(byte_size(blob), 2))
    {chunk0, span0} = data_chunk(3, "peers", 0, first)
    {chunk1, span1} = data_chunk(3, "peers", 1, second)
    {stale, stale_span} = data_chunk(3, "peers", 0, "old bytes")

    page([
      {entry(0, 0x01, 1, 0xFF, "badge", <<3, 0::56>>), 1, @written},
      {entry(0, 0x01, 1, 0xFF, "other", <<4, 0::56>>), 1, @written},
      {stale, stale_span, @erased},
      {chunk0, span0, @written},
      {chunk1, span1, @written},
      {entry(3, 0x48, 1, 0xFF, "peers", <<byte_size(blob)::little-32, 2, 0, 0::16>>), 1, @written}
    ]) <> page([], 1)
  end

  @peers [
    %{
      id: <<0x90, 0xDA, 0x72, 0, 0, 1>>,
      profile: %{name: "Goat McMire", email: "goat@goatmire.com"}
    },
    %{id: <<0xA0, 0xF2, 0x62, 0xEE, 0x6E, 0x84>>, profile: %{name: "Smith, \"Jo\"", github: "jo"}}
  ]

  describe "reading NVS" do
    test "reassembles a chunked blob, skipping erased entries" do
      assert Contacts.blob(nvs(@peers), "badge", "peers") == Peers.encode(@peers)
    end

    test "answers nil for a key or namespace that is not there" do
      assert Contacts.blob(nvs(@peers), "badge", "nothing") == nil
      assert Contacts.blob(nvs(@peers), "nowhere", "peers") == nil
    end

    test "an erased flash is no contacts" do
      assert Contacts.blob(:binary.copy(<<0xFF>>, 0x6000), "badge", "peers") == nil
      assert Peers.decode(nil) == []
    end
  end

  describe "the CSV" do
    test "has a header naming the chip id and every profile field but the QR choice" do
      [header | _rows] = String.split(Contacts.csv([]), "\r\n")

      assert header == "Chip ID,Name,Company,Email,GitHub,LinkedIn,Mastodon,Bluesky,Link"
    end

    test "one row per contact, most recently met first, missing fields empty" do
      [_header, first, second, ""] = String.split(Contacts.csv(@peers), "\r\n")

      assert first == "90DA72000001,Goat McMire,,goat@goatmire.com,,,,,"
      assert second == "A0F262EE6E84,\"Smith, \"\"Jo\"\"\",,,jo,,,,"
    end
  end

  test "the task writes the file from a saved dump" do
    dir = Path.join(System.tmp_dir!(), "contacts-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dump = Path.join(dir, "nvs.bin")
    out = Path.join(dir, "out.csv")
    File.write!(dump, nvs(@peers))

    ExUnit.CaptureIO.capture_io(fn -> Contacts.run(["--from", dump, "--out", out]) end)

    assert File.read!(out) == Contacts.csv(@peers)
  end
end
