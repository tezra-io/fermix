defmodule FermixCore.Tools.BrowserPageLookTest do
  use ExUnit.Case, async: true

  alias FermixCore.Tools.Browser

  # The result shapes below are the ones the backends build: `snapshot_result/2`
  # and `observed/5` in `Browser.Cdp.Backend`, `snapshot_result/3`,
  # `tab_result/1` and `page_verdict/4` in `Browser.HostServer`, with the
  # `backend` key `ProfileServer` adds to `open` and `navigate`.

  @page_text ~s(- heading "Flights" [level=1]\n- @button_1 [button] "Book this flight")

  defp snapshot_result do
    %{
      "ok" => true,
      "target" => "T1",
      "url" => "https://example.com/flights?from=LIS#results",
      "title" => "Flights",
      "ready_state" => "complete",
      "snapshot" => @page_text,
      "truncated" => false
    }
  end

  defp pane_open_result do
    %{
      "id" => "h3:7",
      "target" => "h3:7",
      "url" => "https://example.com/",
      "title" => "Example",
      "type" => "page",
      "page" => "changed",
      "snapshot" => @page_text,
      "truncated" => false,
      "ready_state" => "interactive",
      "backend" => "fermix_app"
    }
  end

  defp changed_act_result do
    %{
      "ok" => true,
      "target" => "T1",
      "action" => "click",
      "page" => "changed",
      "snapshot" => @page_text,
      "truncated" => false,
      "url" => "https://example.com/flights/42",
      "ready_state" => "complete"
    }
  end

  defp encode(result), do: Jason.encode!(result)

  describe "page_look/1" do
    test "a snapshot, an observed open and a changed act each look at their tab and address" do
      assert Browser.page_look(encode(snapshot_result())) ==
               {"T1", "https://example.com/flights?from=LIS#results"}

      assert Browser.page_look(encode(pane_open_result())) == {"h3:7", "https://example.com/"}

      assert Browser.page_look(encode(changed_act_result())) ==
               {"T1", "https://example.com/flights/42"}
    end

    # A hash-routed app puts each screen behind its own fragment: the inbox and
    # a message read from it are different pages, so the whole address is the
    # page, fragment and query both.
    test "the whole address is the page, its fragment and its query included" do
      at = fn url -> encode(%{snapshot_result() | "url" => url}) end

      assert Browser.page_look(at.("https://mail.example.com/#inbox/m1")) ==
               {"T1", "https://mail.example.com/#inbox/m1"}

      refute Browser.page_look(at.("https://mail.example.com/#inbox/m1")) ==
               Browser.page_look(at.("https://mail.example.com/#inbox"))

      refute Browser.page_look(at.("https://example.com/a#top")) ==
               Browser.page_look(at.("https://example.com/a"))

      refute Browser.page_look(at.("https://example.com/a?page=2")) ==
               Browser.page_look(at.("https://example.com/a"))
    end

    test "a result that carries no page text is not a look" do
      unchanged = changed_act_result() |> Map.drop(["snapshot", "truncated"])
      unchanged = %{unchanged | "page" => "unchanged"}
      unobserved = pane_open_result() |> Map.drop(["snapshot", "truncated", "ready_state"])
      unobserved = %{unobserved | "page" => "unobserved"}

      refused =
        changed_act_result()
        |> Map.drop(["url", "snapshot", "truncated", "ready_state"])
        |> Map.merge(%{"page" => "read_blocked", "page_reason" => "blocked by policy"})

      tab_only = pane_open_result() |> Map.drop(["page", "snapshot", "truncated", "ready_state"])
      text_get = %{"ok" => true, "target" => "T1", "value" => @page_text}

      for result <- [unchanged, unobserved, refused, tab_only, text_get] do
        assert Browser.page_look(encode(result)) == nil, inspect(result)
      end
    end

    test "a result missing its target, its url or a text snapshot is not a look" do
      for result <- [
            Map.delete(snapshot_result(), "target"),
            Map.delete(snapshot_result(), "url"),
            %{snapshot_result() | "snapshot" => nil},
            %{snapshot_result() | "url" => nil},
            %{snapshot_result() | "target" => 1}
          ] do
        assert Browser.page_look(encode(result)) == nil, inspect(result)
      end
    end

    test "text that is not a JSON object is not a look" do
      for text <- [
            "Snapshot unavailable (snapshot_unavailable)",
            ~s({"target": "T1", "url": "https://example.com/", "snapshot": "cut off),
            ~s(["T1", "https://example.com/", "text"]),
            ~s("a string"),
            ""
          ] do
        assert Browser.page_look(text) == nil, inspect(text)
      end
    end
  end

  describe "superseded_look/1" do
    # The marker says what happened and nothing more: a page whose content
    # changed at the same address (a search's Next re-rendering in place) is
    # not brought back by a `snapshot`, so it promises no way back of its own.
    test "swaps the page text for one line saying what replaced it and keeps every other field" do
      result = changed_act_result()
      superseded = result |> encode() |> Browser.superseded_look() |> Jason.decode!()

      assert Map.delete(superseded, "snapshot") == Map.delete(result, "snapshot")

      marker = superseded["snapshot"]
      refute marker =~ "Book this flight"
      refute marker =~ "\n"
      assert marker =~ "a later look at the same address in this tab replaced it"
      refute marker =~ "snapshot"
      refute marker =~ "again"
    end

    test "the marker is the same for every look it replaces" do
      marker = fn result ->
        result |> encode() |> Browser.superseded_look() |> Jason.decode!() |> Map.get("snapshot")
      end

      assert marker.(snapshot_result()) == marker.(changed_act_result())
      assert marker.(snapshot_result()) == marker.(pane_open_result())
    end

    test "the marked result is small however long the page text was" do
      long = %{pane_open_result() | "snapshot" => String.duplicate("- row\n", 8_000)}
      bare = pane_open_result() |> Map.delete("snapshot") |> encode()

      superseded = long |> encode() |> Browser.superseded_look()

      assert byte_size(superseded) < byte_size(bare) + 300
    end

    test "refuses a result that is not a look" do
      unchanged = %{"ok" => true, "target" => "T1", "page" => "unchanged", "url" => "https://a/"}

      assert_raise ArgumentError, fn -> Browser.superseded_look(encode(unchanged)) end
      assert_raise ArgumentError, fn -> Browser.superseded_look("not json") end
    end
  end
end
