defmodule Badge.Page.VoteTest do
  use ExUnit.Case, async: true

  alias Badge.Page.Vote, as: Page
  alias Badge.Theme
  alias Badge.Vote

  @open Vote.opens_at()
  @close Vote.closes_at()

  defp at(phase, now), do: Page.clocked(%{Page.init() | phase: phase}, now)

  defp press(state, event) do
    {:ok, next} = Page.handle_key(event, state)
    next
  end

  defp texts(state),
    do: for({:text, _x, _y, _font, _fg, _bg, text} <- Page.render(state), do: text)

  test "names itself for the home grid" do
    assert Page.title() == "Oban"
    assert Page.icon() in Badge.Icons.names()
  end

  describe "before voting opens" do
    test "an unset clock waits for it" do
      assert at(:clock, 0).phase == :clock
    end

    test "a set clock counts down" do
      state = at(:clock, @open - 3_725)

      assert state.phase == :locked
      assert "01:02:05" in texts(state)
    end

    test "no suspect can be chosen" do
      state = at(:locked, @open - 10)

      assert Page.handle_key({:edit, :newline}, state) == :ignore
      assert Page.handle_key({:move, :down}, state) == :ignore
    end

    test "the ballot opens on the hour" do
      assert at(:locked, @open).phase == :open
    end
  end

  describe "voting" do
    setup do: %{state: at(:clock, @open + 60)}

    test "every suspect can be scrolled to and chosen", %{state: state} do
      Enum.reduce(Vote.suspects(), state, fn {_id, name, _colour}, acc ->
        assert name in texts(acc)
        assert elem(Vote.at(acc.cursor), 1) == name
        press(acc, {:move, :down})
      end)
    end

    test "the cursor wraps both ways", %{state: state} do
      assert press(state, {:move, :up}).cursor == Vote.count() - 1
      assert state |> press({:move, :down}) |> press({:move, :down}) |> Map.get(:cursor) == 2
    end

    test "shows six suspects at a time and says how many are below", %{state: state} do
      names = for {_id, name, _colour} <- Vote.suspects(), do: name
      {shown, hidden} = Enum.split(names, 6)

      for name <- shown, do: assert(name in texts(state))
      for name <- hidden, do: refute(name in texts(state))
      assert "3 more below" in texts(state)
    end

    test "scrolls with the cursor, and back", %{state: state} do
      down = Enum.reduce(1..7, state, fn _i, acc -> press(acc, {:move, :down}) end)

      assert down.cursor == 7
      assert down.top == 2
      assert "1 more below" in texts(down)
      assert elem(Vote.at(7), 1) in texts(down)
      refute elem(Vote.at(0), 1) in texts(down)

      last = press(down, {:move, :down})
      assert last.top == 3
      assert "3 more above" in texts(last)

      wrapped = press(last, {:move, :down})
      assert {wrapped.cursor, wrapped.top} == {0, 0}
      assert press(state, {:move, :up}).top == 3
    end

    test "Enter asks before accusing", %{state: state} do
      state = state |> press({:move, :down}) |> press({:edit, :newline})

      assert state.phase == :confirm
      assert state.choice == 1
      assert elem(Vote.at(1), 1) in texts(state)
    end

    test "Esc backs out of the confirm screen", %{state: state} do
      state = state |> press({:edit, :newline}) |> press({:nav, :home})

      assert state.phase == :open
      assert state.choice == nil
    end

    test "a second Enter sends", %{state: state} do
      assert state |> press({:edit, :newline}) |> press({:edit, :newline}) |> Map.get(:phase) ==
               :sending
    end

    test "Esc on the ballot goes home", %{state: state} do
      assert Page.handle_key({:nav, :home}, state) == :ignore
    end
  end

  describe "after the ballot closes" do
    test "the list gives way to the closed screen" do
      state = at(:open, @close)

      assert state.phase == :closed
      assert "VOTING CLOSED" in texts(state)
      assert Page.handle_key({:edit, :newline}, state) == :ignore
      assert Page.handle_key({:move, :down}, state) == :ignore
    end

    test "a badge still confirming is closed out" do
      confirming = %{at(:clock, @open) | phase: :confirm, choice: 1}
      state = Page.clocked(confirming, @close)

      assert state.phase == :closed
      assert state.choice == nil
    end

    test "a badge confirming before the close stays on its choice" do
      confirming = %{at(:clock, @open) | phase: :confirm, choice: 1}

      assert %{phase: :confirm, choice: 1} = Page.clocked(confirming, @close - 1)
    end

    test "a badge that voted keeps its verdict" do
      voted = %{Page.init() | phase: :voted, choice: 2}

      assert Page.clocked(voted, @close + 60).phase == :voted
    end
  end

  describe "the O key" do
    test "opens the ballot from every lockout, and the clock leaves it open" do
      for {phase, now} <- [{:clock, 0}, {:locked, @open - 60}, {:closed, @close + 60}] do
        state = at(:clock, now)
        assert state.phase == phase

        state = press(state, {:char, ?o})
        assert state.phase == :open
        assert Page.clocked(state, now).phase == :open
        assert Page.clocked(press(state, {:edit, :newline}), now).phase == :confirm
      end
    end

    test "does nothing once a vote is in" do
      voted = %{Page.init() | phase: :voted, choice: 2}

      assert Page.handle_key({:char, ?o}, voted) == :ignore
    end
  end

  describe "sending" do
    setup do
      worker = spawn(fn -> :ok end)
      %{state: %{Page.init() | phase: :posting, choice: 1, worker: worker}, worker: worker}
    end

    test "the worker's yes seals the vote", %{state: state, worker: worker} do
      assert {:ok, %{phase: :voted, worker: nil, t: 0}} =
               Page.handle_info({:vote, worker, :ok}, state)
    end

    test "the worker's no offers another try", %{state: state, worker: worker} do
      assert {:ok, %{phase: :failed}} =
               Page.handle_info({:vote, worker, {:error, :nxdomain}}, state)
    end

    test "an answer from a worker that was given up on is ignored", %{state: state} do
      assert Page.handle_info({:vote, self(), :ok}, state) == :ignore
    end

    test "a worker that never answers is given up on", %{state: state} do
      import ExUnit.CaptureIO

      capture_io(fn -> assert Page.tick(%{state | t: 200}).phase == :failed end)
    end

    test "takes no keys while it waits", %{state: state} do
      for event <- [{:edit, :newline}, {:move, :down}, {:nav, :home}] do
        assert Page.handle_key(event, state) == :ignore
      end
    end
  end

  describe "after voting" do
    setup do: %{state: %{Page.init() | phase: :voted, choice: 2}}

    test "shows the accusation and takes no keys", %{state: state} do
      assert elem(Vote.at(2), 1) in texts(state)

      for event <- [{:edit, :newline}, {:move, :down}, {:nav, :home}] do
        assert Page.handle_key(event, state) == :ignore
      end
    end

    test "stops redrawing once the stamp lands", %{state: state} do
      landed = %{state | t: 6}

      assert Page.tick(landed) == landed
      assert Page.refresh(landed) == 1000
    end
  end

  test "every phase stays inside the content area" do
    states = [
      at(:clock, 0),
      at(:clock, @open - 90_000),
      at(:clock, @open),
      at(:clock, @close),
      %{at(:clock, @open) | top: 2, cursor: 7},
      %{at(:clock, @open) | top: 3, cursor: 8},
      %{at(:clock, @open) | phase: :confirm, choice: 5},
      %{Page.init() | phase: :sending, choice: 0},
      %{Page.init() | phase: :posting, choice: 0},
      %{Page.init() | phase: :failed, choice: 0},
      %{Page.init() | phase: :voted, choice: 3, t: 0},
      %{Page.init() | phase: :voted, choice: 3, t: 6}
    ]

    for base <- states, t <- 0..60 do
      for item <- Page.render(%{base | t: t}) do
        case item do
          {:rect, x, y, w, h, _colour} ->
            assert w >= 0 and h >= 0
            assert x >= 0 and x + w <= Theme.width(), inspect({base.phase, t, item})

            assert y >= Theme.content_top() and y + h <= Theme.height(),
                   inspect({base.phase, t, item})

          {:text, x, y, _font, _fg, _bg, text} ->
            assert x >= 0 and y >= Theme.content_top(), inspect({base.phase, t, item})
            assert x + 8 * byte_size(text) <= Theme.width()
        end
      end
    end
  end
end
