defmodule FermixCore.Browser.MutatingActionsTest do
  # The one classification behind `outcome_unknown` (M47 §3.4): which browser
  # requests change something a re-send would repeat. Pure, so async.
  use ExUnit.Case, async: true

  alias FermixCore.Browser

  # Every advertised action, with the arguments that decide it where the action
  # alone does not. Enumerated against `Browser.actions/0` below so an action
  # added later either joins this table or fails the test — the failure mode
  # otherwise is silent: an unlisted mutation gets blind-replayed.
  @classified %{
    "doctor" => {false, %{}},
    "status" => {false, %{}},
    "start" => {false, %{}},
    "stop" => {false, %{}},
    "snapshot" => {false, %{}},
    "tabs" => {false, %{}},
    "screenshot" => {false, %{}},
    "pdf" => {false, %{}},
    "console" => {false, %{}},
    "open" => {true, %{"url" => "https://example.com"}},
    "navigate" => {true, %{"url" => "https://example.com"}},
    "close" => {true, %{}},
    "focus" => {true, %{}},
    "dialog" => {true, %{"decision" => "accept"}},
    "upload" => {true, %{"ref" => "file_1", "path" => "/w/a.csv"}},
    "download" => {true, %{}}
  }

  test "every advertised action is classified" do
    decided = Map.keys(@classified) ++ ~w(act cookies storage webmcp)

    for action <- Browser.actions() do
      assert action in decided, "`#{action}` has no mutation classification"
    end
  end

  test "an action with a fixed verdict keeps it" do
    for {action, {expected, args}} <- @classified do
      assert Browser.mutating?(action, args) == expected,
             "`#{action}` was classified #{not expected}"
    end
  end

  # `act` is nine kinds under one action: the two that only read are the two
  # that may be re-sent.
  test "act is split by kind — get and wait read, the rest change the page" do
    for kind <- ~w(click fill type submit press hover click_coords) do
      assert Browser.mutating?("act", %{"kind" => kind}), "act #{kind} was classified a read"
    end

    refute Browser.mutating?("act", %{"kind" => "get", "field" => "text"})
    refute Browser.mutating?("act", %{"kind" => "wait", "wait_until" => "load"})
  end

  # `cookies` and `storage` both read by default and write in exactly one form.
  test "cookies and storage are split by their arguments" do
    assert Browser.mutating?("cookies", %{"kind" => "clear"})
    refute Browser.mutating?("cookies", %{})
    refute Browser.mutating?("cookies", %{"kind" => "list"})

    assert Browser.mutating?("storage", %{"key" => "side", "value" => "w"})
    refute Browser.mutating?("storage", %{})
    refute Browser.mutating?("storage", %{"key" => "side"})
  end

  # A page's own `readOnlyHint` never reaches this decision: a `call` runs code
  # the page chose, and the page is the untrusted party.
  test "webmcp call changes things, webmcp list does not" do
    assert Browser.mutating?("webmcp", %{"op" => "call", "name" => "chess_move"})
    refute Browser.mutating?("webmcp", %{"op" => "list"})
  end
end
