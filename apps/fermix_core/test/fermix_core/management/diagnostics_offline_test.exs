defmodule FermixCore.Management.DiagnosticsOfflineTest do
  @moduledoc """
  The offline diagnostics bundle (M38 §11.2).

  Every source is injected — the service inspector, the log reader, the journal
  runner and the executable lookup — so every unavailable case is reachable and
  nothing here touches a host service manager, a journal or a keyring.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Management.Diagnostics.Offline

  defmodule PackagedBuildInfo do
    @moduledoc false

    def public_identity do
      %{
        "engine_id" => "fermix-core",
        "product_version" => "1.2.3",
        "build_id" => "release-9",
        "source_commit" => String.duplicate("a", 40),
        "distribution_identity" => "linux_package",
        "artifact_target" => "linux_x86_64",
        "architecture" => "x86_64"
      }
    end
  end

  # The collection runs inside its own task, so a fixture in the test process's
  # dictionary would not reach it: the stub carries the status itself.
  defmodule AnsweringService do
    @moduledoc false

    def status(_opts) do
      {:ok,
       %{
         "binding" => %{"state" => "bound", "home" => "/home/operator/.fermix", "reason" => nil},
         "unit" => %{
           "effective_path" => "/usr/lib/systemd/user/fermix.service",
           "vendor" => true,
           "legacy_generated" => false,
           "foreign" => false,
           "need_daemon_reload" => false
         },
         "enabled" => true,
         "active" => true,
         "sub_state" => "running",
         "pid" => 4711,
         "invocation_id" => "4b1e9d1a",
         "restart_count" => 0,
         "linger" => "enabled",
         "path_source" => "engine_baseline",
         "listener" => %{
           "port" => 4030,
           "origin" => "http://127.0.0.1:4030",
           "source" => "daemon"
         },
         "installed" => PackagedBuildInfo.public_identity(),
         "running" => PackagedBuildInfo.public_identity(),
         "alignment" => "aligned"
       }}
    end
  end

  defmodule ForeignService do
    @moduledoc false
    def status(_opts), do: {:error, :foreign_distribution}
  end

  defmodule UnreachableService do
    @moduledoc false
    def status(_opts), do: {:error, :user_manager_unreachable}
  end

  describe "the envelope" do
    test "carries its own schema version, a timestamp and the explicit mode" do
      assert {:ok, report} = Offline.build(opts())

      assert report["schema_version"] == 1
      assert report["mode"] == "offline"
      assert {:ok, _dt, _offset} = DateTime.from_iso8601(report["generated_at"])
      assert Map.keys(report["sources"]) |> Enum.sort() == ~w(
               desktop_session doctor engine logs secret_backend service
             )
    end

    test "every source carries a status and an observation time" do
      assert {:ok, report} = Offline.build(opts())

      for {name, source} <- report["sources"] do
        assert source["status"] in ~w(available unavailable not_applicable), name
        assert {:ok, _dt, _offset} = DateTime.from_iso8601(source["observed_at"])

        case source["status"] do
          "available" -> assert Map.has_key?(source, "data"), name
          _absent -> assert is_binary(source["reason"]), name
        end
      end
    end
  end

  describe "the engine source" do
    test "publishes the compiled identity and its manifest verdict" do
      assert {:ok, report} = Offline.build(opts())
      engine = report["sources"]["engine"]["data"]

      assert engine["installed"]["build_id"] == "release-9"
      assert engine["installed"]["distribution_identity"] == "linux_package"
      assert engine["installed"]["integrity"] == "unreadable"
    end

    # The one identity an offline export cannot have is named rather than
    # omitted: no omitted field is read as healthy.
    test "names the running identity as unavailable rather than leaving it out" do
      assert {:ok, report} = Offline.build(opts())
      engine = report["sources"]["engine"]["data"]

      assert engine["running"] == nil
      assert engine["running_status"] == "unavailable"
    end

    test "a manifest that disagrees with the executable is an integrity failure" do
      manifest = %{PackagedBuildInfo.public_identity() | "build_id" => "release-8"}
      path = write_manifest(manifest)

      assert {:ok, report} = Offline.build(opts(engine_manifest_path: path))
      assert report["sources"]["engine"]["data"]["installed"]["integrity"] == "mismatched"
    end
  end

  describe "the service source" do
    test "projects the shared inspector onto the allowlist" do
      assert {:ok, report} = Offline.build(opts(service: AnsweringService))
      service = report["sources"]["service"]["data"]

      assert service["active"] == true
      assert service["sub_state"] == "running"
      assert service["pid"] == 4711
      assert service["linger"] == "enabled"
      assert service["alignment"] == "aligned"
      assert service["binding_state"] == "bound"
      assert service["unit_vendor"] == true
      assert service["listener_port"] == 4030
    end

    # §11.2 excludes absolute user paths and account names. The binding's home
    # and the effective unit path are both, so the state is published and the
    # path is not.
    test "never carries the bound home or the unit path" do
      assert {:ok, report} = Offline.build(opts(service: AnsweringService))
      service = report["sources"]["service"]["data"]

      refute Map.has_key?(service, "binding")
      refute Map.has_key?(service, "unit")

      encoded = Jason.encode!(service)
      refute encoded =~ "/home/operator"
      refute encoded =~ "systemd/user"
    end

    test "another distribution is not applicable, not a fault" do
      assert {:ok, report} = Offline.build(opts(service: ForeignService))

      assert report["sources"]["service"]["status"] == "not_applicable"
      assert report["sources"]["service"]["reason"] =~ "packaged install"
    end

    # The reason a support reader sees is the sentence the operator was shown,
    # not the atom the CLI decided it with: a bundle carrying `:atom` names a
    # vocabulary nobody outside this repository can look up.
    test "an unreachable user manager is unavailable with its published sentence" do
      assert {:ok, report} = Offline.build(opts(service: UnreachableService))

      assert report["sources"]["service"]["status"] == "unavailable"
      assert report["sources"]["service"]["reason"] =~ "no user service manager"
      refute report["sources"]["service"]["reason"] =~ "user_manager_unreachable"
    end
  end

  # Doctor's checks reach the daemon, so running them offline would report a
  # broken engine as a broken host.
  test "the doctor source is unavailable and says why" do
    assert {:ok, report} = Offline.build(opts())

    assert report["sources"]["doctor"]["status"] == "unavailable"
    assert report["sources"]["doctor"]["reason"] =~ "daemon"
  end

  # A lingering daemon's environment is not the graphical session, and §11.2
  # forbids reconstructing one from it.
  test "the desktop session source is supplied by the client, never invented" do
    assert {:ok, report} = Offline.build(opts())

    assert report["sources"]["desktop_session"]["status"] == "unavailable"
    assert report["sources"]["desktop_session"]["reason"] =~ "graphical client"
  end

  describe "the logs source" do
    test "carries both named places, labelled per entry" do
      assert {:ok, report} = Offline.build(opts())
      logs = report["sources"]["logs"]["data"]

      assert logs["file_status"] == "available"
      assert logs["journal_status"] == "available"
      assert logs["count"] == 2

      assert Enum.map(logs["entries"], & &1["source"]) == ["file", "journal"]
      assert Enum.find(logs["entries"], &(&1["source"] == "journal"))["message"] =~ "started"
    end

    test "an unreadable log file leaves the journal half intact" do
      assert {:ok, report} =
               Offline.build(opts(logs_reader: fn _params -> {:error, :unreadable} end))

      logs = report["sources"]["logs"]["data"]

      assert logs["file_status"] == "unavailable"
      assert logs["journal_status"] == "available"
      assert Enum.map(logs["entries"], & &1["source"]) == ["journal"]
    end

    test "an absent journalctl is named, and the file half still answers" do
      assert {:ok, report} = Offline.build(opts(cmd: fn _executable, _args -> :absent end))
      logs = report["sources"]["logs"]["data"]

      assert logs["journal_status"] == "unavailable"
      assert logs["journal_reason"] =~ "not installed"
      assert logs["file_status"] == "available"
    end

    test "a journal that refuses quotes its own words" do
      runner = fn _executable, _args -> {"No journal files were found.", 1} end

      assert {:ok, report} = Offline.build(opts(cmd: runner))
      logs = report["sources"]["logs"]["data"]

      assert logs["journal_status"] == "unavailable"
      assert logs["journal_reason"] =~ "No journal files were found."
    end

    test "a journal read that runs long is bounded rather than waited on" do
      assert {:ok, report} = Offline.build(opts(cmd: fn _executable, _args -> :timeout end))

      assert report["sources"]["logs"]["data"]["journal_reason"] =~ "in time"
    end
  end

  describe "the secret backend source" do
    test "reports tool presence and reads nothing" do
      assert {:ok, report} =
               Offline.build(opts(os: {:unix, :linux}, find_executable: fn _n -> "/x" end))

      assert report["sources"]["secret_backend"]["data"] == %{
               "tool" => "secret-tool",
               "present" => true
             }
    end

    test "an absent tool is a fact, not a failure" do
      assert {:ok, report} =
               Offline.build(opts(os: {:unix, :linux}, find_executable: fn _n -> nil end))

      assert report["sources"]["secret_backend"]["data"]["present"] == false
    end

    test "macOS names its own tool" do
      assert {:ok, report} = Offline.build(opts(os: {:unix, :darwin}))

      assert report["sources"]["secret_backend"]["data"]["tool"] == "security"
    end
  end

  describe "redaction" do
    # Every class §11.2 excludes, seeded at once. A bundle that carries any of
    # them is a support file that leaks the thing it was collected to explain.
    @excluded [
      "sk-proj-abcdefghijklmnopqrstuvwxyz0123456789",
      "Bearer eyJhbGciOiJIUzI1NiJ9.payload.signature",
      "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9",
      "/Users/operator/.fermix/config.toml",
      "/home/operator/.fermix/memory.db",
      "http://127.0.0.1:4030/setup?t=launch-token-9f2b",
      "api_key = sk-live-9f2babcdefghijklmnopqrstuvwxyz",
      # A shape the redactor matches (the prefix plus ten or more token
      # characters) that no scanner reads as a live credential.
      "xoxb-fixture-token-that-must-never-appear"
    ]

    test "no excluded class survives, from the log file or the journal" do
      seeded = Enum.join(@excluded, " ")

      logs_reader = fn _params ->
        {:ok, %{"entries" => [%{"time" => "t", "level" => "error", "message" => seeded}]}}
      end

      runner = fn _executable, _args ->
        {"2026-09-13T10:00:00+0000 host fermix[1]: #{seeded}", 0}
      end

      assert {:ok, report} = Offline.build(opts(logs_reader: logs_reader, cmd: runner))
      encoded = Jason.encode!(report)

      for secret <- @excluded do
        refute encoded =~ secret, "the bundle carried #{secret}"
      end
    end

    test "a service refusal's own words are scrubbed before they are published" do
      defmodule LeakingService do
        @moduledoc false
        def status(_opts) do
          {:error, {:read_failed, "/Users/operator/.fermix/config.toml"}}
        end
      end

      assert {:ok, report} = Offline.build(opts(service: LeakingService))

      refute report["sources"]["service"]["reason"] =~ "/Users/operator"
    end
  end

  describe "bounds" do
    test "a collection that runs past the deadline is an error, never a bundle" do
      slow = fn _executable, _args ->
        Process.sleep(200)
        {"", 0}
      end

      assert Offline.build(opts(cmd: slow, deadline_ms: 10)) == {:error, :deadline_exceeded}
    end

    test "a bundle over the ceiling refuses rather than losing its tail" do
      oversized = String.duplicate("x", Offline.max_bytes() + 1)

      logs_reader = fn _params ->
        {:ok, %{"entries" => [%{"time" => "t", "level" => "info", "message" => oversized}]}}
      end

      assert Offline.build(opts(logs_reader: logs_reader)) == {:error, :too_large}
    end
  end

  defp opts(overrides \\ []) do
    defaults = [
      build_info: PackagedBuildInfo,
      service: ForeignService,
      engine_manifest_path: Path.join(System.tmp_dir!(), "fermix-offline-absent-manifest.json"),
      logs_reader: fn _params ->
        {:ok,
         %{
           "entries" => [
             %{"time" => "2026-09-13T10:00:00Z", "level" => "info", "message" => "ok"}
           ]
         }}
      end,
      cmd: fn "journalctl", _args -> {"2026-09-13T10:00:00+0000 host fermix[1]: started\n", 0} end,
      find_executable: fn _name -> "/usr/bin/secret-tool" end,
      os: {:unix, :linux}
    ]

    Keyword.merge(defaults, overrides)
  end

  defp write_manifest(manifest) do
    path =
      Path.join(
        System.tmp_dir!(),
        "fermix-offline-manifest-#{System.unique_integer([:positive])}.json"
      )

    File.write!(path, Jason.encode!(manifest))
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(path) end)
    path
  end
end
