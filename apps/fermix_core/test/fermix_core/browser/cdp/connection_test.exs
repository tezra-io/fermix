defmodule FermixCore.Browser.CDP.ConnectionTest do
  use ExUnit.Case, async: true

  alias FermixCore.Browser.CDP.Connection

  defp state(overrides \\ %{}) do
    Map.merge(%{owner: self(), next_id: 1, pending: %{}, keepalive_ms: 30_000}, overrides)
  end

  describe "handle_cast :command" do
    test "assigns a request id, frames JSON, and tracks the pending caller" do
      ref = make_ref()

      assert {:reply, {:text, frame}, new_state} =
               Connection.handle_cast(
                 {:command, self(), ref, "Page.navigate", %{url: "https://x"}, "sess-1", 5_000},
                 state()
               )

      assert %{"id" => 1, "method" => "Page.navigate", "sessionId" => "sess-1"} =
               Jason.decode!(frame)

      assert new_state.next_id == 2
      assert %{1 => {pid, ^ref}} = new_state.pending
      assert pid == self()
    end

    test "omits params and sessionId when not provided" do
      ref = make_ref()

      assert {:reply, {:text, frame}, _state} =
               Connection.handle_cast(
                 {:command, self(), ref, "Browser.getVersion", nil, nil, 5_000},
                 state()
               )

      decoded = Jason.decode!(frame)
      assert decoded["method"] == "Browser.getVersion"
      refute Map.has_key?(decoded, "params")
      refute Map.has_key?(decoded, "sessionId")
    end
  end

  describe "command/6 client timeout" do
    test "returns cdp_timeout when no response arrives within timeout + grace" do
      # self() is not a real socket, so no {:cdp_response, ...} ever comes back;
      # the receive `after timeout_ms + grace_ms` branch must fire.
      assert {:error, %{code: "cdp_timeout"}} =
               Connection.command(self(), "Page.navigate", nil, nil, 20, 10)
    end
  end

  describe "handle_frame response routing" do
    test "delivers the result to the matching caller and clears pending" do
      ref = make_ref()
      st = state(%{pending: %{7 => {self(), ref}}})
      frame = Jason.encode!(%{"id" => 7, "result" => %{"ok" => true}})

      assert {:ok, new_state} = Connection.handle_frame({:text, frame}, st)
      assert new_state.pending == %{}
      assert_receive {:cdp_response, ^ref, {:ok, %{"ok" => true}}}
    end

    test "maps a CDP error payload to a tagged error" do
      ref = make_ref()
      st = state(%{pending: %{9 => {self(), ref}}})
      frame = Jason.encode!(%{"id" => 9, "error" => %{"message" => "boom"}})

      assert {:ok, _state} = Connection.handle_frame({:text, frame}, st)
      assert_receive {:cdp_response, ^ref, {:error, %{code: "cdp_error", message: "boom"}}}
    end

    test "forwards CDP events to the owner" do
      st = state()
      frame = Jason.encode!(%{"method" => "Page.loadEventFired", "params" => %{}})

      assert {:ok, _state} = Connection.handle_frame({:text, frame}, st)
      assert_receive {:cdp_event, "Page.loadEventFired", %{"method" => "Page.loadEventFired"}}
    end

    test "ignores unknown frames without crashing" do
      assert {:ok, _state} = Connection.handle_frame({:text, "not json"}, state())
    end
  end

  describe "timeouts and disconnects" do
    test "request_timeout notifies the caller and drops the pending entry" do
      ref = make_ref()
      st = state(%{pending: %{3 => {self(), ref}}})

      assert {:ok, new_state} =
               Connection.handle_info({:request_timeout, 3, "DOM.getDocument"}, st)

      assert new_state.pending == %{}
      assert_receive {:cdp_response, ^ref, {:error, %{code: "cdp_timeout"}}}
    end

    test "disconnect flushes every pending caller with cdp_closed" do
      r1 = make_ref()
      r2 = make_ref()
      st = state(%{pending: %{1 => {self(), r1}, 2 => {self(), r2}}})

      assert {:ok, new_state} = Connection.handle_disconnect(%{}, st)
      assert new_state.pending == %{}
      assert_receive {:cdp_response, ^r1, {:error, %{code: "cdp_closed"}}}
      assert_receive {:cdp_response, ^r2, {:error, %{code: "cdp_closed"}}}
    end
  end
end
