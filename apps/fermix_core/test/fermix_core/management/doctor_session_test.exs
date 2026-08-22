defmodule FermixCore.Management.DoctorSessionTest do
  use ExUnit.Case, async: true

  alias FermixCore.Management.Doctor
  alias FermixCore.Management.Doctor.Descriptor

  defmodule AppBuildInfo do
    def app_engine?, do: true
  end

  defmodule StandaloneBuildInfo do
    def app_engine?, do: false
  end

  defp ids(scope, opts), do: scope |> Descriptor.catalog(opts) |> Enum.map(& &1.id)

  setup context do
    server =
      start_supervised!(
        {Doctor,
         name: :"doctor_#{:erlang.phash2(context.test)}",
         task_supervisor: task_supervisor(context)}
      )

    %{server: server}
  end

  defp task_supervisor(context) do
    name = :"doctor_tasks_#{:erlang.phash2(context.test)}"
    start_supervised!({Task.Supervisor, name: name}, id: name)
    name
  end

  describe "descriptor adaptation" do
    test "adapts a Checks result into the typed M34 descriptor shape" do
      spec =
        spec("readiness", fn -> %{name: "readiness", status: :warn, detail: "no provider"} end)

      result = Descriptor.run(spec)

      assert result["id"] == "readiness"
      assert result["category"] == "runtime"
      assert result["severity"] == "critical"
      assert result["applicability"] == "always"
      assert result["origin"] == "engine"
      assert result["status"] == "warning"
      assert result["summary"] == "no provider"
      assert result["evidence"] == %{"source_name" => "readiness", "source_status" => "warn"}
      assert result["remediation_code"] == "readiness.warning"
      assert is_integer(result["duration_ms"]) and result["duration_ms"] >= 0
      assert {:ok, _dt, 0} = DateTime.from_iso8601(result["finished_at"])
    end

    # `not_applicable` means "this distribution does not have this check"; it is
    # not `unavailable`, which means the check broke. Collapsing them tells an
    # operator on a correct install that a check failed to run.
    test "maps every Checks status and a skipped check onto the M34 status vocabulary" do
      for {check_status, expected} <- [
            {:ok, "passed"},
            {:warn, "warning"},
            {:fail, "failed"},
            {:not_applicable, "not_applicable"}
          ] do
        spec = spec("readiness", fn -> %{name: "n", status: check_status, detail: "d"} end)
        assert Descriptor.run(spec)["status"] == expected
      end

      assert "not_applicable" in Descriptor.statuses()

      skipped = spec("harness", fn -> nil end)
      assert Descriptor.run(skipped)["status"] == "skipped"
      assert Descriptor.run(skipped)["remediation_code"] == nil
    end

    test "a raising check becomes an unavailable descriptor, never a crashed session" do
      spec = spec("plugins", fn -> raise "boom /Users/someone/.fermix/config.toml" end)

      result = Descriptor.run(spec)

      assert result["status"] == "unavailable"
      refute result["summary"] =~ "/Users/someone"
    end

    # M34 §2: no `inspect(reason)` output crosses the native boundary. An exit
    # reason routinely embeds the call arguments, so the summary carries the
    # exit kind and nothing else.
    test "an exiting check reports a typed exit, never the inspected reason" do
      spec =
        spec("plugins", fn ->
          exit({:timeout, {GenServer, :call, [Runtime, {:install, %{token: "s3cr3t-value"}}, 5]}})
        end)

      result = Descriptor.run(spec)

      assert result["status"] == "unavailable"
      assert result["evidence"] == %{"exit_kind" => "exit"}
      refute result["summary"] =~ "s3cr3t-value"
      refute result["summary"] =~ "GenServer"
      refute result["summary"] =~ "install"
    end

    test "summaries are redacted and bounded" do
      long = String.duplicate("x", 400)

      secret =
        spec("plaintext secrets", fn ->
          %{
            name: "n",
            status: :fail,
            detail: "key sk-ABCDEFGHIJKLMNOPQRSTUVWX in /Users/rae/.fermix"
          }
        end)

      assert result = Descriptor.run(secret)
      refute result["summary"] =~ "sk-ABCDEFGHIJKLMNOPQRSTUVWX"
      refute result["summary"] =~ "/Users/rae"

      bounded = Descriptor.run(spec("n", fn -> %{name: "n", status: :ok, detail: long} end))
      assert byte_size(bounded["summary"]) <= 256
    end

    test "the engine catalog is well formed and excludes prompting and metered checks" do
      for scope <- [:local, :network] do
        catalog = Descriptor.catalog(scope)

        refute Enum.empty?(catalog)
        assert length(Enum.uniq_by(catalog, & &1.id)) == length(catalog)

        for entry <- catalog do
          assert is_function(entry.run, 0)
          assert entry.origin == :engine
          assert entry.category in Descriptor.categories()
          assert entry.severity in Descriptor.severities()
          assert entry.applicability in Descriptor.applicabilities()
        end
      end

      ids = Enum.map(Descriptor.catalog(:local) ++ Descriptor.catalog(:network), & &1.id)
      refute "computer_use_permissions" in ids
      refute "place_probe" in ids
    end

    # The two distribution rows answer instantly and offline under `macos_app`
    # — they are `not_applicable` by construction there. Leaving them in the
    # network catalog means plain `fermix doctor` never prints them, which is
    # the output self-knowledge and the eval case describe.
    test "the distribution rows follow the engine they can answer for" do
      app = [build_info: AppBuildInfo]
      standalone = [build_info: StandaloneBuildInfo]

      assert "binary_integrity" in ids(:local, app)
      assert "upgrade_available" in ids(:local, app)
      refute "binary_integrity" in ids(:network, app)
      refute "upgrade_available" in ids(:network, app)

      refute "binary_integrity" in ids(:local, standalone)
      assert "binary_integrity" in ids(:network, standalone)
      assert "upgrade_available" in ids(:network, standalone)
    end

    # A healthy app-managed install has no legacy unit by design. Reporting that
    # as a critical warning that names `fermix service install` — a verb the same
    # engine refuses — makes a correct install look broken.
    test "the legacy service unit row is not applicable on an app-managed engine" do
      spec =
        Enum.find(
          Descriptor.catalog(:local, build_info: AppBuildInfo),
          &(&1.id == "service_unit")
        )

      assert Descriptor.run(spec)["status"] == "not_applicable"
    end
  end

  describe "sessions" do
    test "runs a scope to completion and reports typed results", %{server: server} do
      specs = [
        spec("readiness", fn -> %{name: "readiness", status: :ok, detail: "ready"} end),
        spec("plugins", fn -> %{name: "plugins", status: :fail, detail: "broken"} end)
      ]

      assert {:ok, %{"session_id" => session_id, "status" => "running", "scope" => "local"}} =
               Doctor.start(server: server, scope: :local, descriptors: specs)

      assert {:ok, view} = await_status(server, session_id, "completed")
      assert view["budget_ms"] == Doctor.budget_ms(:local)
      assert view["total"] == 2
      assert Enum.map(view["checks"], & &1["status"]) == ["passed", "failed"]
      assert view["summary"]["passed"] == 1
      assert view["summary"]["failed"] == 1
      assert is_integer(view["duration_ms"])
      assert {:ok, _dt, 0} = DateTime.from_iso8601(view["finished_at"])
    end

    test "network scope carries the 30 second whole-run budget", %{server: server} do
      specs = [spec("web search", fn -> %{name: "web search", status: :ok, detail: "ok"} end)]

      assert {:ok, %{"session_id" => session_id}} =
               Doctor.start(server: server, scope: :network, descriptors: specs)

      assert {:ok, view} = await_status(server, session_id, "completed")
      assert view["scope"] == "network"
      assert view["budget_ms"] == Doctor.budget_ms(:network)
      assert Doctor.budget_ms(:local) == 10_000
      assert Doctor.budget_ms(:network) == 30_000
    end

    test "the whole-run budget times the run out and marks unrun checks timed_out", %{
      server: server
    } do
      specs = [
        spec("stall", fn ->
          Process.sleep(5_000)
          %{name: "stall", status: :ok, detail: "never"}
        end),
        spec("plugins", fn -> %{name: "plugins", status: :ok, detail: "never"} end)
      ]

      assert {:ok, %{"session_id" => session_id}} =
               Doctor.start(server: server, scope: :local, descriptors: specs, budget_ms: 60)

      assert {:ok, view} = await_status(server, session_id, "timed_out")
      assert Enum.map(view["checks"], & &1["status"]) == ["timed_out", "timed_out"]
      assert view["summary"]["timed_out"] == 2
    end

    test "cancel stops the run and marks the remaining checks cancelled", %{server: server} do
      parent = self()

      specs = [
        spec("stall", fn ->
          send(parent, :running)
          Process.sleep(5_000)
          %{name: "stall", status: :ok, detail: "never"}
        end),
        spec("plugins", fn -> %{name: "plugins", status: :ok, detail: "never"} end)
      ]

      assert {:ok, %{"session_id" => session_id}} =
               Doctor.start(server: server, scope: :local, descriptors: specs)

      assert_receive :running, 1_000
      assert {:ok, %{"status" => "cancelled"}} = Doctor.cancel(session_id, server: server)
      assert {:ok, view} = Doctor.get(session_id, server: server)
      assert Enum.map(view["checks"], & &1["status"]) == ["cancelled", "cancelled"]
    end

    test "concurrency is bounded", %{server: server} do
      specs = [spec("stall", fn -> Process.sleep(5_000) end)]

      for _ <- 1..Doctor.max_concurrent_sessions() do
        assert {:ok, _view} = Doctor.start(server: server, scope: :local, descriptors: specs)
      end

      assert {:error, :busy} = Doctor.start(server: server, scope: :local, descriptors: specs)
    end

    test "retention is bounded and evicts the oldest finished session", %{server: server} do
      specs = [spec("readiness", fn -> %{name: "readiness", status: :ok, detail: "ok"} end)]

      ids =
        for _ <- 1..(Doctor.max_retained_sessions() + 2) do
          {:ok, %{"session_id" => session_id}} =
            Doctor.start(server: server, scope: :local, descriptors: specs)

          {:ok, _view} = await_status(server, session_id, "completed")
          session_id
        end

      assert {:error, :unknown_session} = Doctor.get(hd(ids), server: server)
      assert {:ok, _view} = Doctor.get(List.last(ids), server: server)
    end

    test "an unknown session id is refused", %{server: server} do
      assert {:error, :unknown_session} = Doctor.get("doctor:missing", server: server)
      assert {:error, :unknown_session} = Doctor.cancel("doctor:missing", server: server)
    end

    test "an invalid scope is refused", %{server: server} do
      assert {:error, :invalid_scope} = Doctor.start(server: server, scope: :everything)
    end

    test "sessions emit the doctor run bookends with one session id", %{server: server} do
      handler_id = "doctor-session-telemetry-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach_many(
        handler_id,
        [
          [:fermix, :doctor, :session_start],
          [:fermix, :doctor, :session_complete]
        ],
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      specs = [spec("readiness", fn -> %{name: "readiness", status: :ok, detail: "ok"} end)]

      assert {:ok, %{"session_id" => session_id}} =
               Doctor.start(server: server, scope: :local, descriptors: specs)

      assert_receive {:telemetry, [:fermix, :doctor, :session_start], _meas, start_meta}, 1_000
      assert start_meta.session_id == session_id
      assert start_meta.agent == "doctor"
      assert start_meta.scope == :local

      assert_receive {:telemetry, [:fermix, :doctor, :session_complete], meas, complete_meta},
                     1_000

      assert complete_meta.session_id == session_id
      assert complete_meta.status == "completed"
      assert is_integer(meas.duration_ms)
    end
  end

  defp spec(id, run) do
    %{
      id: id,
      category: :runtime,
      severity: :critical,
      applicability: :always,
      origin: :engine,
      run: run
    }
  end

  defp await_status(server, session_id, status, attempts \\ 100)

  defp await_status(_server, _session_id, status, 0),
    do: flunk("session never reached #{status}")

  defp await_status(server, session_id, status, attempts) do
    case Doctor.get(session_id, server: server) do
      {:ok, %{"status" => ^status} = view} ->
        {:ok, view}

      _other ->
        Process.sleep(20)
        await_status(server, session_id, status, attempts - 1)
    end
  end
end
