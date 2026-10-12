defmodule Badge.Page.Settings.UpdateTest do
  use ExUnit.Case, async: true

  alias Badge.Page.Settings
  alias Badge.Page.Settings.Update
  alias Badge.Theme

  defp bodies(state) do
    for {:text, _x, _y, _f, _c, _b, body} <- Update.render(state), do: body
  end

  defp says?(state, text) do
    :lists.any(fn body -> :binary.match(body, text) != :nomatch end, bodies(state))
  end

  describe "identity" do
    test "names itself for the tab strip" do
      assert Update.title() == "Update"
    end

    test "starts with no question asked" do
      assert Update.init().confirm == false
    end

    test "knows whether the badge has an updater" do
      assert Update.init().updater == true
    end
  end

  describe "what the screen says" do
    test "the running firmware and its version" do
      assert says?(Update.init(), "avm_badge " <> Badge.Update.version())
    end

    test "the chip id NervesHub knows the badge by" do
      assert says?(Update.init(), "90DA72000001")
    end

    test "what checking does" do
      assert says?(Update.init(), "updater")
    end

    test "how to check" do
      assert says?(Update.init(), "Enter check for updates")
    end
  end

  describe "confirming" do
    test "Enter asks before restarting" do
      assert {:ok, %{confirm: true} = asked} = Update.handle_key({:edit, :newline}, Update.init())
      assert says?(asked, "restart now?")
    end

    test "escape leaves the confirm, not the page" do
      asked = %{Update.init() | confirm: true}

      assert {:ok, %{confirm: false}} = Update.handle_key({:nav, :home}, asked)
    end

    test "escape at rest is left alone, so the router still reaches home" do
      assert Update.handle_key({:nav, :home}, Update.init()) == :ignore
    end
  end

  describe "a badge without an updater" do
    test "says it needs a cable instead of offering a check" do
      bare = %{Update.init() | updater: false}

      assert says?(bare, "no updater")
      refute says?(bare, "Enter check for updates")
    end

    test "Enter does nothing" do
      assert Update.handle_key({:edit, :newline}, %{Update.init() | updater: false}) == :ignore
    end
  end

  describe "the carousel" do
    test "the arrows slide between tabs at rest" do
      assert Update.handle_key({:move, :left}, Update.init()) == :ignore
      assert Update.handle_key({:move, :right}, Update.init()) == :ignore
    end

    test "the arrows are swallowed while a confirm is up" do
      asked = %{Update.init() | confirm: true}

      assert {:ok, ^asked} = Update.handle_key({:move, :left}, asked)
      assert {:ok, ^asked} = Update.handle_key({:move, :right}, asked)
    end
  end

  describe "drawing inside the lines" do
    test "both states fit the content area" do
      states = [
        Update.init(),
        %{Update.init() | confirm: true},
        %{Update.init() | updater: false}
      ]

      for state <- states do
        for {:text, x, y, _f, _c, _b, body} <- Update.render(state) do
          assert y >= Settings.content_top()
          assert y < Theme.height()
          assert x >= 0
          assert x + 8 * byte_size(body) <= Theme.width()
        end
      end
    end
  end
end
