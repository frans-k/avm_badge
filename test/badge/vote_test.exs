defmodule Badge.VoteTest do
  use ExUnit.Case, async: true

  alias Badge.Vote

  @open Vote.opens_at()
  @close Vote.closes_at()

  test "the ballot waits for the clock, then for the hour, then closes" do
    assert Vote.phase(0, @open, @close) == :clock
    assert Vote.phase(@open - 1, @open, @close) == :locked
    assert Vote.phase(@open, @open, @close) == :open
    assert Vote.phase(@close - 1, @open, @close) == :open
    assert Vote.phase(@close, @open, @close) == :closed
  end

  test "opens at 15:40 and closes at midnight, Stockholm time, on 1 October 2026" do
    assert DateTime.from_unix!(@open) == ~U[2026-10-01 13:40:00Z]
    assert DateTime.from_unix!(@close) == ~U[2026-10-01 22:00:00Z]
    assert Badge.Zone.offset_minutes("Europe/Stockholm", @open) == 120
  end

  test "suspects are found by id, in ballot order" do
    for {suspect, index} <- Enum.with_index(Vote.suspects()) do
      assert Vote.index(elem(suspect, 0)) == index
      assert Vote.at(index) == suspect
    end

    assert Vote.index("nobody") == nil
  end

  test "the countdown shows days only when there are some" do
    assert Vote.countdown(-5) == "00:00:00"
    assert Vote.countdown(3_725) == "01:02:05"
    assert Vote.countdown(2 * 86_400 + 3_725) == "2d 01:02:05"
  end

  test "the voter is the badge name, then its chip id" do
    assert Vote.voter("Ada", "A1B2C3D4E5F6") == "Ada A1B2C3D4E5F6"
    assert Vote.voter("", "A1B2C3D4E5F6") == "A1B2C3D4E5F6"
  end

  test "the body names the voter and the suspect by their full name" do
    assert Jason.decode!(Vote.body("Ada A1B2C3D4E5F6", "doctor")) ==
             %{"name" => "Ada A1B2C3D4E5F6", "suspect" => "The Doctor"}
  end

  test "a name with quotes and accents is escaped" do
    name = ~s(Ad"a \\ Lovelace Ö)

    assert Jason.decode!(Vote.body(name, "chief"))["name"] == name
  end

  test "only a 2xx answer counts as accepted" do
    assert Vote.accepted(200) == :ok
    assert Vote.accepted(201) == :ok
    assert Vote.accepted(409) == :ok
    assert Vote.accepted(422) == {:error, {:status, 422}}
    assert Vote.accepted(nil) == {:error, {:status, nil}}
  end
end
