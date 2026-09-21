defmodule Fermix.CLI.Service.StatusTest do
  @moduledoc """
  The pure half of `fermix service status` (M38 §4.4.1, §9.2).

  Nothing here runs a command or reads a file: every input is the evidence
  `Fermix.CLI.Service` already gathered.
  """

  use ExUnit.Case, async: true

  alias Fermix.CLI.Service.Status

  @installed %{
    "engine_id" => "fermix-core",
    "product_version" => "1.2.3",
    "build_id" => "release-9",
    "source_commit" => String.duplicate("a", 40),
    "distribution_identity" => "linux_package",
    "artifact_target" => "linux_x86_64",
    "architecture" => "x86_64"
  }

  @running Map.drop(@installed, ["engine_id"])

  @properties %{
    "LoadState" => "loaded",
    "UnitFileState" => "enabled",
    "ActiveState" => "active",
    "SubState" => "running",
    "MainPID" => "4711",
    "ExecMainPID" => "4711",
    "InvocationID" => "4b1e9d1a",
    "NRestarts" => "2",
    "NeedDaemonReload" => "no",
    "FragmentPath" => "/usr/lib/systemd/user/fermix.service",
    "DropInPaths" => ""
  }

  describe "alignment/2" do
    test "matching build ids are aligned" do
      assert Status.alignment(@installed, @running) == "aligned"
    end

    test "differing build ids call for a restart" do
      assert Status.alignment(@installed, %{@running | "build_id" => "release-10"}) ==
               "pending_restart"
    end

    test "no answering daemon is not running" do
      assert Status.alignment(@installed, nil) == "not_running"
    end

    # §9.2: a build id is compared with a build id. A product version is a
    # display value, and inferring skew from it is the defect this rule exists
    # to prevent.
    test "an absent build id on either side is unknown, never inferred from a version" do
      older = %{@running | "build_id" => nil, "product_version" => "1.0.0"}

      assert Status.alignment(@installed, older) == "unknown"
      assert Status.alignment(%{@installed | "build_id" => nil}, @running) == "unknown"
    end

    test "a different distribution or architecture is an ownership conflict" do
      assert Status.alignment(@installed, %{@running | "distribution_identity" => "standalone"}) ==
               "ownership_conflict"

      assert Status.alignment(@installed, %{@running | "architecture" => "arm64"}) ==
               "ownership_conflict"
    end

    # The conflict is decided before the build ids are read: a foreign daemon
    # whose build id happens to match is still a foreign daemon.
    test "an ownership conflict outranks a missing build id" do
      foreign = %{@running | "distribution_identity" => "standalone", "build_id" => nil}

      assert Status.alignment(@installed, foreign) == "ownership_conflict"
    end
  end

  describe "installed/2" do
    test "a manifest matching the compiled identity is verified" do
      assert Status.installed(@installed, {:ok, @installed})["integrity"] == "verified"
    end

    test "a manifest disagreeing with its own executable is an integrity failure" do
      manifest = %{@installed | "build_id" => "release-8"}

      assert Status.installed(@installed, {:ok, manifest})["integrity"] == "mismatched"
    end

    test "an unreadable manifest is unknown, not a failure and not a pass" do
      assert Status.installed(@installed, {:error, :enoent})["integrity"] == "unreadable"
    end

    # Reversed deliberately. This once asserted the opposite — that the
    # published identity is the compiled one and the manifest is only evidence
    # about it — which held while the answering code could be trusted to come
    # from the installed package. It cannot: a Burrito payload extracted by an
    # earlier package keeps running after an upgrade, so the compiled constants
    # describe an engine that is no longer installed. What is INSTALLED is what
    # the package put on disk, so the manifest is the identity.
    test "the published identity is the manifest's, because that is what is installed" do
      manifest = %{@installed | "build_id" => "release-8"}
      installed = Status.installed(@installed, {:ok, manifest})

      assert installed["build_id"] == "release-8"
      assert Map.keys(installed) == Enum.sort(Map.keys(@installed) ++ ["integrity"])
    end
  end

  describe "classify_unit/1" do
    test "no file at the user unit path is absent" do
      assert Status.classify_unit(nil) == :absent
    end

    test "the unit this binary used to write is recognised in both env spellings" do
      assert Status.classify_unit(legacy_unit("Environment=FERMIX_HOME=/home/o/.fermix")) ==
               :legacy_generated

      assert Status.classify_unit(legacy_unit(~s(Environment="FERMIX_HOME=/home/o/.fermix"))) ==
               :legacy_generated
    end

    test "anything else at that path is foreign and is never rewritten" do
      assert Status.classify_unit("[Service]\nExecStart=/usr/bin/other-daemon\n") == :foreign
      assert Status.classify_unit(legacy_unit("")) == :foreign
      assert Status.classify_unit("[Service]\nExecStart=/usr/bin/fermix run\n") == :foreign
    end
  end

  describe "legacy_home/1" do
    test "reads the home out of an unquoted assignment" do
      assert Status.legacy_home(legacy_unit("Environment=FERMIX_HOME=/home/o/.fermix")) ==
               {:ok, "/home/o/.fermix"}
    end

    # The quoted spelling is what the serializer writes, so migration has to
    # undo exactly what it did: doubled percent, escaped quote, escaped backslash.
    test "unescapes a quoted assignment carrying spaces and percent characters" do
      unit = legacy_unit(~s(Environment="FERMIX_HOME=/home/o/my 100%% fermix"))

      assert Status.legacy_home(unit) == {:ok, "/home/o/my 100% fermix"}
    end

    test "a unit with no home assignment has no home to migrate" do
      assert Status.legacy_home(legacy_unit("")) == :error
    end
  end

  describe "legacy_observability/1" do
    test "carries only the allowlisted observability assignments" do
      unit =
        legacy_unit("""
        Environment=FERMIX_HOME=/home/o/.fermix
        Environment="FERMIX_OPIK_ENABLED=1"
        Environment="FERMIX_OPIK_BASE_URL=http://localhost:5173/api"
        Environment=FERMIX_TRACE_CONTENT=0
        Environment=PATH=/usr/bin
        Environment=SOMETHING_ELSE=x\
        """)

      assert Status.legacy_observability(unit) == %{
               "FERMIX_OPIK_ENABLED" => "1",
               "FERMIX_OPIK_BASE_URL" => "http://localhost:5173/api",
               "FERMIX_TRACE_CONTENT" => "0"
             }
    end

    test "a unit with no observability values carries none" do
      assert Status.legacy_observability(legacy_unit("")) == %{}
    end
  end

  describe "build/1" do
    test "publishes every fact the interface renders" do
      status = Status.build(inputs())

      assert status["binding"] == %{
               "state" => "bound",
               "home" => "/home/o/.fermix",
               "reason" => nil
             }

      assert status["unit"] == %{
               "effective_path" => "/usr/lib/systemd/user/fermix.service",
               "vendor" => true,
               "legacy_generated" => false,
               "foreign" => false,
               "need_daemon_reload" => false
             }

      assert status["enabled"] == true
      assert status["active"] == true
      assert status["sub_state"] == "running"
      assert status["pid"] == 4711
      assert status["invocation_id"] == "4b1e9d1a"
      assert status["restart_count"] == 2
      assert status["linger"] == "enabled"
      assert status["path_source"] == "engine_baseline"
      assert status["installed"]["integrity"] == "verified"
      assert status["running"] == @running
      assert status["alignment"] == "aligned"

      assert status["listener"] == %{
               "port" => 4030,
               "origin" => "http://127.0.0.1:4030",
               "source" => "daemon"
             }
    end

    test "a fresh package has no binding, no unit and no running engine" do
      status = Status.build(%{inputs() | binding: {:error, :missing}, hello: nil})

      assert status["binding"] == %{"state" => "unbound", "home" => nil, "reason" => nil}
      assert status["running"] == nil
      assert status["alignment"] == "not_running"

      assert status["listener"] == %{"port" => nil, "origin" => nil, "source" => "unknown"}
    end

    # M38 §4.7. The status a STOPPED service answers still has to name the port
    # the next start will use — the whole reason the verb runs without a daemon.
    test "with no daemon the listener comes from the bound home's settings" do
      status =
        Status.build(%{
          inputs()
          | hello: nil,
            configured_listener: {:ok, %{port: 4555, source: :config}}
        })

      assert status["listener"] == %{
               "port" => 4555,
               "origin" => "http://127.0.0.1:4555",
               "source" => "config"
             }
    end

    test "an unset setting reports the default rather than an unknown" do
      status =
        Status.build(%{
          inputs()
          | hello: nil,
            configured_listener: {:ok, %{port: 4030, source: :default}}
        })

      assert status["listener"]["source"] == "default"
      assert status["listener"]["port"] == 4030
    end

    # A running daemon's own origin outranks the setting: the setting is what
    # the next start will use, and the origin is what something is listening on
    # now, which is the fact the interface has to render.
    test "a running daemon's published origin outranks the setting" do
      status =
        Status.build(%{inputs() | configured_listener: {:ok, %{port: 4555, source: :config}}})

      assert status["listener"]["port"] == 4030
      assert status["listener"]["source"] == "daemon"
    end

    test "an unreadable settings file is unknown, never a silent default" do
      status =
        Status.build(%{inputs() | hello: nil, configured_listener: {:error, :eacces}})

      assert status["listener"] == %{"port" => nil, "origin" => nil, "source" => "unknown"}
    end

    test "a malformed binding carries its sentence rather than a guessed home" do
      inputs = %{inputs() | binding: {:error, {:invalid, "The service home must be absolute."}}}
      status = Status.build(inputs)

      assert status["binding"] == %{
               "state" => "invalid",
               "home" => nil,
               "reason" => "The service home must be absolute."
             }
    end

    test "an intentionally disabled service is not an enabled-but-failed one" do
      properties = %{
        @properties
        | "UnitFileState" => "disabled",
          "ActiveState" => "inactive",
          "SubState" => "dead",
          "MainPID" => "0",
          "InvocationID" => "",
          "NRestarts" => "0"
      }

      status = Status.build(%{inputs() | properties: properties, hello: nil})

      assert status["enabled"] == false
      assert status["active"] == false
      assert status["sub_state"] == "dead"
      assert status["pid"] == nil
      assert status["invocation_id"] == nil
      assert status["restart_count"] == 0
    end

    test "a legacy or foreign unit shadowing the vendor unit is published as such" do
      legacy =
        Status.build(%{
          inputs()
          | user_unit: :legacy_generated,
            properties: %{
              @properties
              | "FragmentPath" => "/home/o/.config/systemd/user/fermix.service"
            }
        })

      assert legacy["unit"]["legacy_generated"] == true
      assert legacy["unit"]["vendor"] == false
      assert legacy["unit"]["foreign"] == false

      foreign = Status.build(%{inputs() | user_unit: :foreign})
      assert foreign["unit"]["foreign"] == true
      assert foreign["unit"]["legacy_generated"] == false
    end

    test "a pending unit reload is reported so a mutation reloads first" do
      properties = %{@properties | "NeedDaemonReload" => "yes"}

      assert Status.build(%{inputs() | properties: properties})["unit"]["need_daemon_reload"] ==
               true
    end

    test "an undeterminable linger state is unknown, never assumed off" do
      status = Status.build(%{inputs() | linger: {:error, :loginctl_absent}})

      assert status["linger"] == "unknown"
    end

    test "the whole result encodes as JSON with no surprises" do
      assert {:ok, _json} = Jason.encode(Status.build(inputs()))
    end
  end

  defp inputs do
    %{
      binding: {:ok, %{home: "/home/o/.fermix"}},
      properties: @properties,
      user_unit: :absent,
      linger: {:ok, true},
      installed: Status.installed(@installed, {:ok, @installed}),
      hello: %{
        "engine" => @running,
        "setup" => %{"origin" => "http://127.0.0.1:4030", "path" => "/setup"}
      },
      configured_listener: {:error, :unbound}
    }
  end

  defp legacy_unit(environment) do
    """
    [Unit]
    Description=Fermix multi-agent platform daemon (user-scope)

    [Service]
    Type=simple
    #{environment}
    ExecStart=/usr/local/bin/fermix run
    Restart=on-failure

    [Install]
    WantedBy=default.target
    """
  end
end
