defmodule Badge.LogTest do
  use ExUnit.Case, async: false

  alias Badge.Log

  setup do
    # The log echoes to the leader it starts under; give it a silent one.
    {:ok, quiet} = StringIO.open("")
    leader = Process.group_leader()
    Process.group_leader(self(), quiet)
    log = start_supervised!({Log, :ok})
    Process.group_leader(self(), leader)

    %{log: log}
  end

  describe "keeping lines" do
    test "a formatted print is one line, oldest first", %{log: log} do
      :io.format(log, ~c"hello ~p~n", [1])
      :io.format(log, ~c"world~n", [])

      assert Log.tail(10) == ["hello 1", "world"]
    end

    test "plain chars are split on newlines, blanks dropped", %{log: log} do
      :io.put_chars(log, "one\ntwo\n\nthree")

      assert Log.tail(10) == ["one", "two", "three"]
    end

    test "tail gives only the newest", %{log: log} do
      :io.put_chars(log, "a\nb\nc\n")

      assert Log.tail(2) == ["b", "c"]
    end

    test "the ring is bounded", %{log: log} do
      for n <- 1..60, do: :io.format(log, ~c"line ~p~n", [n])

      lines = Log.tail(100)

      assert length(lines) == 40
      assert :lists.last(lines) == "line 60"
    end

    test "a long line is clipped rather than kept whole", %{log: log} do
      :io.put_chars(log, :binary.copy("x", 200))

      assert [line] = Log.tail(1)
      assert byte_size(line) == 80
    end
  end

  describe "answering every request" do
    test "reads are answered with eof rather than blocking", %{log: log} do
      assert :io.get_line(log, "") == :eof
    end

    test "an unknown request is refused, not left hanging", %{log: log} do
      ref = make_ref()
      send(log, {:io_request, self(), ref, :bogus})

      assert_receive {:io_reply, ^ref, {:error, :request}}
    end
  end
end
