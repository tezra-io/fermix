defmodule FermixCore.Sandbox.EnvHealthTest do
  # `async: false` because the refresh tests read the shared `:sandbox` app env,
  # and the module under test logs through the global Logger.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.Sandbox.Config
  alias FermixCore.Sandbox.EnvHealth

  @absent "FERMIX_TEST_ABSENT"
  @missing {:missing_env, "FERMIX_TEST_ABSENT"}

  setup do
    name = :"env_health_#{System.unique_integer([:positive])}"
    start_supervised!({EnvHealth, name: name})
    %{server: name}
  end

  test "a fresh instance reports nothing unresolved", %{server: server} do
    assert EnvHealth.unresolved(server: server) == []
  end

  test "records an unresolved name with its reason and when it was first seen", %{
    server: server
  } do
    EnvHealth.record(%{resolved: [], unresolved: [%{name: @absent, reason: @missing}]},
      server: server
    )

    assert [%{name: @absent, reason: @missing, since: %DateTime{}}] =
             EnvHealth.unresolved(server: server)
  end

  test "a name that resolves again is cleared", %{server: server} do
    EnvHealth.record(%{resolved: [], unresolved: [%{name: @absent, reason: @missing}]},
      server: server
    )

    EnvHealth.record(%{resolved: [@absent], unresolved: []}, server: server)

    assert EnvHealth.unresolved(server: server) == []
  end

  test "keeps the first observation while the same fault persists", %{server: server} do
    record = %{resolved: [], unresolved: [%{name: @absent, reason: @missing}]}

    EnvHealth.record(record, server: server)
    [%{since: first}] = EnvHealth.unresolved(server: server)

    EnvHealth.record(record, server: server)
    [%{since: again}] = EnvHealth.unresolved(server: server)

    assert again == first
  end

  test "a changed reason replaces the record", %{server: server} do
    EnvHealth.record(%{resolved: [], unresolved: [%{name: @absent, reason: @missing}]},
      server: server
    )

    failed = {:env_command_failed, "/usr/bin/security", 44, "not found"}

    EnvHealth.record(%{resolved: [], unresolved: [%{name: @absent, reason: failed}]},
      server: server
    )

    assert [%{name: @absent, reason: ^failed}] = EnvHealth.unresolved(server: server)
  end

  # 126 refusals over 26 days wrote nothing to the daemon log. One line on the
  # way in and one on the way out is the whole budget: a command that fails the
  # same way a hundred times must not write a hundred lines.
  test "logs once when a name stops resolving and once when it resolves again", %{
    server: server
  } do
    # The recovery line is `info`, which the suite's `warning` level hides;
    # the test sets the level it asserts against and puts it back.
    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)

    record = %{resolved: [], unresolved: [%{name: @absent, reason: @missing}]}

    first =
      capture_log(fn ->
        EnvHealth.record(record, server: server)
        EnvHealth.record(record, server: server)
        EnvHealth.unresolved(server: server)
      end)

    assert first =~ "FERMIX_TEST_ABSENT has no value Fermix can read"
    assert first =~ "run without it"
    assert length(String.split(first, "FERMIX_TEST_ABSENT has no value Fermix can read")) == 2

    recovered =
      capture_log(fn ->
        EnvHealth.record(%{resolved: [@absent], unresolved: []}, server: server)
        EnvHealth.record(%{resolved: [@absent], unresolved: []}, server: server)
        EnvHealth.unresolved(server: server)
      end)

    assert recovered =~ "FERMIX_TEST_ABSENT resolves again"
    assert length(String.split(recovered, "resolves again")) == 2
  end

  test "names are reported in a stable order", %{server: server} do
    EnvHealth.record(
      %{
        resolved: [],
        unresolved: [
          %{name: "FERMIX_TEST_ZULU", reason: {:missing_env, "FERMIX_TEST_ZULU"}},
          %{name: "FERMIX_TEST_ALPHA", reason: {:missing_env, "FERMIX_TEST_ALPHA"}}
        ]
      },
      server: server
    )

    assert ["FERMIX_TEST_ALPHA", "FERMIX_TEST_ZULU"] =
             Enum.map(EnvHealth.unresolved(server: server), & &1.name)
  end

  describe "refresh/1" do
    setup do
      sandbox = Application.get_env(:fermix_core, :sandbox)
      original = System.get_env(@absent)

      on_exit(fn ->
        case sandbox do
          nil -> Application.delete_env(:fermix_core, :sandbox)
          value -> Application.put_env(:fermix_core, :sandbox, value)
        end

        case original do
          nil -> System.delete_env(@absent)
          value -> System.put_env(@absent, value)
        end
      end)

      :ok
    end

    # The probe that readiness depends on before any command has run: boot and
    # every config apply call it, so a bad entry shows up the moment it lands.
    # It runs off the server, so the record lands a moment later.
    test "probes the current allow list", %{server: server} do
      System.delete_env(@absent)
      Application.put_env(:fermix_core, :sandbox, Config.normalize(env: [allow: [@absent]]))

      EnvHealth.refresh(server: server)

      assert [%{name: @absent, reason: @missing}] = await_names(server, [@absent])
    end

    test "clears a name the current allow list resolves", %{server: server} do
      EnvHealth.record(%{resolved: [], unresolved: [%{name: @absent, reason: @missing}]},
        server: server
      )

      System.put_env(@absent, "present-now")
      Application.put_env(:fermix_core, :sandbox, Config.normalize(env: [allow: [@absent]]))

      EnvHealth.refresh(server: server)

      assert await_names(server, []) == []
    end

    # A slow helper must never make the record unanswerable: the probe is off
    # the server, so a caller gets the record as it stands while the helper
    # runs, and the outcome lands when the helper is done.
    test "answers while a slow helper is still being probed", %{server: server} do
      sh = System.find_executable("sh") || "/bin/sh"

      Application.put_env(
        :fermix_core,
        :sandbox,
        Config.normalize(
          env: [
            allow: [@absent],
            sources: %{
              @absent => [source: :command, command: sh, args: ["-c", "sleep 0.3; exit 3"]]
            }
          ]
        )
      )

      EnvHealth.refresh(server: server)

      assert EnvHealth.unresolved(server: server) == []

      assert [%{name: @absent, reason: {:env_command_failed, ^sh, 3, ""}}] =
               await_names(server, [@absent])
    end
  end

  # Bounded: two seconds of ten-millisecond polls, then the last answer is the
  # assertion's to fail on.
  defp await_names(server, expected) do
    Enum.reduce_while(1..200, [], fn _tick, _last ->
      entries = EnvHealth.unresolved(server: server)

      if Enum.map(entries, & &1.name) == expected do
        {:halt, entries}
      else
        Process.sleep(10)
        {:cont, entries}
      end
    end)
  end

  # The tree-less CLI world: no process, and the defined answer is "nothing to
  # report", never a call into a process that is not running.
  test "answers empty and accepts records when the process is not running" do
    assert EnvHealth.unresolved(server: :no_such_env_health) == []
    assert :ok = EnvHealth.record(%{resolved: [], unresolved: []}, server: :no_such_env_health)
    assert :ok = EnvHealth.refresh(server: :no_such_env_health)
  end
end
