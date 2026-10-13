defmodule Badge.Font do
  @moduledoc """
  Character widths for the fonts the badge registers.

  The `.uf` files are IFF: a `uFI0` record maps codepoint ranges to glyph
  indices, and a `uFP0` record holds packed glyphs whose third field is the
  advance width. Both are read here at compile time, on the host, so the
  panel never parses anything.

  Only a fixed-width font can be measured this cheaply, so `advance/1`
  answers `nil` for a proportional one rather than guessing.
  """

  @dir Path.expand("../../priv/fonts", __DIR__)

  @glyph_bytes 18
  @interval_bytes 12

  for file <- Path.wildcard(Path.join(@dir, "*.uf")) do
    @external_resource file
  end

  # Runs on the host compiler, where the full standard library is available.
  @advances (for path <- Path.wildcard(Path.join(@dir, "*.uf")), into: %{} do
               data = File.read!(path)

               records =
                 Stream.unfold(12, fn
                   position when position >= byte_size(data) ->
                     nil

                   position ->
                     <<name::binary-4, size::big-32>> = :binary.part(data, position, 8)
                     next = position + 8 + size
                     {{name, position + 8, size}, next + rem(4 - rem(next, 4), 4)}
                 end)
                 |> Enum.into(%{}, fn {name, offset, size} -> {name, {offset, size}} end)

               {header, _header_size} = Map.fetch!(records, "uFH0")

               <<_intervals::little-32, _compressed::8, line_height::little-16, _rest::binary>> =
                 :binary.part(data, header, 11)

               {glyphs, _glyph_size} = Map.fetch!(records, "uFP0")
               {intervals, interval_size} = Map.fetch!(records, "uFI0")

               widths =
                 for index <- 0..(div(interval_size, @interval_bytes) - 1),
                     <<first::little-32, last::little-32, offset::little-32>> =
                       :binary.part(data, intervals + index * @interval_bytes, @interval_bytes),
                     code <- first..last do
                   at = glyphs + (offset + code - first) * @glyph_bytes

                   <<_w::little-16, _h::little-16, advance::little-16>> =
                     :binary.part(data, at, 6)

                   advance
                 end

               codes =
                 for index <- 0..(div(interval_size, @interval_bytes) - 1),
                     <<first::little-32, last::little-32, _offset::little-32>> =
                       :binary.part(data, intervals + index * @interval_bytes, @interval_bytes),
                     code <- first..last do
                   code
                 end

               name = path |> Path.basename(".uf") |> String.to_atom()

               {name, {Enum.uniq(widths), Enum.zip(codes, widths) |> Enum.into(%{}), line_height}}
             end)

  @per_char for {name, {_widths, table, _height}} <- @advances, into: %{}, do: {name, table}

  @line_heights for {name, {_widths, _table, height}} <- @advances, into: %{}, do: {name, height}

  @fixed (for {name, {widths, _table, _height}} <- @advances, length(widths) == 1, into: %{} do
            {name, hd(widths)}
          end)

  @doc """
  Pixels each character advances, or nil when the font is proportional.

  A proportional font cannot be measured without the glyph table, which the
  panel keeps to itself, so text in one is left-aligned and never wrapped.
  """
  @spec advance(atom) :: pos_integer | nil
  def advance(:default16px), do: 8
  def advance(font), do: Map.get(@fixed, font)

  @doc "Every font whose characters are all the same width."
  def fixed_width, do: Map.keys(@fixed)

  @doc "How far one line of `font` sits below the last, in pixels."
  @spec line_height(atom) :: pos_integer | nil
  def line_height(:default16px), do: 16
  def line_height(font), do: Map.get(@line_heights, font)

  @doc """
  How wide `text` is in `font`, in pixels.

  Works for proportional fonts too, by summing each glyph's own advance.
  `nil` when the font was never registered, so a caller can tell "zero
  wide" from "no idea".
  """
  @spec width(atom, binary) :: non_neg_integer | nil
  def width(:default16px, text), do: 8 * byte_size(text)

  def width(font, text) do
    case Map.get(@per_char, font) do
      nil -> nil
      table -> sum(text, table, 0)
    end
  end

  @doc "Whether `text` fits within `pixels` when set in `font`."
  @spec fits?(atom, binary, integer) :: boolean
  def fits?(font, text, pixels) do
    case width(font, text) do
      nil -> false
      measured -> measured <= pixels
    end
  end

  # An unknown character contributes nothing rather than crashing the render.
  defp sum(<<>>, _table, total), do: total

  defp sum(<<char, rest::binary>>, table, total) do
    sum(rest, table, total + Map.get(table, char, 0))
  end
end
