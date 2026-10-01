defmodule Badge.Page.RaycasterTest do
  use ExUnit.Case, async: true

  alias Badge.Page.Raycaster
  alias Badge.Theme

  describe "identity" do
    test "names itself for the home grid" do
      assert Raycaster.title() == "Raycaster"
      assert Raycaster.icon() in Badge.Icons.names()
    end

    test "asks for the shortest gap the ticker offers" do
      assert Raycaster.refresh(Raycaster.init()) == 100
    end

    test "starts standing still" do
      assert %{at: nil} = Raycaster.init()
    end
  end

  describe "the keys the engine reads" do
    # The firmware's labels are charlists, and the engine has to know them.
    test "every direction moves or turns the player" do
      grid = Elixir.Raycaster.Engine.grid()
      start = %{x: 11 * 256 + 128, y: 9 * 256 + 128, a: 0}

      for label <- [
            ~c"Up",
            ~c"W",
            ~c"Down",
            ~c"S",
            ~c"Q",
            ~c"E",
            ~c"Left",
            ~c"A",
            ~c"Right",
            ~c"D"
          ] do
        refute Elixir.Raycaster.Engine.step(grid, start, [label], 200) == start
      end
    end

    test "keys with no meaning here change nothing" do
      grid = Elixir.Raycaster.Engine.grid()
      start = %{x: 11 * 256 + 128, y: 9 * 256 + 128, a: 0}

      assert Elixir.Raycaster.Engine.step(grid, start, [~c"Space", ~c"Ctrl", ~c"1"], 200) == start
    end
  end

  describe "render/1" do
    test "stays inside the content area, below the title bar" do
      items = Raycaster.render(Raycaster.init())

      assert items != []

      for {:rect, x, y, w, h, _colour} <- items do
        assert x >= 0 and x + w <= Theme.width()
        assert y >= Theme.content_top() and y + h <= Theme.height()
      end
    end

    test "draws no background, which is the router's job" do
      items = Raycaster.render(Raycaster.init())
      rects = for {:rect, 0, y, w, h, _} <- items, w == Theme.width(), do: {y, h}

      # Only the floor and ceiling span the panel, and together they fill the view only.
      assert length(rects) == 2

      assert rects |> Enum.map(fn {_y, h} -> h end) |> Enum.sum() ==
               Theme.height() - Theme.content_top()
    end
  end

  describe "other players" do
    @figure {900, 300, 0xE0433A}

    defp with_others(others),
      do: elem(Raycaster.handle_info({:raycaster, {:players, others, nil}}, Raycaster.init()), 1)

    test "offline until the relay puts the badge in a room" do
      assert Enum.any?(
               Raycaster.render(Raycaster.init()),
               &match?({:text, _, _, _, _, _, "offline"}, &1)
             )
    end

    test "the line says how many are playing, counting this badge" do
      up = elem(Raycaster.handle_info({:raycaster, :up}, Raycaster.init()), 1)

      assert Enum.any?(
               Raycaster.render(up),
               &match?({:text, _, _, _, _, _, "online, 1 playing"}, &1)
             )

      two = %{up | others: [@figure]}

      assert Enum.any?(
               Raycaster.render(two),
               &match?({:text, _, _, _, _, _, "online, 2 playing"}, &1)
             )
    end

    test "the snapshot replaces who is around, and losing the link empties it" do
      state = with_others([@figure])

      assert %{others: [@figure]} = state

      assert {:ok, %{others: []}} =
               Raycaster.handle_info({:raycaster, {:players, [], nil}}, state)

      assert {:ok, %{others: [], link: :off}} = Raycaster.handle_info({:raycaster, :down}, state)
    end

    test "the link coming up makes the page say where it is at once" do
      state = %{Raycaster.init() | sent: 12_345}

      assert {:ok, %{link: :up, sent: nil}} = Raycaster.handle_info({:raycaster, :up}, state)
    end

    test "a figure in view is drawn in front of the walls" do
      # The spawn point faces east along row 1, so someone four cells ahead is in view.
      ahead = {384 + 4 * 256, 384, 0xE0433A}
      without = Raycaster.render(Raycaster.init())
      with_figure = Raycaster.render(with_others([ahead]))

      # The status line, then a head and a body, then exactly what was there before.
      assert length(with_figure) == length(without) + 2
      assert Enum.drop(with_figure, 3) == Enum.drop(without, 1)
    end

    test "the goat is drawn when the relay says where it is, and is gone when it is not" do
      # Four cells ahead of the spawn point, facing east along row 1.
      state = Raycaster.init()
      without = Raycaster.render(state)

      {:ok, seen} =
        Raycaster.handle_info({:raycaster, {:players, [], {384 + 4 * 256, 384, true}}}, state)

      assert %{goat: {_x, _y, true}} = seen
      # Five rectangles at this distance, thirteen close up.
      assert length(Raycaster.render(seen)) >= length(without) + 5

      {:ok, gone} = Raycaster.handle_info({:raycaster, {:players, [], nil}}, seen)
      assert Raycaster.render(gone) == without
    end

    test "the line says how long this life has lasted once there is a goat" do
      up = elem(Raycaster.handle_info({:raycaster, :up}, Raycaster.init()), 1)
      {:ok, up} = Raycaster.handle_info({:raycaster, {:players, [], {900, 900, false}}}, up)

      assert Enum.any?(
               Raycaster.render(up),
               &match?({:text, _, _, _, _, _, "online, 1 playing, alive 0 s"}, &1)
             )
    end

    test "being caught shows the game over screen, inside the content area" do
      {:ok, caught} = Raycaster.handle_info({:raycaster, :caught}, Raycaster.init())
      items = Raycaster.render(caught)

      assert Enum.any?(items, &match?({:text, _, _, _, _, _, "GAME OVER"}, &1))

      for {:text, _x, y, _font, _fg, _bg, _text} <- items, do: assert(y >= Theme.content_top())
      for {:rect, _x, y, _w, _h, _c} <- items, do: assert(y >= Theme.content_top())
    end

    test "a catch is taken once, and the game over screen outlasts a key still held" do
      {:ok, caught} = Raycaster.handle_info({:raycaster, :caught}, Raycaster.init())

      assert Raycaster.handle_info({:raycaster, :caught}, caught) == :ignore
      # Without a key held, and within the time it stays up, ticking changes nothing.
      assert Raycaster.tick(caught).caught == caught.caught
    end

    test "being caught turns the LEDs steady red, once" do
      {:ok, caught} = Raycaster.handle_info({:raycaster, :caught}, Raycaster.init())
      assert %{dread: 0} = caught

      lit = Raycaster.tick(caught)
      assert %{dread: :caught} = lit
      # The level did not change, so the LEDs are not told again.
      assert Raycaster.tick(lit) == lit
    end

    test "a message it does not know is ignored" do
      assert Raycaster.handle_info(:nonsense, Raycaster.init()) == :ignore
      assert Raycaster.handle_info({:raycaster, :sideways}, Raycaster.init()) == :ignore
    end
  end

  test "handle_key ignores everything, so Esc goes home" do
    for event <- [{:move, :up}, {:char, ?w}, {:nav, :home}] do
      assert Raycaster.handle_key(event, Raycaster.init()) == :ignore
    end
  end
end
