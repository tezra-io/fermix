defmodule FermixCore.Capabilities.MCP.RuntimeStatusTest do
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.MCP.RuntimeStatus

  @source {:plugin, "eden"}
  @other {:operator, "eden"}

  setup do
    status = start_supervised!({RuntimeStatus, name: :"runtime_status_#{unique()}"})
    %{status: status}
  end

  defp unique, do: System.unique_integer([:positive])

  # A stand-in owner: it exists, it can be killed, and it holds nothing.
  defp fake_owner do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  describe "generations" do
    test "a start installs a fresh generation at :connecting", %{status: status} do
      owner = fake_owner()

      assert {:ok, generation} =
               RuntimeStatus.register_owner(status, @source, owner, plugin: "eden")

      assert {:ok, entry} = RuntimeStatus.fetch(status, @source)
      assert entry.status == :connecting
      assert entry.generation == generation
      assert entry.owner == owner
      assert entry.plugin == "eden"
    end

    test "each start installs a DIFFERENT generation", %{status: status} do
      {:ok, first} = RuntimeStatus.register_owner(status, @source, fake_owner())
      {:ok, second} = RuntimeStatus.register_owner(status, @source, fake_owner())

      refute first == second
    end

    test "the source id is qualified: an operator server of the same name is separate", %{
      status: status
    } do
      {:ok, plugin_gen} = RuntimeStatus.register_owner(status, @source, fake_owner())
      {:ok, operator_gen} = RuntimeStatus.register_owner(status, @other, fake_owner())

      :ok = RuntimeStatus.put(status, @source, plugin_gen, :ready, nil)

      assert {:ok, %{status: :ready}} = RuntimeStatus.fetch(status, @source)

      assert {:ok, %{status: :connecting, generation: ^operator_gen}} =
               RuntimeStatus.fetch(status, @other)
    end

    # The rotation case: the old owner is still mid-handshake when its
    # replacement is installed, and its `:ready` is about a credential that is
    # no longer the one in use.
    test "a delayed write from a REPLACED generation cannot overwrite the replacement", %{
      status: status
    } do
      {:ok, replaced} = RuntimeStatus.register_owner(status, @source, fake_owner())
      {:ok, current} = RuntimeStatus.register_owner(status, @source, fake_owner())

      assert {:error, :stale_generation} =
               RuntimeStatus.put(status, @source, replaced, :ready, nil)

      assert {:ok, %{status: :connecting, generation: ^current}} =
               RuntimeStatus.fetch(status, @source)
    end

    test "a write for a source that was cleared is refused", %{status: status} do
      {:ok, generation} = RuntimeStatus.register_owner(status, @source, fake_owner())
      :ok = RuntimeStatus.clear(status, @source)

      assert {:error, :stale_generation} =
               RuntimeStatus.put(status, @source, generation, :ready, nil)

      assert :error = RuntimeStatus.fetch(status, @source)
    end
  end

  describe "await/4" do
    test "returns when this generation reaches :ready", %{status: status} do
      {:ok, generation} = RuntimeStatus.register_owner(status, @source, fake_owner())
      waiter = Task.async(fn -> RuntimeStatus.await(status, @source, generation, 1_000) end)

      :ok = RuntimeStatus.put(status, @source, generation, :ready, nil)

      assert {:ok, :ready} = Task.await(waiter)
    end

    test "returns the terminal status and its redacted class", %{status: status} do
      {:ok, generation} = RuntimeStatus.register_owner(status, @source, fake_owner())
      waiter = Task.async(fn -> RuntimeStatus.await(status, @source, generation, 1_000) end)

      :ok =
        RuntimeStatus.put(
          status,
          @source,
          generation,
          :remote_security_blocked,
          :non_global_answer
        )

      assert {:error, {:remote_security_blocked, :non_global_answer, nil}} = Task.await(waiter)
    end

    test "a stale generation's :ready never satisfies the replacement's waiter", %{status: status} do
      {:ok, replaced} = RuntimeStatus.register_owner(status, @source, fake_owner())
      {:ok, current} = RuntimeStatus.register_owner(status, @source, fake_owner())

      waiter = Task.async(fn -> RuntimeStatus.await(status, @source, current, 200) end)
      {:error, :stale_generation} = RuntimeStatus.put(status, @source, replaced, :ready, nil)

      assert {:error, :timeout} = Task.await(waiter, 1_000)
    end

    test "a waiter on a replaced generation fails instead of hanging", %{status: status} do
      {:ok, replaced} = RuntimeStatus.register_owner(status, @source, fake_owner())
      {:ok, _current} = RuntimeStatus.register_owner(status, @source, fake_owner())

      assert {:error, {:generation_replaced, @source}} =
               RuntimeStatus.await(status, @source, replaced, 1_000)
    end

    test "a waiter registered before a replacement is released, not left hanging", %{
      status: status
    } do
      {:ok, first} = RuntimeStatus.register_owner(status, @source, fake_owner())
      waiter = Task.async(fn -> RuntimeStatus.await(status, @source, first, 5_000) end)
      Process.sleep(20)

      {:ok, _second} = RuntimeStatus.register_owner(status, @source, fake_owner())

      assert {:error, {:generation_replaced, @source}} = Task.await(waiter, 1_000)
    end

    test "an already-terminal entry answers immediately", %{status: status} do
      {:ok, generation} = RuntimeStatus.register_owner(status, @source, fake_owner())
      :ok = RuntimeStatus.put(status, @source, generation, :needs_workspace, nil)

      assert {:error, {:needs_workspace, nil, nil}} =
               RuntimeStatus.await(status, @source, generation, 1_000)
    end
  end

  describe "owner death" do
    test "an abrupt death leaves a visible terminal status", %{status: status} do
      owner = fake_owner()
      {:ok, _generation} = RuntimeStatus.register_owner(status, @source, owner)

      Process.exit(owner, :kill)

      assert eventually(fn ->
               match?(
                 {:ok, %{status: :remote_unreachable, owner: nil}},
                 RuntimeStatus.fetch(status, @source)
               )
             end)
    end

    test "a classified terminal status survives the death that follows it", %{status: status} do
      owner = fake_owner()
      {:ok, generation} = RuntimeStatus.register_owner(status, @source, owner)
      :ok = RuntimeStatus.put(status, @source, generation, :reauthorization_required, nil)

      Process.exit(owner, :kill)

      assert eventually(fn ->
               match?(
                 {:ok, %{status: :reauthorization_required}},
                 RuntimeStatus.fetch(status, @source)
               )
             end)
    end

    test "a REPLACED owner's death cannot touch the replacement's status", %{status: status} do
      replaced = fake_owner()
      {:ok, _old} = RuntimeStatus.register_owner(status, @source, replaced)
      {:ok, current} = RuntimeStatus.register_owner(status, @source, fake_owner())
      :ok = RuntimeStatus.put(status, @source, current, :ready, nil)

      Process.exit(replaced, :kill)
      Process.sleep(50)

      assert {:ok, %{status: :ready, generation: ^current}} = RuntimeStatus.fetch(status, @source)
    end

    test "death releases this generation's waiter with the terminal outcome", %{status: status} do
      owner = fake_owner()
      {:ok, generation} = RuntimeStatus.register_owner(status, @source, owner)
      waiter = Task.async(fn -> RuntimeStatus.await(status, @source, generation, 2_000) end)
      Process.sleep(20)

      Process.exit(owner, :kill)

      assert {:error, {:remote_unreachable, _class, nil}} = Task.await(waiter, 1_000)
    end
  end

  describe "classify/1" do
    test "maps the remote rail's reasons onto statuses with atom-only detail" do
      assert {:needs_secret, nil, nil} = RuntimeStatus.classify({:needs_secret, "eden"})

      assert {:reauthorization_required, nil, nil} =
               RuntimeStatus.classify({:reauthorization_required, "mcp.eden.so"})

      assert {:remote_protocol_error, :session_expired, nil} =
               RuntimeStatus.classify(:session_expired)

      assert {:remote_security_blocked, :endpoint_not_pinnable, nil} =
               RuntimeStatus.classify({:remote_security_blocked, :endpoint_not_pinnable})

      assert {:remote_protocol_error, :unsupported_protocol_version, nil} =
               RuntimeStatus.classify(
                 {:remote_protocol_error, {:unsupported_protocol_version, "2025-11-25"}}
               )

      assert {:remote_unreachable, :transport, nil} =
               RuntimeStatus.classify({:transport, :econnrefused})
    end

    # A crash reason can carry the crashing process's state, and a session's
    # state holds a bearer credential. Only the class may survive.
    test "an unrecognized reason keeps only its class" do
      assert {:remote_unreachable, :unclassified, nil} =
               RuntimeStatus.classify(%{secret: "eden_pat_do_not_leak"})

      assert {:remote_unreachable, :badarg, nil} =
               RuntimeStatus.classify({:badarg, %{credential: "eden_pat_do_not_leak"}})
    end

    test "every status it can produce is a declared status" do
      reasons = [
        {:needs_secret, "eden"},
        {:needs_workspace, "eden"},
        {:insufficient_credential_scope, :write},
        {:invalid_remote_config, :transport},
        {:reauthorization_required, "host"},
        {:remote_security_blocked, :blocked},
        {:remote_protocol_error, :bad},
        {:invalid_remote_result, :empty_body},
        :session_expired,
        {:upstream_contract_mismatch, :missing},
        {:capability_conflict, "eden_search"},
        {:remote_jsonrpc_error, -32_000, "nope"},
        {:remote_http_error, 503},
        {:rate_limited, 60_000},
        :anything_else
      ]

      for reason <- reasons do
        {status, detail, subject} = RuntimeStatus.classify(reason)
        assert status in RuntimeStatus.statuses()
        assert is_atom(detail)
        assert is_nil(subject) or is_binary(subject)
      end
    end
  end

  describe "classify/1 subject" do
    # The one question a contract refusal raises is WHICH capability, and before
    # this the answer existed only inside the daemon's own memory.
    test "a contract refusal carries the capability it names" do
      assert {:upstream_contract_mismatch, :missing_tool, "eden_get_item_connections"} =
               RuntimeStatus.classify(
                 {:upstream_contract_mismatch, {:missing_tool, "eden_get_item_connections"}}
               )

      assert {:upstream_contract_mismatch, :descriptor_changed, "eden_read_card"} =
               RuntimeStatus.classify(
                 {:upstream_contract_mismatch, {:descriptor_changed, "eden_read_card"}}
               )

      assert {:capability_conflict, nil, "eden_search"} =
               RuntimeStatus.classify({:capability_conflict, "eden_search"})

      assert {:capability_conflict, :duplicate_name, "eden_search"} =
               RuntimeStatus.classify({:capability_conflict, {:duplicate_name, "eden_search"}})

      # A manifest key that failed the namespace rule is still a manifest key —
      # `Contract.verify_one/2` fetches it out of the signed tool map before the
      # namespace check can fire.
      assert {:upstream_contract_mismatch, :name_outside_namespace, "get_note"} =
               RuntimeStatus.classify(
                 {:upstream_contract_mismatch, {:name_outside_namespace, "get_note"}}
               )
    end

    # The moduledoc's boundary, as a test. A subject is a capability name this
    # build already holds; a crash term and an unrecognized `{class, binary}`
    # are the two ways a string could otherwise reach an operator's screen.
    test "crash terms and unrecognized shapes never become a subject" do
      assert {:remote_unreachable, :unclassified, nil} =
               RuntimeStatus.classify(%{tokens: %{access_token: "eden_pat_do_not_leak"}})

      assert {:remote_unreachable, :EXIT, nil} =
               RuntimeStatus.classify({:EXIT, self(), {%RuntimeError{message: "boom"}, []}})

      # Shape alone earns nothing: an unknown kind carrying a string is refused
      # even though it looks exactly like a refusal this table would name.
      assert {:upstream_contract_mismatch, :some_future_kind, nil} =
               RuntimeStatus.classify(
                 {:upstream_contract_mismatch, {:some_future_kind, "eden_pat_do_not_leak"}}
               )

      # A peer-authored JSON-RPC error is never a runtime status at all.
      assert {:remote_protocol_error, :jsonrpc_error, nil} =
               RuntimeStatus.classify({:remote_jsonrpc_error, nil, "peer authored text"})
    end

    # Bounded in characters, so the truncation can never emit invalid UTF-8 and
    # make `Jason` refuse the whole status reply.
    test "a stored subject is bounded and stays valid UTF-8", %{status: status} do
      {:ok, generation} = RuntimeStatus.register_owner(status, @source, fake_owner())

      for oversized <- [String.duplicate("x", 500), String.duplicate("é", 500)] do
        :ok =
          RuntimeStatus.put(
            status,
            @source,
            generation,
            :upstream_contract_mismatch,
            :missing_tool,
            oversized
          )

        {:ok, entry} = RuntimeStatus.fetch(status, @source)
        assert String.length(entry.subject) == 128
        assert String.valid?(entry.subject)
        assert {:ok, _json} = Jason.encode(%{subject: entry.subject})
      end
    end
  end

  describe "@subject_kinds vs its producers" do
    @contract_source "lib/fermix_core/capabilities/mcp/remote/contract.ex"
    @producer_sources [
      @contract_source,
      "lib/fermix_core/capabilities/mcp/server.ex",
      "lib/fermix_core/capabilities/mcp/naming.ex"
    ]

    # Derived from the constructing sources, never from a second hand-written
    # list. `:schema_too_large` was missing from `@subject_kinds` for exactly the
    # reason this test exists: it is built indirectly, so it does not appear as a
    # literal refusal tuple anywhere, and a reviewer reading the list saw its
    # sibling `:schema_too_deep` and assumed the pair was covered.
    test "every kind a refusal can carry a manifest name under is declared" do
      literal =
        for path <- @producer_sources,
            source = File.read!(Path.join(app_root(), path)),
            [_, kind] <-
              Regex.scan(
                ~r/\{:(?:upstream_contract_mismatch|capability_conflict), \{:([a-z_]+),/,
                source
              ),
            into: MapSet.new(),
            do: String.to_existing_atom(kind)

      # The indirect producer: `bound_schema/2` wraps whatever class the schema
      # walkers return into `{:upstream_contract_mismatch, {class, name}}`.
      indirect =
        for [_, kind] <-
              Regex.scan(
                ~r/\{:error, :(schema_[a-z_]+)\}/,
                File.read!(Path.join(app_root(), @contract_source))
              ),
            into: MapSet.new(),
            do: String.to_existing_atom(kind)

      # Anchors: a moved or renamed source must fail loudly here rather than
      # quietly reduce this test to asserting nothing.
      assert MapSet.size(literal) >= 6, "refusal tuples not found — did the sources move?"
      assert MapSet.size(indirect) >= 2, "schema-bound classes not found — did they move?"

      assert MapSet.union(literal, indirect) ==
               MapSet.new(RuntimeStatus.subject_kinds()),
             "@subject_kinds has drifted from the refusals its producers construct"
    end

    defp app_root do
      Path.expand("../../../..", __DIR__)
    end
  end

  describe "describe/1" do
    test "renders the same refusal for every operator surface, atoms or wire strings" do
      assert RuntimeStatus.describe({:ready, nil, nil}) == "ready"

      assert RuntimeStatus.describe({:upstream_contract_mismatch, :missing_tool, "eden_x"}) ==
               "upstream_contract_mismatch/missing_tool (eden_x)"

      assert RuntimeStatus.describe({"upstream_contract_mismatch", "missing_tool", "eden_x"}) ==
               "upstream_contract_mismatch/missing_tool (eden_x)"

      assert RuntimeStatus.describe({:capability_conflict, nil, "eden_x"}) ==
               "capability_conflict (eden_x)"
    end
  end

  test "terminal?/1 treats only :connecting and :ready as live" do
    refute RuntimeStatus.terminal?(:connecting)
    refute RuntimeStatus.terminal?(:ready)

    for status <- RuntimeStatus.statuses() -- [:connecting, :ready] do
      assert RuntimeStatus.terminal?(status)
    end
  end

  test "list/1 exposes every source", %{status: status} do
    {:ok, _} = RuntimeStatus.register_owner(status, @source, fake_owner())
    {:ok, _} = RuntimeStatus.register_owner(status, @other, fake_owner())

    entries = RuntimeStatus.list(status)

    assert Map.keys(entries) |> Enum.sort() == Enum.sort([@source, @other])
  end

  defp eventually(fun, deadline_ms \\ 500) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    poll(fun, deadline)
  end

  defp poll(fun, deadline) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> Process.sleep(10) && poll(fun, deadline)
    end
  end
end
