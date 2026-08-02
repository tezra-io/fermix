defmodule FermixCore.Capabilities.MCP.Remote.BudgetTest do
  use ExUnit.Case, async: false

  alias FermixCore.Capabilities.MCP.Remote.Budget

  @source {:plugin, "eden"}
  @limits %{turn_calls: 3, turn_paginated_calls: 2}

  setup do
    suffix = System.unique_integer([:positive])

    budget =
      start_supervised!(
        {Budget, name: :"mcp_budget_#{suffix}", sweep_interval_ms: 60_000},
        id: :"mcp_budget_child_#{suffix}"
      )

    %{budget: budget, key: Budget.turn_key(@source, "turn-#{suffix}")}
  end

  describe "per-turn ceilings" do
    test "refuses the attempt past the signed call ceiling", %{budget: budget, key: key} do
      for _i <- 1..3, do: assert(:ok = Budget.charge(budget, key, :call, @limits, self()))

      assert {:error, {:budget_exhausted, :agent_turn_calls}} =
               Budget.charge(budget, key, :call, @limits, self())
    end

    test "a paginated call spends both ceilings", %{budget: budget, key: key} do
      assert :ok = Budget.charge(budget, key, :paginated_call, @limits, self())
      assert :ok = Budget.charge(budget, key, :paginated_call, @limits, self())

      assert {:error, {:budget_exhausted, :agent_turn_paginated_calls}} =
               Budget.charge(budget, key, :paginated_call, @limits, self())

      # The refused charge is atomic: the call half is not banked either.
      assert {:ok, %{calls: 2, paginated: 2}} = Budget.usage(budget, key)
    end

    test "two turns against one source do not share a ceiling", %{budget: budget} do
      one = Budget.turn_key(@source, "turn-a")
      two = Budget.turn_key(@source, "turn-b")
      limits = %{turn_calls: 1, turn_paginated_calls: 1}

      assert :ok = Budget.charge(budget, one, :call, limits, self())
      assert :ok = Budget.charge(budget, two, :call, limits, self())
      assert {:error, {:budget_exhausted, _}} = Budget.charge(budget, one, :call, limits, self())
    end

    test "a lifecycle identity never borrows the agent turn's ceiling", %{budget: budget} do
      setup_key = Budget.lifecycle_key(@source, :setup)
      limits = %{turn_calls: 1, turn_paginated_calls: 1}

      assert :ok = Budget.charge(budget, setup_key, :call, limits, self())
      assert :ok = Budget.charge(budget, setup_key, :call, limits, self())
      assert {:ok, %{calls: 2}} = Budget.usage(budget, setup_key)
    end
  end

  describe "state lifetime" do
    test "finish/2 removes the turn's state", %{budget: budget, key: key} do
      assert :ok = Budget.charge(budget, key, :call, @limits, self())
      assert :ok = Budget.finish(budget, key)
      assert :error = Budget.usage(budget, key)
    end

    test "owner death removes the turn's state", %{budget: budget, key: key} do
      owner = spawn(fn -> Process.sleep(:infinity) end)
      assert :ok = Budget.charge(budget, key, :call, @limits, owner)
      assert {:ok, _usage} = Budget.usage(budget, key)

      ref = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^owner, :killed}

      # One synchronous round-trip after the :DOWN is delivered to the budget.
      Process.sleep(20)
      assert :error = Budget.usage(budget, key)
    end

    test "the orphan sweep removes nothing fresh", %{budget: budget, key: key} do
      assert :ok = Budget.charge(budget, key, :call, @limits, self())
      assert {:ok, 0} = Budget.sweep(budget)
      assert {:ok, _usage} = Budget.usage(budget, key)
    end

    test "the orphan TTL removes a turn neither completion nor death reached" do
      suffix = System.unique_integer([:positive])

      budget =
        start_supervised!(
          {Budget, name: :"mcp_budget_ttl_#{suffix}", orphan_ttl_ms: 1},
          id: :"mcp_budget_ttl_child_#{suffix}"
        )

      key = Budget.turn_key(@source, "orphan-#{suffix}")
      owner = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)

      assert :ok = Budget.charge(budget, key, :call, @limits, owner)
      Process.sleep(5)

      assert {:ok, 1} = Budget.sweep(budget)
      assert :error = Budget.usage(budget, key)
    end
  end

  describe "public_http_url_array" do
    @guard [%{"pointer" => "/urls", "kind" => "public_http_url_array", "max_items" => 2}]

    test "accepts public https URLs" do
      args = %{"urls" => ["https://example.com/a", "http://example.org/b?page=2"]}
      assert :ok = Budget.check_arguments(@guard, args)
    end

    test "refuses more items than the manifest allows" do
      args = %{"urls" => ["https://a.example", "https://b.example", "https://c.example"]}

      assert {:error, {:argument_guard, "public_http_url_array", :too_many_items}} =
               Budget.check_arguments(@guard, args)
    end

    test "refuses userinfo, control characters, and non-HTTP schemes" do
      for {url, class} <- [
            {"https://user:pw@example.com/", :userinfo_present},
            {"https://exa\tmple.com/", :control_characters},
            {"file:///etc/passwd", :scheme_not_http}
          ] do
        assert {:error, {:argument_guard, "public_http_url_array", ^class}} =
                 Budget.check_arguments(@guard, %{"urls" => [url]})
      end
    end

    test "refuses non-global hosts" do
      for url <- [
            "http://localhost/x",
            "http://127.0.0.1/x",
            "http://169.254.169.254/latest/meta-data",
            "http://10.1.2.3/x",
            "http://printer.local/x"
          ] do
        assert {:error, {:argument_guard, "public_http_url_array", :non_global_host}} =
                 Budget.check_arguments(@guard, %{"urls" => [url]})
      end
    end

    test "refuses the fixed sensitive and presigned query keys" do
      for url <- [
            "https://example.com/f?X-Amz-Signature=abc",
            "https://example.com/f?token=abc",
            "https://example.com/f?a=1&api_key=abc"
          ] do
        assert {:error, {:argument_guard, "public_http_url_array", :sensitive_query_key}} =
                 Budget.check_arguments(@guard, %{"urls" => [url]})
      end
    end

    test "an absent guarded field is not a violation" do
      assert :ok = Budget.check_arguments(@guard, %{"other" => 1})
    end

    test "a guarded field that is not an array is a violation" do
      assert {:error, {:argument_guard, "public_http_url_array", :not_an_array}} =
               Budget.check_arguments(@guard, %{"urls" => "https://example.com"})
    end
  end

  describe "bounded_visible_ascii_array" do
    @ascii_guard [
      %{"pointer" => "/ids", "kind" => "bounded_visible_ascii_array", "max_items" => 2}
    ]

    test "accepts short visible-ASCII ids" do
      assert :ok = Budget.check_arguments(@ascii_guard, %{"ids" => ["abc_1", "XYZ-2"]})
    end

    test "refuses whitespace, control characters, and non-strings" do
      assert {:error, {:argument_guard, _kind, :non_visible_ascii}} =
               Budget.check_arguments(@ascii_guard, %{"ids" => ["has space"]})

      assert {:error, {:argument_guard, _kind, :not_a_string}} =
               Budget.check_arguments(@ascii_guard, %{"ids" => [42]})
    end
  end

  describe "collection policy" do
    @policy %{
      "paginated" => true,
      "request_limit_pointer" => "/limit",
      "default_limit" => 50,
      "result_items_pointer" => "/items",
      "max_returned_items" => 50
    }

    test "injects the signed default when the model omitted the limit" do
      assert {:ok, %{"limit" => 50}} = Budget.apply_request_limit(@policy, %{})
    end

    test "refuses a larger request limit before network I/O" do
      assert {:error, {:collection, :request_limit_too_large}} =
               Budget.apply_request_limit(@policy, %{"limit" => 500})
    end

    test "refuses an oversized RETURNED collection rather than truncating it" do
      body = %{"items" => Enum.to_list(1..51)}

      assert {:error, {:collection, :oversized_returned_collection}} =
               Budget.check_returned_items(@policy, body)
    end

    test "accepts a collection at the signed maximum" do
      assert :ok = Budget.check_returned_items(@policy, %{"items" => Enum.to_list(1..50)})
    end
  end
end
