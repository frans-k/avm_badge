defmodule Badge.Sim.VoteNvsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Badge.Page.Vote, as: Page
  alias Badge.Vote

  setup do
    start_supervised!(Badge.Sim.Nvs)
    :ok
  end

  test "a stored vote opens the page on its verdict" do
    assert Vote.save("mechanic") == :ok
    assert Vote.load() == "mechanic"
    assert %{phase: :voted, choice: 2} = Page.tick(Page.init())
  end

  test "a stored id no longer on the ballot is no vote" do
    Vote.save("butler")

    assert Vote.load() == nil
  end

  test "a fresh badge goes on to the ballot, voting under its name and chip id" do
    assert Vote.load() == nil

    state = Page.tick(Page.init())

    assert state.phase in [:clock, :locked, :open]
    assert state.voter =~ ~r/^Sim Badge [0-9A-F]{12}$/
  end

  test "a vote that cannot be sent is not stored, and can be tried again" do
    sending = %{Page.init() | phase: :sending, choice: 7, voter: "Ada A1B2C3D4E5F6"}

    log =
      capture_io(fn ->
        posting = Page.tick(sending)
        assert posting.phase == :posting
        worker = posting.worker

        assert_receive {:vote, ^worker, {:error, _reason}} = reply, 5_000
        {:ok, failed} = Page.handle_info(reply, posting)
        assert failed.phase == :failed
        assert {:ok, %{phase: :sending}} = Page.handle_key({:edit, :newline}, failed)
      end)

    assert log =~ ~s(POST https://oban-murders.fly.dev/api/vote)
    assert log =~ ~s("suspect":"The Doctor")
    assert log =~ "failed {error,undef}"
    assert Vote.load() == nil
  end
end
