defmodule Badge.Page.Vote do
  @moduledoc """
  The murder mystery ballot, from `Badge.Vote`.

  Until the clock passes `Badge.Vote.opens_at/0` the page shows a candle and
  a countdown; then the suspects, until `Badge.Vote.closes_at/0` closes the
  ballot. O opens the ballot regardless of the clock until the page is left.

  The list shows six suspects at a time, with a scrollbar and a line saying
  how many more lie below or above. Up and Down choose and scroll, Enter
  accuses, and a second Enter on the confirm screen sends the vote, while Esc
  backs out of it. A badge that has voted shows its sealed verdict and nothing else.

  The stored vote and the clock are read from `tick/1`, which also starts the
  worker that sends the vote; it answers through `handle_info/2`, and one that
  has not answered in about 20 s is killed.
  """

  use Badge.Page

  alias Badge.Identity
  alias Badge.Profile
  alias Badge.Theme
  alias Badge.Vote

  @top Theme.content_top()
  @w Theme.width()
  @h Theme.height() - @top

  @ink 0x0C0A12
  @blood 0x8B0A14
  @red 0xE11D2E
  @paper 0xEDE3CC
  @ash 0x7A7385
  @shade 0x2A2633
  @row_hi 0x2A0E14
  @flame 0xFFA41B
  @flame_core 0xFFF1B8
  @glow 0x2E1607
  @tape 0xF5C518

  # Every animation repeats within this many ticks, so the counter stays small.
  @period 2520
  @stamp_ticks 6
  @timeout_ticks 200

  @row_y @top + 32
  @pitch 24
  @shown 6
  @list_h @shown * @pitch - 2
  @more_y @top + 178

  @tape_text "CRIME SCENE - DO NOT CROSS  "
  @tape_loop @tape_text <> @tape_text <> @tape_text
  @tape_cols div(@w, 8)

  @drips [{22, 0}, {64, 1}, {101, 2}, {150, 3}, {197, 4}, {243, 5}, {290, 6}]

  @impl true
  def title, do: "Oban"

  @impl true
  def icon, do: :diamond

  @impl true
  def init do
    %{
      phase: :loading,
      t: 0,
      now: 0,
      opens_at: Vote.opens_at(),
      closes_at: Vote.closes_at(),
      cursor: 0,
      top: 0,
      choice: nil,
      voter: nil,
      worker: nil,
      skip: false
    }
  end

  @impl true
  def refresh(%{phase: :voted, t: t}) when t >= @stamp_ticks, do: 1000
  def refresh(_state), do: 100

  @impl true
  def tick(%{phase: :loading} = state) do
    case Vote.load() do
      nil ->
        voter = Vote.voter(Profile.load().name, Identity.format(Identity.chip_id()))
        clocked(%{state | phase: :clock, voter: voter}, :erlang.system_time(:second))

      id ->
        %{state | phase: :voted, choice: Vote.index(id), t: 0}
    end
  end

  def tick(%{phase: :sending} = state) do
    {id, _name, _colour} = Vote.at(state.choice)

    %{state | phase: :posting, worker: Vote.start(self(), state.voter, id), t: 0}
  end

  def tick(%{phase: :posting, t: t} = state) when t >= @timeout_ticks do
    Process.exit(state.worker, :kill)
    :io.format(~c"Vote: no answer, gave up~n")

    %{state | phase: :failed, worker: nil, t: 0}
  end

  def tick(%{phase: :voted, t: t} = state) when t >= @stamp_ticks, do: state

  def tick(state) do
    clocked(%{state | t: rem(state.t + 1, @period)}, :erlang.system_time(:second))
  end

  @doc "Takes a reading of the clock, opening and closing the ballot on time."
  def clocked(%{skip: true} = state, now), do: %{state | now: now}
  def clocked(%{phase: :clock} = state, now), do: phased(state, now)
  def clocked(%{phase: :locked} = state, now), do: phased(state, now)
  def clocked(%{phase: :open} = state, now), do: phased(state, now)
  def clocked(%{phase: :confirm} = state, now), do: confirming(phased(state, now))
  def clocked(state, now), do: %{state | now: now}

  defp phased(state, now) do
    %{state | now: now, phase: Vote.phase(now, state.opens_at, state.closes_at)}
  end

  defp confirming(%{phase: :open} = state), do: %{state | phase: :confirm}
  defp confirming(state), do: %{state | choice: nil}

  @impl true
  def handle_key({:char, ?o}, %{phase: phase} = state)
      when phase == :clock or phase == :locked or phase == :closed do
    {:ok, %{state | phase: :open, skip: true}}
  end

  def handle_key({:move, :up}, %{phase: :open} = state), do: {:ok, move(state, -1)}
  def handle_key({:move, :down}, %{phase: :open} = state), do: {:ok, move(state, 1)}

  def handle_key({:edit, :newline}, %{phase: :open} = state) do
    {:ok, %{state | phase: :confirm, choice: state.cursor, t: 0}}
  end

  def handle_key({:edit, :newline}, %{phase: :confirm} = state),
    do: {:ok, %{state | phase: :sending}}

  def handle_key({:edit, :newline}, %{phase: :failed} = state),
    do: {:ok, %{state | phase: :sending}}

  def handle_key({:nav, :home}, %{phase: :confirm} = state), do: {:ok, back(state)}
  def handle_key({:edit, :backspace}, %{phase: :confirm} = state), do: {:ok, back(state)}

  def handle_key(_event, _state), do: :ignore

  @impl true
  def handle_info({:vote, worker, :ok}, %{phase: :posting, worker: worker} = state) do
    {:ok, %{state | phase: :voted, worker: nil, t: 0}}
  end

  def handle_info({:vote, worker, _error}, %{phase: :posting, worker: worker} = state) do
    {:ok, %{state | phase: :failed, worker: nil, t: 0}}
  end

  def handle_info(_message, _state), do: :ignore

  defp move(state, step) do
    cursor = rem(state.cursor + step + Vote.count(), Vote.count())

    %{state | cursor: cursor, top: scrolled(state.top, cursor)}
  end

  defp scrolled(top, cursor) when cursor < top, do: cursor
  defp scrolled(top, cursor) when cursor >= top + @shown, do: cursor - @shown + 1
  defp scrolled(top, _cursor), do: top

  defp back(state), do: %{state | phase: :open, choice: nil}

  @impl true
  def render(state), do: items(state) ++ [{:rect, 0, @top, @w, @h, @ink}]

  defp items(%{phase: :loading}), do: []
  defp items(%{phase: :clock, t: t}), do: waiting(t)
  defp items(%{phase: :locked} = state), do: locked(state)
  defp items(%{phase: :open} = state), do: ballot(state)
  defp items(%{phase: :confirm} = state), do: confirm(state)

  defp items(%{phase: :sending}), do: sealing(0)
  defp items(%{phase: :posting, t: t}), do: sealing(t)

  defp items(%{phase: :failed}) do
    [
      centred("The letter went astray", @top + 80, :default16px, @red),
      centred("Check wifi, then", @top + 104, :default16px, @ash),
      centred("Enter to try again", @top + 122, :default16px, @ash)
    ]
  end

  defp items(%{phase: :closed, t: t}), do: closed(t)
  defp items(%{phase: :voted} = state), do: verdict(state)

  defp sealing(t) do
    dots = :binary.part("...", 0, rem(div(t, 4), 4))

    [{:text, 52, @top + 100, :default16px, @paper, @ink, "Sealing your accusation" <> dots}]
  end

  # Waiting for SNTP.

  defp waiting(t) do
    dots = :binary.part("...", 0, rem(div(t, 4), 4))

    [
      centred("Waiting for the clock" <> dots, @top + 80, :default16px, @paper),
      centred("Connect to wifi to sync", @top + 104, :default16px, @ash)
    ]
  end

  # Before the ballot opens: dripping title, countdown, candle, police tape.

  defp locked(%{t: t, now: now, opens_at: opens_at}) do
    [
      centred("THE VERDICT", @top + 26, :dogica, @red),
      centred("The ballot opens in", @top + 54, :default16px, @ash),
      centred(Vote.countdown(opens_at - now), @top + 76, :dogica, @paper)
      | candle(t) ++ tape(t, @top + 194) ++ drips(t, @drips, [])
    ]
  end

  defp drips(_t, [], acc), do: acc

  defp drips(t, [{x, seed} | rest], acc) do
    period = 24 + seed * 5
    len = div(rem(t + seed * 11, period) * 18, period)

    drips(t, rest, [
      {:rect, x - 1, @top + len, 5, 4, @red},
      {:rect, x, @top, 3, len, @blood} | acc
    ])
  end

  defp candle(t) do
    flicker = noise(t, 1)
    lean = rem(noise(t, 2), 3) - 1
    tall = 14 + rem(flicker, 7)
    wide = 10 + rem(flicker, 3)
    base = @top + 146
    glow = 34 + rem(flicker, 5) * 2

    [
      {:rect, 158 + lean, base - div(tall, 2), 4, div(tall, 2), @flame_core},
      {:rect, 160 - div(wide, 2) + lean, base - tall, wide, tall, @flame},
      {:rect, 159, base, 2, 4, @shade},
      {:rect, 150, base + 4, 20, 36, @paper},
      {:rect, 160 - glow, base - div(glow, 2), 2 * glow, glow, @glow}
    ]
  end

  defp tape(t, y) do
    shown = :binary.part(@tape_loop, rem(t, byte_size(@tape_text)), @tape_cols)

    [{:text, 0, y + 1, :default16px, @ink, @tape, shown}, {:rect, 0, y, @w, 18, @tape}]
  end

  # After the ballot closes: the candle is out.

  defp closed(t) do
    [
      centred("VOTING CLOSED", @top + 26, :dogica, @red),
      centred("The case is in the", @top + 60, :default16px, @ash),
      centred("detectives' hands now", @top + 78, :default16px, @ash),
      {:rect, 150, @top + 150, 20, 36, @paper},
      {:rect, 159, @top + 146, 2, 4, @shade}
      | smoke(t) ++ tape(t, @top + 194)
    ]
  end

  defp smoke(t) do
    for puff <- :lists.seq(0, 3) do
      rise = rem(t + puff * 6, 24)
      {:rect, 157 + bounce(t + puff * 2, 3), @top + 140 - rise * 3, 5, 5, @shade}
    end
  end

  # Voting open: the suspects, with the chosen row lit and swept.

  defp ballot(%{t: t, cursor: cursor, top: top}) do
    visible = :lists.sublist(Vote.suspects(), top + 1, @shown)

    [
      centred("WHODUNNIT?", @top + 6, :dogica, @red),
      sweep(t * 12, 0, @w, @top + 27),
      {:rect, 0, @top + 27, @w, 2, @blood},
      centred("Up/Down scroll  Enter accuse", @top + 198, :default16px, @ash)
      | more(top, t) ++ scrollbar(top) ++ rows(visible, top, top, cursor, t, [])
    ]
  end

  defp rows([], _index, _top, _cursor, _t, acc), do: acc

  defp rows([suspect | rest], index, top, cursor, t, acc) do
    y = @row_y + (index - top) * @pitch

    rows(rest, index + 1, top, cursor, t, row(suspect, y, index == cursor, t) ++ acc)
  end

  defp row({_id, name, colour}, y, false, _t) do
    [
      {:text, 40, y + 3, :default16px, @paper, @ink, name},
      {:rect, 26, y + 4, 6, 14, colour}
    ]
  end

  defp row({_id, name, colour}, y, true, t) do
    bob = bounce(t, 4)

    [
      {:text, 10 + bob, y + 3, :default16px, @red, @row_hi, ">"},
      {:text, 40, y + 3, :default16px, colour, @row_hi, name},
      {:rect, 26, y + 4, 6, 14, colour},
      sweep(t * 16, 8, 290, y + 20),
      {:rect, 8, y, 3, 22, @red},
      {:rect, 8, y, 290, 22, @row_hi}
    ]
  end

  # How far the window is through the list, beside it.
  defp scrollbar(top) do
    hidden = Vote.count() - @shown
    thumb = div(@list_h * @shown, Vote.count())
    y = @row_y + div((@list_h - thumb) * top, max(hidden, 1))

    [{:rect, 304, y, 6, thumb, @red}, {:rect, 306, @row_y, 2, @list_h, @shade}]
  end

  # A bobbing line under the list counting the suspects out of view.
  defp more(top, t) do
    below = Vote.count() - @shown - top
    y = @more_y + bounce(t, 3)

    cond do
      below > 0 -> pointing(:erlang.integer_to_binary(below) <> " more below", :down, y)
      top > 0 -> pointing(:erlang.integer_to_binary(top) <> " more above", :up, y)
      true -> []
    end
  end

  defp pointing(text, way, y) do
    {:text, x, _y, _font, _fg, _bg, _text} = item = centred(text, y, :default16px, @paper)
    right = x + 8 * byte_size(text) + 8

    [item | chevron(x - 16, y + 4, way) ++ chevron(right, y + 4, way)]
  end

  defp chevron(x, y, way) do
    for step <- :lists.seq(0, 3) do
      row = if way == :down, do: step, else: 3 - step
      {:rect, x + step, y + row * 2, 7 - 2 * step, 2, @red}
    end
  end

  # Are you sure: the suspect in a lineup, behind a pulsing frame.

  defp confirm(%{t: t, choice: choice}) do
    {_id, name, colour} = Vote.at(choice)
    blink = rem(t, 10) < 7

    hint =
      if blink,
        do: [centred("Enter accuse  Esc back", @top + 192, :default16px, @paper)],
        else: []

    [
      centred("You accuse...", @top + 8, :default16px, @ash),
      centred(name, @top + 28, :dogica, colour),
      centred("This cannot be undone", @top + 172, :default16px, @red)
      | hint ++ silhouette(colour, @top + 78) ++ lineup(@top + 74) ++ frame(t)
    ]
  end

  # Rounded head, ears, neck and sloping shoulders, stacked from rects.
  defp silhouette(colour, y) do
    for {x, dy, w, h} <- [
          {154, 0, 12, 2},
          {150, 2, 20, 2},
          {148, 4, 24, 14},
          {145, 9, 3, 6},
          {172, 9, 3, 6},
          {149, 18, 22, 3},
          {152, 21, 16, 2},
          {155, 23, 10, 5},
          {148, 28, 24, 2},
          {142, 30, 36, 2},
          {138, 32, 44, 3},
          {135, 35, 50, 45}
        ],
        do: {:rect, x, y + dy, w, h, colour}
  end

  defp lineup(y) do
    for step <- :lists.seq(0, 8), do: {:rect, 96, y + step * 10, 128, 1, @shade}
  end

  defp frame(t) do
    thick = 2 + bounce(t, 3)
    colour = if rem(div(t, 3), 2) == 0, do: @red, else: @blood

    [
      {:rect, 0, @top, @w, thick, colour},
      {:rect, 0, @top + @h - thick, @w, thick, colour},
      {:rect, 0, @top, thick, @h, colour},
      {:rect, @w - thick, @top, thick, @h, colour}
    ]
  end

  # Voted: the stamp slams down, then the page stops redrawing.

  defp verdict(%{t: t, choice: choice}) do
    {_id, name, colour} = Vote.at(choice)

    stamp(t) ++
      [
        centred("You accused", @top + 98, :default16px, @ash),
        centred(name, @top + 118, :dogica, colour),
        centred("Your vote is sealed", @top + 184, :default16px, @ash)
      ]
  end

  defp stamp(t) do
    grow = max(@stamp_ticks - t, 0) * 9
    x = 56 - grow
    y = @top + 28 - div(grow, 2)
    w = 208 + 2 * grow
    h = 44 + grow

    text = if t >= 3, do: [centred("CASE CLOSED", @top + 41, :dogica, @red)], else: []

    text ++ splatter(t) ++ box(x, y, w, h, 3, @red)
  end

  defp splatter(t) when t < @stamp_ticks, do: []

  defp splatter(_t) do
    [
      {:rect, 50, @top + 22, 4, 4, @blood},
      {:rect, 268, @top + 70, 5, 5, @blood},
      {:rect, 262, @top + 20, 3, 3, @red},
      {:rect, 44, @top + 66, 3, 3, @red},
      {:rect, 274, @top + 30, 2, 2, @blood}
    ]
  end

  defp box(x, y, w, h, thick, colour) do
    [
      {:rect, x, y, w, thick, colour},
      {:rect, x, y + h - thick, w, thick, colour},
      {:rect, x, y, thick, h, colour},
      {:rect, x + w - thick, y, thick, h, colour}
    ]
  end

  # A 60 px streak crossing `width` from `x`, clipped at both ends.
  defp sweep(travel, x, width, y) do
    head = rem(travel, width + 60)
    left = max(head - 60, 0)

    {:rect, x + left, y, min(head, width) - left, 2, @red}
  end

  # 0, 1, .., n - 1, .., 1, 0 and round again.
  defp bounce(t, n) do
    phase = rem(t, 2 * (n - 1))
    if phase < n, do: phase, else: 2 * (n - 1) - phase
  end

  defp noise(t, seed), do: rem((t * 37 + seed * 61) * 29, 97)

  defp centred(text, y, font, colour) do
    {:text, div(@w - advance(font) * byte_size(text), 2), y, font, colour, @ink, text}
  end

  defp advance(:dogica), do: 16
  defp advance(:default16px), do: 8
end
