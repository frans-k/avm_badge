defmodule Badge.Page.Splash do
  @moduledoc """
  The Goatmire logo, arriving in pieces on boot.

  The logo is cut into a grid of uneven rectangles. On the way in they appear
  one after another in a shuffled order, each landing with a sideways jitter
  that settles in two frames, until the whole logo is still. It holds, then
  the pieces drop out in another shuffled order, and the page hands over to
  Home. Any key ends it early; a badge waking from deep sleep, or one where
  the logo cannot be read, does not show it at all.

  The cut and both orders come from one seed, so a frame is a pure function
  of the step and the seed and the sequence is testable on the host.
  """

  use Badge.Page

  alias Badge.Logo
  alias Badge.Page.Home
  alias Badge.Theme

  @compile {:no_warn_undefined, :esp}

  @width Theme.width()
  @height Theme.height()

  # The logo is composited onto black, so the panel behind it is black on every skin.
  @black 0x000000

  @frame_ms 100
  @in_frames 10
  @hold_ms 2_000
  @out_frames 6
  @total_ms (@in_frames + @out_frames) * @frame_ms + @hold_ms

  # The UI is up within a few seconds of the chip; anything later is a restart.
  @boot_ms 10_000

  # The cut is in logo pixels; the logo is drawn scaled, so the origin is not.
  @logo_w elem(Logo.size(), 0)
  @logo_h elem(Logo.size(), 1)
  @x div(@width - @logo_w * Logo.scale(), 2)
  @y div(@height - @logo_h * Logo.scale(), 2)

  @band_min 3
  @band_max 7
  @column_min 20
  @column_max 50

  # Jitter on the frame a piece lands, then the frame after, in pixels.
  @jitter_landing 10
  @jitter_after 3

  @impl true
  def title, do: "Goatmire"

  @impl true
  def refresh(_state), do: @frame_ms

  # The cover hides the whole panel, title bar included.
  @impl true
  def chrome?(_state), do: false

  # Everything a frame can reuse is built here, once: on AtomVM each pass over
  # the ~50 pieces costs about a millisecond a piece, so a frame only builds
  # the few pieces that are moving. The clock starts on the first tick, not
  # here, because the page is made while the rest of the badge is still
  # starting and the first frame can be seconds away.
  @impl true
  def init do
    seed = rem(abs(:erlang.monotonic_time(:millisecond)), 1_000_003) + 1

    %{
      started: nil,
      seed: seed,
      cut: prepare(seed, Logo.image()),
      step: {:in, 0},
      done: false
    }
  end

  @doc "Whether this start should show the splash: see `wanted?/3`."
  @spec wanted?() :: boolean
  def wanted?, do: wanted?(reset_reason(), :erlang.monotonic_time(:millisecond), logo())

  @doc """
  Whether a start of the UI should show the splash, given the chip's reset
  reason, how long it has been up and the logo, if it could be read. A boot does, unless it is a wake from deep sleep; a UI restart later in
  the same boot does not, and nor does a badge with nothing to show.
  """
  @spec wanted?(atom, integer, tuple | nil) :: boolean
  def wanted?(_reason, _uptime_ms, nil), do: false

  def wanted?(reason, uptime_ms, _image) do
    reason != :esp_rst_deepsleep and uptime_ms < @boot_ms
  end

  defp logo do
    case Logo.image() do
      nil ->
        :io.format(~c"Splash: no logo in priv~n")

        nil

      image ->
        image
    end
  end

  defp reset_reason do
    :esp.reset_reason()
  catch
    _kind, _error -> :esp_rst_unknown
  end

  @impl true
  def tick(%{done: true}), do: {:goto, Home}

  def tick(%{started: nil} = state) do
    %{state | started: :erlang.monotonic_time(:millisecond), step: {:in, 0}}
  end

  def tick(state) do
    elapsed = :erlang.monotonic_time(:millisecond) - state.started

    case elapsed >= @total_ms do
      true -> {:goto, Home}
      false -> %{state | step: step(elapsed)}
    end
  end

  @impl true
  def handle_key(_event, state), do: {:ok, %{state | done: true}}

  # Wi-Fi holds its radio while the splash shows; see `Badge.Wifi.release/0`.
  @impl true
  def leave(_state), do: Badge.Wifi.release()

  @impl true
  def render(state), do: draw(state.step, state.cut)

  @doc """
  Which part of the sequence `elapsed` milliseconds falls in, and the frame within it.

  The hold is one step, so the page does not repaint while nothing moves.
  """
  @spec step(non_neg_integer) :: {:in | :hold | :out, non_neg_integer}
  def step(elapsed) when elapsed < @in_frames * @frame_ms, do: {:in, div(elapsed, @frame_ms)}

  def step(elapsed) when elapsed < @in_frames * @frame_ms + @hold_ms, do: {:hold, 0}

  def step(elapsed) do
    {:out, div(elapsed - @in_frames * @frame_ms - @hold_ms, @frame_ms)}
  end

  @doc "Display items for one step of the sequence, drawing `image`; only the cover without one."
  @spec frame({atom, non_neg_integer}, pos_integer, tuple | nil) :: [tuple]
  def frame(step, seed, image), do: draw(step, prepare(seed, image))

  # The pieces in landing order as a tuple, each piece's item at rest built
  # once and kept latest-landing first, so the pieces at rest in any frame are
  # a tail of that list and cost nothing to take, and each piece's jitter
  # direction.
  defp prepare(_seed, nil), do: nil

  defp prepare(seed, image) do
    pieces = pieces(seed)

    %{
      image: image,
      count: length(pieces),
      pieces: :erlang.list_to_tuple(for({piece, _index} <- pieces, do: piece)),
      rest: :lists.reverse(for({piece, _index} <- pieces, do: item(piece, 0, image))),
      signs: :erlang.list_to_tuple(for({_piece, index} <- pieces, do: sign(seed, index)))
    }
  end

  defp draw(_step, nil), do: [cover()]
  defp draw({:hold, _n}, cut), do: [Logo.item(@x, @y, cut.image), cover()]

  # In landing order, the pieces down by frame `n` are a prefix; those that
  # landed in the last two frames are still jittering.
  defp draw({:in, n}, cut) do
    landed = landed_by(n, cut.count, @in_frames)
    resting = landed_by(n - 2, cut.count, @in_frames)

    moving(cut, resting, landed, fn index -> n - land_frame(index, cut.count, @in_frames) end) ++
      at_rest(cut, resting) ++ [cover()]
  end

  # On the way out the pieces still up are a prefix too, and those about to go
  # jitter first.
  defp draw({:out, n}, cut) do
    up = still_up(n, cut.count)
    resting = still_up(n + 2, cut.count)

    moving(cut, resting, up, fn index -> gone(index, cut.count) - 1 - n end) ++
      at_rest(cut, resting) ++ [cover()]
  end

  defp at_rest(cut, resting), do: :lists.nthtail(cut.count - resting, cut.rest)

  defp moving(_cut, from, to, _age) when from >= to, do: []

  defp moving(cut, from, to, age) do
    piece = :erlang.element(from + 1, cut.pieces)
    slide = jitter(age.(from), :erlang.element(from + 1, cut.signs))

    [item(piece, slide, cut.image) | moving(cut, from + 1, to, age)]
  end

  # How many pieces, in landing order, have landed by frame `n`.
  defp landed_by(n, _count, _frames) when n < 0, do: 0
  defp landed_by(n, count, frames), do: min(count, div((n + 1) * count + frames - 1, frames))

  # How many pieces, in landing order, are still up after frame `n` of the way out.
  defp still_up(n, count), do: max(count - div((n + 1) * count + @out_frames - 1, @out_frames), 0)

  defp gone(index, count), do: land_frame(count - 1 - index, count, @out_frames)

  @doc "How long the whole sequence runs, in milliseconds."
  def total_ms, do: @total_ms

  @doc """
  The logo cut into pieces, each with its place in the arrival order.

  Rows of uneven height, each split into columns of uneven width, shuffled.
  """
  @spec pieces(pos_integer) :: [{{integer, integer, integer, integer}, non_neg_integer}]
  def pieces(seed) do
    rects = rows(seed, 0, [])

    rects
    |> shuffle(mix(seed, 17))
    |> index(0, [])
  end

  # Last, so it is painted first: under the pieces, over the skin's bar and background.
  defp cover, do: {:rect, 0, 0, @width, @height, @black}

  defp item({left, top, width, height}, slide, image) do
    Logo.piece(@x, @y, left, top, width, height, slide, image)
  end

  # The frame at which the piece with this place in the order lands.
  defp land_frame(index, count, frames), do: div(index * frames, count)

  # A push one way on landing, a smaller one back, then still.
  defp jitter(0, sign), do: clamp(sign * @jitter_landing)
  defp jitter(1, sign), do: clamp(-sign * @jitter_after)
  defp jitter(_age, _sign), do: 0

  defp sign(seed, index) do
    {roll, _next} = roll(mix(seed, index * 7 + 3))
    1 - 2 * rem(roll, 2)
  end

  # A jitter must not push a piece off the panel; the margin either side is what it may use.
  defp clamp(slide), do: max(min(slide, @x), -@x)

  defp rows(_seed, top, acc) when top >= @logo_h, do: :lists.reverse(acc)

  defp rows(seed, top, acc) do
    {roll, next} = roll(seed)
    height = min(@band_min + rem(roll, @band_max - @band_min + 1), @logo_h - top)

    rows(next, top + height, columns(next, top, height, 0, acc))
  end

  defp columns(_seed, _top, _height, left, acc) when left >= @logo_w, do: acc

  defp columns(seed, top, height, left, acc) do
    {roll, next} = roll(mix(seed, left))
    width = min(@column_min + rem(roll, @column_max - @column_min + 1), @logo_w - left)

    columns(next, top, height, left + width, [{left, top, width, height} | acc])
  end

  # Sort by a random key per piece, since AtomVM has no `Enum.shuffle/1`.
  defp shuffle(rects, seed) do
    keyed =
      for {left, top, width, height} = rect <- rects do
        {elem(roll(mix(seed, left * 131 + top * 17 + width * 7 + height)), 0), rect}
      end

    for {_key, rect} <- :lists.sort(keyed), do: rect
  end

  defp index([], _n, acc), do: :lists.reverse(acc)
  defp index([rect | rest], n, acc), do: index(rest, n + 1, [{rect, n} | acc])

  # A small linear congruential generator, since AtomVM ships no `rand`.
  defp roll(seed) do
    next = rem(seed * 1_103_515_245 + 12_345, 2_147_483_648)

    {div(next, 65_536), next}
  end

  defp mix(seed, salt), do: rem(seed * 31 + salt * 7 + 1, 2_147_483_648)
end
