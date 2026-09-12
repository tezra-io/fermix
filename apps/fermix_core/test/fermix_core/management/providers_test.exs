defmodule FermixCore.Management.ProvidersTest do
  use ExUnit.Case, async: true

  alias FermixCore.Management.Jobs
  alias FermixCore.Management.Providers

  setup context do
    tasks = :"providers_tasks_#{:erlang.phash2(context.test)}"
    start_supervised!({Task.Supervisor, name: tasks}, id: tasks)

    server =
      start_supervised!(
        {Jobs, name: :"providers_jobs_#{:erlang.phash2(context.test)}", task_supervisor: tasks}
      )

    %{jobs: [server: server]}
  end

  describe "set_primary" do
    test "an unknown provider is refused by field with the daemon's own sentence" do
      assert {:error, {:invalid_params, "provider", sentence}} = Providers.set_primary("nope")
      assert sentence == "This daemon has no such provider."
    end

    # Promoting a provider with no credential would leave the daemon with a
    # primary it cannot call, so the refusal is before the write, not after it.
    test "an unconfigured provider is refused before anything is written" do
      commit = fn _id -> flunk("an unconfigured provider must not reach the writer") end

      assert {:error, {:invalid_params, "provider", sentence}} =
               Providers.set_primary("anthropic",
                 configured?: fn _id -> false end,
                 commit: commit
               )

      assert sentence == "This provider has no credentials yet."
    end

    test "a configured provider commits through the shared write tail" do
      commit = fn :anthropic -> {:ok, %{}} end

      assert {:ok, result} =
               Providers.set_primary("anthropic", configured?: fn _id -> true end, commit: commit)

      assert Enum.sort(Map.keys(result)) == ~w(restart side_effects)
      assert %{"required" => _required, "reasons" => _reasons} = result["restart"]
      assert result["side_effects"] == []
    end

    test "an outside edit and an unreadable file stay two refusals, not one" do
      changed = fn _id -> {:error, {:external_change, ["providers"]}} end

      assert {:error, {:external_change, ["providers"]}} =
               Providers.set_primary("anthropic",
                 configured?: fn _id -> true end,
                 commit: changed
               )

      broken = fn _id -> {:error, {:config_unreadable, "line 14: expected a table."}} end

      assert {:error, {:config_unreadable, "line 14: expected a table."}} =
               Providers.set_primary("anthropic", configured?: fn _id -> true end, commit: broken)
    end

    # A save that fails for a reason with no sentence of its own carries the
    # writer's internal term, and that term names files on the operator's disk.
    # It belongs in the daemon log, never in the sentence a client renders.
    test "a save refused for an unnamed reason publishes a fixed sentence" do
      broken = fn _id ->
        {:error, {:snapshot_write_failed, "/Users/example/.fermix/config.toml"}}
      end

      assert {:error, {:invalid_params, "provider", sentence}} =
               Providers.set_primary("anthropic", configured?: fn _id -> true end, commit: broken)

      assert sentence == "The primary provider could not be saved. See the daemon log."
    end
  end

  describe "models" do
    test "a catalog page carries the source it came from" do
      assert {:ok, page} = Providers.models(%{"provider" => "anthropic", "live" => false})

      assert page["source"] == "catalog"
      assert page["truncated"] == false
      assert page["cursor"] == nil
      assert [%{"id" => _id, "label" => _label} | _rest] = page["models"]
    end

    test "a page beyond the limit hands back a cursor that resumes it" do
      params = %{"provider" => "anthropic", "live" => false, "limit" => 1}

      assert {:ok, first} = Providers.models(params)
      assert length(first["models"]) == 1
      assert first["truncated"] == true
      assert is_binary(first["cursor"])

      assert {:ok, second} = Providers.models(Map.put(params, "cursor", first["cursor"]))
      assert second["models"] != first["models"]
    end

    test "a cursor this daemon did not mint is refused by field" do
      params = %{"provider" => "anthropic", "live" => false, "cursor" => "!!not-base64!!"}

      assert {:error, {:invalid_params, "cursor", _sentence}} = Providers.models(params)
    end

    test "a query narrows the page without changing its source" do
      params = %{"provider" => "anthropic", "live" => false, "query" => "opus"}

      assert {:ok, page} = Providers.models(params)
      assert page["source"] == "catalog"
      assert Enum.all?(page["models"], &String.contains?(String.downcase(&1["id"]), "opus"))
    end

    # A live listing and the catalog answer two different questions. Serving one
    # under the other's label is the failure this refuses.
    test "a provider with no live source refuses rather than degrading to the catalog" do
      params = %{"provider" => "anthropic", "live" => true}

      assert {:error, {:unavailable, "model_listing"}} = Providers.models(params)
    end

    test "a live listing that fails refuses rather than degrading to the catalog" do
      live = fn :ollama, _opts -> {:error, "connection refused"} end
      params = %{"provider" => "ollama", "live" => true}

      assert {:error, {:unavailable, "model_listing"}} =
               Providers.models(params, live_models: live)
    end

    test "a live listing answers with the live label" do
      live = fn :ollama, _opts ->
        {:ok, [%{id: "qwen3:32b", label: "Qwen3", context_window: 1}]}
      end

      assert {:ok, page} =
               Providers.models(%{"provider" => "ollama", "live" => true},
                 live_models: live
               )

      assert page["source"] == "live"
      assert page["models"] == [%{"id" => "qwen3:32b", "label" => "Qwen3"}]
    end

    test "a listing with no live flag or an out-of-range limit is refused by field" do
      assert {:error, {:invalid_params, "live", _s}} =
               Providers.models(%{"provider" => "anthropic"})

      assert {:error, {:invalid_params, "limit", _s}} =
               Providers.models(%{"provider" => "anthropic", "live" => false, "limit" => 0})

      assert {:error, {:invalid_params, "limit", _s}} =
               Providers.models(%{"provider" => "anthropic", "live" => false, "limit" => 201})
    end
  end

  describe "probe.start" do
    test "the probe is a job that carries its model and latency", %{jobs: jobs} do
      probe = fn :anthropic, _opts -> {:ok, %{model: "claude-opus-5", latency_ms: 812}} end

      assert {:ok, started} = Providers.probe_start("anthropic", jobs: jobs, probe: probe)
      assert started["kind"] == "provider_probe"
      assert started["budget_ms"] == Jobs.budget_ms(:provider_probe)

      assert {:ok, done} = terminal(jobs, started["job_id"])
      assert done["status"] == "completed"
      assert done["result"] == %{"model" => "claude-opus-5", "latency_ms" => 812}
    end

    test "a refused probe carries the daemon's sentence, not a bare code", %{jobs: jobs} do
      probe = fn :anthropic, _opts -> {:error, {:server_error, 429, "slow down"}} end

      assert {:ok, started} = Providers.probe_start("anthropic", jobs: jobs, probe: probe)
      assert {:ok, done} = terminal(jobs, started["job_id"])

      assert done["status"] == "failed"

      assert done["failure"] == %{
               "code" => "unavailable",
               "sentence" => "The provider answered HTTP 429."
             }
    end

    test "an unreachable provider is a sentence, not a transport struct", %{jobs: jobs} do
      probe = fn :anthropic, _opts -> {:error, {:network, %{reason: :econnrefused}}} end

      assert {:ok, started} = Providers.probe_start("anthropic", jobs: jobs, probe: probe)
      assert {:ok, done} = terminal(jobs, started["job_id"])

      assert done["failure"] == %{
               "code" => "unavailable",
               "sentence" => "The provider could not be reached. See the daemon log."
             }
    end

    # The probe is a real metered call, so it joins the one provider stream with
    # the job's own id as its session. Without that the call is unparented and
    # cannot be attributed to the run that issued it.
    test "the metered call is emitted under the job's session id", %{jobs: jobs} do
      handler = :"probe_telemetry_#{System.unique_integer([:positive])}"
      owner = self()

      :telemetry.attach(
        handler,
        [:fermix, :provider, :call],
        fn _event, measurements, metadata, _config ->
          send(owner, {:provider_call, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      probe = fn :anthropic, _opts -> {:ok, %{model: "claude-opus-5", latency_ms: 3}} end
      assert {:ok, started} = Providers.probe_start("anthropic", jobs: jobs, probe: probe)

      assert_receive {:provider_call, measurements, metadata}
      assert metadata.session_id == started["job_id"]
      assert metadata.provider == :anthropic
      assert metadata.model == "claude-opus-5"
      assert metadata.status == "ok"
      assert is_integer(measurements.duration_ms)
    end

    test "a second probe of the same provider is refused as busy", %{jobs: jobs} do
      owner = self()

      probe = fn :anthropic, _opts ->
        send(owner, :probing)

        receive do
          :finish -> {:ok, %{model: "m", latency_ms: 1}}
        end
      end

      assert {:ok, _first} = Providers.probe_start("anthropic", jobs: jobs, probe: probe)
      assert_receive :probing

      assert {:error, {:busy, "provider_probe"}} =
               Providers.probe_start("anthropic", jobs: jobs, probe: probe)
    end

    test "an unknown provider never mints a job", %{jobs: jobs} do
      assert {:error, {:invalid_params, "provider", _s}} =
               Providers.probe_start("nope", jobs: jobs)

      assert {:ok, []} = Jobs.list(jobs)
    end
  end

  defp terminal(jobs, job_id, attempts \\ 200)
  defp terminal(_jobs, job_id, 0), do: {:error, {:never_terminal, job_id}}

  defp terminal(jobs, job_id, attempts) do
    {:ok, view} = Jobs.get(job_id, jobs)

    if view["status"] == "running" do
      Process.sleep(10)
      terminal(jobs, job_id, attempts - 1)
    else
      {:ok, view}
    end
  end
end
