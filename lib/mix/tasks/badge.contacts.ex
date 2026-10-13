defmodule Mix.Tasks.Badge.Contacts do
  @shortdoc "Exports the contacts saved on the badge to badge_contacts.csv"

  @moduledoc """
  Reads the badge's NVS partition over USB and writes the badges it has
  collected (`Badge.Peers`, NVS key `badge/peers`) to a CSV file, most
  recently met first.

      mix badge.contacts                    # badge_contacts.csv
      mix badge.contacts --out people.csv
      mix badge.contacts --from nvs.bin     # parse a saved NVS dump instead

  Reading resets the badge. Nothing is written to it.
  """

  use Mix.Task

  alias Badge.Identity
  alias Badge.Peers
  alias Badge.Profile

  @nvs_offset 0x9000
  @nvs_size 0x6000
  @out "badge_contacts.csv"

  @impl Mix.Task
  def run(args) do
    {options, _rest} = OptionParser.parse!(args, strict: [out: :string, from: :string])
    out = Keyword.get(options, :out, @out)

    image =
      case options[:from] do
        nil -> read_nvs()
        path -> File.read!(path)
      end

    peers = image |> blob("badge", "peers") |> Peers.decode()
    File.write!(out, csv(peers))

    Mix.shell().info("badge.contacts: #{length(peers)} contacts written to #{out}")
  end

  defp read_nvs do
    :ok = ExAtomVM.EsptoolHelper.setup()
    port = ExAtomVM.EsptoolHelper.select_device()["port"]

    case ExAtomVM.EsptoolHelper.read_flash_with_size(port, @nvs_offset, @nvs_size, true) do
      {:ok, %{"data" => data}} -> data
      {:error, reason} -> Mix.raise("badge.contacts: could not read NVS: #{inspect(reason)}")
    end
  end

  # ---------------------------------------------------------------- the CSV

  @doc "The contacts as CSV: a header, then one row per badge."
  @spec csv([map]) :: binary
  def csv(peers) do
    fields = for {key, label, _capacity, _icon} <- Profile.fields(), key != :qr, do: {key, label}

    header = ["Chip ID" | for({_key, label} <- fields, do: label)]

    rows =
      for %{id: id, profile: profile} <- peers do
        [Identity.format(id) | for({key, _label} <- fields, do: Map.get(profile, key, ""))]
      end

    Enum.map_join(
      [header | rows],
      "",
      &(Enum.map_join(&1, ",", fn cell -> cell(cell) end) <> "\r\n")
    )
  end

  defp cell(value) when is_binary(value) do
    if String.contains?(value, [",", "\"", "\r", "\n"]) do
      "\"" <> String.replace(value, "\"", "\"\"") <> "\""
    else
      value
    end
  end

  defp cell(value), do: cell(to_string(value))

  # ------------------------------------------------------------ the NVS image

  # ESP-IDF's NVS format: 4096-byte pages, each a 32-byte header, a 32-byte
  # bitmap holding two bits of state per entry, and 126 entries of 32 bytes.
  # An entry is namespace index, type, span, chunk index, CRC, a 16-byte key
  # and 8 bytes of data; a string or blob chunk continues in the next
  # `span - 1` entries.
  @page 4096
  @entries 126
  @written 0b10

  @u8 0x01
  @blob 0x41
  @blob_data 0x42
  @blob_index 0x48
  @string 0x21

  @doc """
  The blob stored under `key` in `namespace` in an NVS partition image, or
  `nil`. Handles both the chunked blobs ESP-IDF writes now and the single-entry
  ones of the old format.
  """
  @spec blob(binary, binary, binary) :: binary | nil
  def blob(image, namespace, key) do
    entries = entries(image)

    with ns when is_integer(ns) <- namespace_index(entries, namespace) do
      chunked(entries, ns, key) || single(entries, ns, key)
    end
  end

  defp namespace_index(entries, name) do
    Enum.find_value(entries, fn
      %{ns: 0, type: @u8, key: ^name, data: <<index, _::binary>>} -> index
      _entry -> nil
    end)
  end

  defp chunked(entries, ns, key) do
    index =
      entries
      |> Enum.filter(&match?(%{ns: ^ns, type: @blob_index, key: ^key}, &1))
      |> Enum.max_by(& &1.seq, fn -> nil end)

    case index do
      %{data: <<size::little-32, count, start, _::binary>>} ->
        chunks =
          entries
          |> Enum.filter(fn entry ->
            match?(%{ns: ^ns, type: @blob_data, key: ^key}, entry) and
              entry.chunk >= start and entry.chunk < start + count
          end)
          |> Enum.sort_by(& &1.chunk)
          |> Enum.map_join(& &1.payload)

        if byte_size(chunks) >= size, do: binary_part(chunks, 0, size), else: nil

      nil ->
        nil
    end
  end

  defp single(entries, ns, key) do
    Enum.find_value(entries, fn
      %{ns: ^ns, type: @blob, key: ^key, payload: payload} -> payload
      _entry -> nil
    end)
  end

  defp entries(image) do
    for <<page::binary-size(@page) <- image>>,
        entry <- page_entries(page),
        do: entry
  end

  defp page_entries(
         <<state::little-32, seq::little-32, _rest::binary-24, bitmap::binary-32, body::binary>>
       )
       when state not in [0xFFFFFFFF, 0xFFFFFFF0] do
    walk(body, bitmap, seq, 0, [])
  end

  defp page_entries(_page), do: []

  defp walk(_body, _bitmap, _seq, i, acc) when i >= @entries, do: Enum.reverse(acc)

  defp walk(body, bitmap, seq, i, acc) do
    <<ns, type, span, chunk, _crc::32, raw_key::binary-16, data::binary-8>> =
      binary_part(body, i * 32, 32)

    cond do
      state(bitmap, i) != @written ->
        walk(body, bitmap, seq, i + 1, acc)

      span < 1 or i + span > @entries ->
        walk(body, bitmap, seq, i + 1, acc)

      true ->
        entry = %{
          seq: seq,
          ns: ns,
          type: type,
          chunk: chunk,
          key: key(raw_key),
          data: data,
          payload: payload(type, data, binary_part(body, (i + 1) * 32, (span - 1) * 32))
        }

        walk(body, bitmap, seq, i + span, [entry | acc])
    end
  end

  # Two bits per entry, four entries to a byte, lowest bits first.
  defp state(bitmap, i) do
    <<_::binary-size(div(i, 4)), byte, _::binary>> = bitmap
    Bitwise.band(Bitwise.bsr(byte, rem(i, 4) * 2), 0b11)
  end

  defp key(raw), do: raw |> :binary.split(<<0>>) |> hd()

  defp payload(type, <<size::little-16, _::binary>>, rest)
       when type in [@string, @blob, @blob_data] and size <= byte_size(rest),
       do: binary_part(rest, 0, size)

  defp payload(_type, _data, _rest), do: <<>>
end
