defmodule FermixCore.Capabilities.MCP.Remote.ProxyTest do
  use ExUnit.Case, async: false

  alias FermixCore.Capabilities.MCP.Remote.Budget
  alias FermixCore.Capabilities.MCP.Remote.Contract
  alias FermixCore.Capabilities.MCP.Remote.Limits
  alias FermixCore.Capabilities.MCP.Remote.Proxy
  alias FermixCore.Plugins.CanonicalJson

  @source {:plugin, "eden"}

  @schema %{
    "type" => "object",
    "properties" => %{"noteId" => %{"type" => "string"}, "workspaceId" => %{"type" => "string"}}
  }

  # The fake transport seam: it records every call it is asked to make, so a
  # test can prove a refusal happened BEFORE the peer would have seen it.
  defmodule FakeDispatch do
    @behaviour FermixCore.Capabilities.MCP.Remote.Proxy

    @table :mcp_proxy_fake_dispatch

    def init do
      cleanup()
      :ets.new(@table, [:named_table, :public, :set])
      :ets.insert(@table, {:calls, []})
      :ok
    end

    def cleanup do
      case :ets.whereis(@table) do
        :undefined -> :ok
        tid -> :ets.delete(tid)
      end
    end

    def set_response(response), do: :ets.insert(@table, {:response, response})

    def set_delay(ms), do: :ets.insert(@table, {:delay, ms})

    defp delay do
      case :ets.lookup(@table, :delay) do
        [{:delay, ms}] -> Process.sleep(ms)
        [] -> :ok
      end
    end

    def calls do
      [{:calls, calls}] = :ets.lookup(@table, :calls)
      Enum.reverse(calls)
    end

    @impl true
    def call_tool(_target, tool, args, _timeout) do
      [{:calls, calls}] = :ets.lookup(@table, :calls)
      :ets.insert(@table, {:calls, [{tool, args} | calls]})
      delay()

      case :ets.lookup(@table, :response) do
        [{:response, response}] -> response
        [] -> {:ok, %{"content" => [%{"type" => "text", "text" => ~s({"ok":true})}]}}
      end
    end
  end

  defp digest(name, input) do
    {:ok, value} = CanonicalJson.descriptor_digest(name, input, nil, nil)
    value
  end

  defp facts(name, overrides \\ %{}) do
    Map.merge(
      %{
        read_only: true,
        replay_safe: true,
        required_credential_scope: "read",
        descriptor_sha256: digest(name, @schema),
        collection_policy: nil,
        argument_guards: []
      },
      overrides
    )
  end

  defp contract(overrides \\ %{}) do
    spec =
      Map.merge(
        %{
          source_id: @source,
          name: "eden",
          transport: :streamable_http,
          name_mode: :preserve,
          selected_profile: "retrieval",
          resource_scope: %{kind: :single_workspace, argument: "workspaceId", id: "ws_secret"},
          allowed_tools: %{"eden_get_note" => facts("eden_get_note")},
          budgets: %{"agent_turn_calls" => 20, "agent_turn_paginated_calls" => 5},
          result_contract: %{
            "kind" => "json_boolean",
            "success_field" => "ok",
            "status_field" => "status",
            "message_field" => "message"
          }
        },
        overrides
      )

    {:ok, contract} = Contract.compile(spec)
    contract
  end

  defp context(overrides \\ %{}) do
    Map.merge(
      %{
        source_id: @source,
        session_id: "turn-#{System.unique_integer([:positive])}",
        turn_pid: self(),
        profile: "retrieval",
        read_only: true,
        replay_safe: true
      },
      overrides
    )
  end

  setup do
    :ok = FakeDispatch.init()
    suffix = System.unique_integer([:positive])

    budget =
      start_supervised!(
        {Budget, name: :"proxy_budget_#{suffix}"},
        id: :"proxy_budget_child_#{suffix}"
      )

    on_exit(&FakeDispatch.cleanup/0)
    %{budget: budget}
  end

  defp spawn_callers(proxy, count) do
    for _i <- 1..count do
      spawn(fn -> Proxy.call(proxy, context(), "eden_get_note", %{}) end)
    end
  end

  # Poll the proxy's own accounting rather than sleeping a guessed interval: the
  # callers are separate processes and their admission is not observable
  # otherwise.
  defp await_queue(proxy, expected) do
    Enum.reduce_while(1..200, :timeout, fn _i, _acc ->
      if Proxy.stats(proxy).queued == expected do
        {:halt, :ok}
      else
        Process.sleep(10)
        {:cont, :timeout}
      end
    end)
    |> case do
      :ok -> :ok
      :timeout -> flunk("proxy queue never reached #{expected}: #{inspect(Proxy.stats(proxy))}")
    end
  end

  defp start_proxy(overrides, budget) do
    {:ok, proxy} =
      Proxy.start_link(
        contract: contract(overrides),
        dispatch: FakeDispatch,
        target: :fake,
        budget: budget
      )

    proxy
  end

  describe "the allowlist gate" do
    test "an excluded tool is refused and the peer never sees it", %{budget: budget} do
      proxy = start_proxy(%{}, budget)

      assert {:error, :tool_not_allowed} =
               Proxy.call(proxy, context(), "eden_delete_workspace", %{})

      assert FakeDispatch.calls() == []
    end

    test "a context minted for another source is refused", %{budget: budget} do
      proxy = start_proxy(%{}, budget)
      other = context(%{source_id: {:operator, "eden"}})

      assert {:error, :source_mismatch} = Proxy.call(proxy, other, "eden_get_note", %{})
      assert FakeDispatch.calls() == []
    end

    test "a context carrying another profile is refused", %{budget: budget} do
      proxy = start_proxy(%{}, budget)

      assert {:error, :profile_mismatch} =
               Proxy.call(proxy, context(%{profile: "capture"}), "eden_get_note", %{})

      assert FakeDispatch.calls() == []
    end

    test "a stale capability whose signed facts no longer match is refused", %{budget: budget} do
      proxy = start_proxy(%{}, budget)

      assert {:error, :stale_capability} =
               Proxy.call(proxy, context(%{read_only: false}), "eden_get_note", %{})

      assert FakeDispatch.calls() == []
    end

    test "a suspended proxy serves nothing", %{budget: budget} do
      proxy = start_proxy(%{}, budget)
      :ok = Proxy.suspend(proxy)

      assert {:error, :remote_suspended} = Proxy.call(proxy, context(), "eden_get_note", %{})
      assert FakeDispatch.calls() == []
    end
  end

  describe "resource scope" do
    test "injects the operator-selected value the model never sees", %{budget: budget} do
      proxy = start_proxy(%{}, budget)

      assert {:ok, _text} = Proxy.call(proxy, context(), "eden_get_note", %{"noteId" => "n1"})
      assert [{"eden_get_note", args}] = FakeDispatch.calls()
      assert args == %{"noteId" => "n1", "workspaceId" => "ws_secret"}
    end

    test "a model-supplied scope value is refused before network I/O", %{budget: budget} do
      proxy = start_proxy(%{}, budget)
      args = %{"noteId" => "n1", "workspaceId" => "ws_someone_else"}

      assert {:error, :resource_scope_violation} =
               Proxy.call(proxy, context(), "eden_get_note", args)

      assert FakeDispatch.calls() == []
    end
  end

  describe "budgets" do
    test "an exhausted turn ceiling fails BEFORE the fixture sees the call", %{budget: budget} do
      proxy =
        start_proxy(
          %{budgets: %{"agent_turn_calls" => 1, "agent_turn_paginated_calls" => 1}},
          budget
        )

      ctx = context()

      key = Budget.turn_key(@source, ctx.session_id)
      :ok = Budget.charge(budget, key, :call, %{turn_calls: 1, turn_paginated_calls: 1}, self())

      assert {:error, {:budget_exhausted, :agent_turn_calls}} =
               Proxy.call(proxy, ctx, "eden_get_note", %{})

      assert FakeDispatch.calls() == []
    end

    test "an argument above a signed guard fails before dispatch", %{budget: budget} do
      guards = [%{"pointer" => "/urls", "kind" => "public_http_url_array", "max_items" => 1}]
      tools = %{"eden_get_note" => facts("eden_get_note", %{argument_guards: guards})}
      proxy = start_proxy(%{allowed_tools: tools}, budget)

      args = %{"urls" => ["https://a.example", "https://b.example"]}

      assert {:error, {:argument_guard, "public_http_url_array", :too_many_items}} =
               Proxy.call(proxy, context(), "eden_get_note", args)

      assert FakeDispatch.calls() == []
    end
  end

  describe "serialization" do
    test "one call is in flight and the rest queue", %{budget: budget} do
      proxy = start_proxy(%{}, budget)
      FakeDispatch.set_delay(2_000)

      spawn_callers(proxy, 3)
      await_queue(proxy, 2)

      assert %{inflight?: true, queued: 2} = Proxy.stats(proxy)
      assert length(FakeDispatch.calls()) == 1
    end

    test "overflow past the queue cap returns :remote_busy, it does not grow", %{budget: budget} do
      proxy = start_proxy(%{}, budget)
      FakeDispatch.set_delay(2_000)

      spawn_callers(proxy, Limits.max_queued_calls() + 1)
      await_queue(proxy, Limits.max_queued_calls())

      assert {:error, :remote_busy} = Proxy.call(proxy, context(), "eden_get_note", %{})
      assert %{queued: queued} = Proxy.stats(proxy)
      assert queued == Limits.max_queued_calls()
    end

    test "a queued caller that dies is removed before dispatch", %{budget: budget} do
      proxy = start_proxy(%{}, budget)
      FakeDispatch.set_delay(2_000)

      spawn_callers(proxy, 1)
      [doomed] = spawn_callers(proxy, 1)
      await_queue(proxy, 1)

      ref = Process.monitor(doomed)
      Process.exit(doomed, :kill)
      assert_receive {:DOWN, ^ref, :process, ^doomed, :killed}

      await_queue(proxy, 0)
      assert %{queued: 0} = Proxy.stats(proxy)
      # The abandoned entry never became a second network call.
      assert length(FakeDispatch.calls()) == 1
    end
  end

  describe "result classification" do
    test "an isError result is a tool error, not a success", %{budget: budget} do
      proxy = start_proxy(%{}, budget)

      FakeDispatch.set_response(
        {:ok, %{"isError" => true, "content" => [%{"type" => "text", "text" => ~s({"ok":true})}]}}
      )

      assert {:error, {:remote_tool_error, "unspecified"}} =
               Proxy.call(proxy, context(), "eden_get_note", %{})
    end

    test "a signed {ok:false} body is an error even without isError", %{budget: budget} do
      proxy = start_proxy(%{}, budget)
      body = ~s({"ok":false,"status":"missing-workspace"})
      FakeDispatch.set_response({:ok, %{"content" => [%{"type" => "text", "text" => body}]}})

      assert {:error, {:remote_tool_error, "missing-workspace"}} =
               Proxy.call(proxy, context(), "eden_get_note", %{})
    end

    test "three consecutive invalid results close the gate", %{budget: budget} do
      proxy = start_proxy(%{}, budget)
      FakeDispatch.set_response({:ok, %{"content" => [%{"type" => "image", "data" => "AA"}]}})

      assert {:error, {:invalid_remote_result, :unsupported_content}} =
               Proxy.call(proxy, context(), "eden_get_note", %{})

      assert {:error, {:invalid_remote_result, :unsupported_content}} =
               Proxy.call(proxy, context(), "eden_get_note", %{})

      assert {:error, {:remote_protocol_error, :unsupported_content}} =
               Proxy.call(proxy, context(), "eden_get_note", %{})

      assert Proxy.state(proxy) == :suspended
    end

    test "an oversized returned collection fails rather than being truncated", %{budget: budget} do
      policy = %{
        "paginated" => true,
        "request_limit_pointer" => "/limit",
        "default_limit" => 2,
        "result_items_pointer" => "/items",
        "max_returned_items" => 2
      }

      tools = %{"eden_get_note" => facts("eden_get_note", %{collection_policy: policy})}
      proxy = start_proxy(%{allowed_tools: tools}, budget)

      body = ~s({"ok":true,"items":[1,2,3]})
      FakeDispatch.set_response({:ok, %{"content" => [%{"type" => "text", "text" => body}]}})

      assert {:error, {:collection, :oversized_returned_collection}} =
               Proxy.call(proxy, context(), "eden_get_note", %{})
    end
  end

  describe "drift" do
    test "a tools-changed notification suspends the gate immediately", %{budget: budget} do
      proxy = start_proxy(%{}, budget)
      assert Proxy.state(proxy) == :ready

      :ok = Proxy.tools_changed(proxy)
      assert Proxy.state(proxy) == :suspended
      assert {:error, :remote_suspended} = Proxy.call(proxy, context(), "eden_get_note", %{})
      assert FakeDispatch.calls() == []
    end

    test "resume/2 reopens the gate with the re-verified contract", %{budget: budget} do
      proxy = start_proxy(%{}, budget)
      :ok = Proxy.tools_changed(proxy)
      :ok = Proxy.resume(proxy, contract())

      assert Proxy.state(proxy) == :ready
      assert {:ok, _text} = Proxy.call(proxy, context(), "eden_get_note", %{})
    end
  end
end
