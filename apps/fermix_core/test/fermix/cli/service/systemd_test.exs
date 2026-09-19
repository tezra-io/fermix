defmodule Fermix.CLI.Service.SystemdTest do
  @moduledoc """
  The systemd inspection and lifecycle surface (M38 §4.4, slice EA1 item 12).

  Every `systemctl` and `loginctl` invocation goes through the injected `:cmd`
  runner, so no case touches the host's service manager.
  """

  use ExUnit.Case, async: true

  alias Fermix.CLI.Service.Systemd

  @unit "fermix.service"

  # systemd answers `show` in its own property order, never the order the
  # properties were asked for. This is the order systemd 257 printed for exactly
  # this request, recorded from the unit in a Debian trixie container: a parser
  # that zips it positionally reads the PID as the load state.
  @show_output """
  MainPID=4711
  NRestarts=2
  ExecMainPID=4711
  LoadState=loaded
  ActiveState=active
  SubState=running
  FragmentPath=/usr/lib/systemd/user/fermix.service
  DropInPaths=/home/o/.config/systemd/user/fermix.service.d/fermix-observability.conf
  UnitFileState=enabled
  NeedDaemonReload=no
  InvocationID=4b1e9d1a9a0b4f3f9c2f0d5d6a7b8c9d
  """

  @show_properties %{
    "LoadState" => "loaded",
    "UnitFileState" => "enabled",
    "ActiveState" => "active",
    "SubState" => "running",
    "MainPID" => "4711",
    "ExecMainPID" => "4711",
    "InvocationID" => "4b1e9d1a9a0b4f3f9c2f0d5d6a7b8c9d",
    "NRestarts" => "2",
    "NeedDaemonReload" => "no",
    "FragmentPath" => "/usr/lib/systemd/user/fermix.service",
    "DropInPaths" => "/home/o/.config/systemd/user/fermix.service.d/fermix-observability.conf"
  }

  defp recorder(result) do
    test = self()

    fn executable, args ->
      send(test, {:ran, executable, args})
      result
    end
  end

  describe "show/2" do
    test "asks the user manager for the properties status reports, in one call" do
      assert {:ok, properties} = Systemd.show(@unit, cmd: recorder({@show_output, 0}))

      assert_received {:ran, "systemctl", args}
      assert ["--user", "show", @unit, "-p", requested] = args

      assert requested ==
               "LoadState,UnitFileState,ActiveState,SubState,MainPID,ExecMainPID," <>
                 "InvocationID,NRestarts,NeedDaemonReload,FragmentPath,DropInPaths"

      assert properties == @show_properties
    end

    # The defect a real systemd 257 found: the answer's order is systemd's, and
    # zipping it against the requested order files a PID under a state.
    test "every value lands under its own key whatever order the manager answers in" do
      reversed =
        @show_output
        |> String.split("\n", trim: true)
        |> Enum.reverse()
        |> Enum.join("\n")

      assert Systemd.show(@unit, cmd: recorder({reversed <> "\n", 0})) == {:ok, @show_properties}

      shuffled =
        @show_output
        |> String.split("\n", trim: true)
        |> Enum.shuffle()
        |> Enum.join("\n")

      assert {:ok, properties} = Systemd.show(@unit, cmd: recorder({shuffled, 0}))
      assert properties["ActiveState"] == "active"
      assert properties["MainPID"] == "4711"
      assert properties["SubState"] == "running"
    end

    test "an empty value stays an empty string rather than vanishing" do
      output = String.replace(@show_output, ~r/^DropInPaths=.*$/m, "DropInPaths=")

      assert {:ok, properties} = Systemd.show(@unit, cmd: recorder({output, 0}))
      assert properties["DropInPaths"] == ""
      assert properties["FragmentPath"] == "/usr/lib/systemd/user/fermix.service"
    end

    # An `Environment=` drop-in path, or any value systemd prints, may carry an
    # equals sign; only the first one separates the key from the value.
    test "a value carrying an equals sign is split on the first one only" do
      output = String.replace(@show_output, ~r/^DropInPaths=.*$/m, "DropInPaths=/etc/a=b.conf")

      assert {:ok, properties} = Systemd.show(@unit, cmd: recorder({output, 0}))
      assert properties["DropInPaths"] == "/etc/a=b.conf"
    end

    # Nothing is guessed and nothing is skipped: a property the manager did not
    # answer is named, so the caller never reads a default as a fact.
    test "a property the manager did not answer is named, never filled in" do
      output = String.replace(@show_output, ~r/^SubState=.*\n/m, "")

      assert Systemd.show(@unit, cmd: recorder({output, 0})) ==
               {:error, {:missing_show_property, "SubState"}}
    end

    test "a truncated answer refuses on the first property it is missing" do
      assert Systemd.show(@unit, cmd: recorder({"LoadState=loaded\n", 0})) ==
               {:error, {:missing_show_property, "UnitFileState"}}
    end

    # A line that is not an assignment contributes no property, so the answer is
    # short and the missing-property refusal catches it.
    test "a line that is not an assignment is not read as a value" do
      output = String.replace(@show_output, "SubState=running", "SubState")

      assert Systemd.show(@unit, cmd: recorder({output, 0})) ==
               {:error, {:missing_show_property, "SubState"}}
    end

    # M38 §4.4.1: an unreachable user manager is a structured error, never an
    # inactive service — they call for different remedies.
    test "an unreachable user manager is its own error, not an inactive unit" do
      for output <- [
            "Failed to connect to bus: No medium found",
            "Failed to connect to user scope bus via local transport: Permission denied"
          ] do
        assert Systemd.show(@unit, cmd: recorder({output, 1})) ==
                 {:error, :user_manager_unreachable}
      end
    end

    # A container, or a distribution that ships no systemd at all, has no
    # `systemctl` to run: `System.cmd/3` raises there, which printed a stack
    # trace where a packaged `fermix service status` owes a sentence (found by
    # installing the real deb in debian:12).
    test "a host with no systemctl at all answers the same structured error" do
      assert Systemd.show(@unit, cmd: fn _executable, _args -> :absent end) ==
               {:error, :user_manager_unreachable}

      assert Systemd.daemon_reload(cmd: fn _executable, _args -> :absent end) ==
               {:error, :user_manager_unreachable}
    end

    # The "not loaded" tolerance belongs to `reset_failed/2` alone: a unit whose
    # properties cannot be read is not a unit whose state was already clear.
    test "any other failure keeps the exit code and the manager's own words" do
      assert Systemd.show(@unit, cmd: recorder({"Unit fermix.service not loaded.\n", 4})) ==
               {:error, {:systemctl_failed, 4, "Unit fermix.service not loaded."}}
    end
  end

  describe "lifecycle verbs" do
    test "each verb issues exactly its own user-scope command" do
      expected = [
        {fn cmd -> Systemd.daemon_reload(cmd: cmd) end, ["--user", "daemon-reload"]},
        {fn cmd -> Systemd.reset_failed(@unit, cmd: cmd) end, ["--user", "reset-failed", @unit]},
        {fn cmd -> Systemd.enable_now(@unit, cmd: cmd) end, ["--user", "enable", "--now", @unit]},
        {fn cmd -> Systemd.disable_now(@unit, cmd: cmd) end,
         ["--user", "disable", "--now", @unit]},
        {fn cmd -> Systemd.restart(@unit, cmd: cmd) end, ["--user", "restart", @unit]}
      ]

      for {call, args} <- expected do
        assert call.(recorder({"", 0})) == :ok
        assert_received {:ran, "systemctl", ^args}
      end
    end

    test "a failing verb reports the exit code and the manager's own words" do
      assert Systemd.enable_now(@unit, cmd: recorder({"Failed to enable unit.\n", 1})) ==
               {:error, {:systemctl_failed, 1, "Failed to enable unit."}}
    end

    test "an unreachable user manager is reported the same way by every verb" do
      unreachable = recorder({"Failed to connect to bus: No such file or directory", 1})

      assert Systemd.daemon_reload(cmd: unreachable) == {:error, :user_manager_unreachable}
      assert Systemd.restart(@unit, cmd: unreachable) == {:error, :user_manager_unreachable}
    end
  end

  # A first install on a fresh account resets a unit nothing has loaded yet, and
  # systemd answers non-zero with "Unit fermix.service not loaded." There is no
  # failed state to clear, which is what this step wanted: refusing there would
  # refuse every first install (found by installing the real deb on systemd 257).
  describe "reset_failed/2" do
    test "a unit nothing has loaded yet has no failed state to clear" do
      assert Systemd.reset_failed(@unit, cmd: recorder({"Unit fermix.service not loaded.\n", 1})) ==
               :ok

      assert_received {:ran, "systemctl", ["--user", "reset-failed", @unit]}
    end

    test "the manager's own casing does not decide the outcome" do
      for output <- [
            "Unit fermix.service Not Loaded.",
            "Failed to reset-failed fermix.service: Unit fermix.service NOT LOADED."
          ] do
        assert Systemd.reset_failed(@unit, cmd: recorder({output, 1})) == :ok
      end
    end

    test "every other non-zero exit stays a refusal with its own words" do
      assert Systemd.reset_failed(@unit, cmd: recorder({"Access denied\n", 1})) ==
               {:error, {:systemctl_failed, 1, "Access denied"}}
    end

    test "an unreachable user manager and an absent systemctl keep their verdict" do
      unreachable = recorder({"Failed to connect to bus: No medium found", 1})

      assert Systemd.reset_failed(@unit, cmd: unreachable) ==
               {:error, :user_manager_unreachable}

      assert Systemd.reset_failed(@unit, cmd: fn _executable, _args -> :absent end) ==
               {:error, :user_manager_unreachable}
    end
  end

  describe "linger_state/1" do
    test "reads the account's own linger property" do
      assert Systemd.linger_state(linger_opts(recorder({"yes\n", 0}))) == {:ok, true}
      assert_received {:ran, "loginctl", ["show-user", "operator", "-p", "Linger", "--value"]}

      assert Systemd.linger_state(linger_opts(recorder({"no\n", 0}))) == {:ok, false}
    end

    test "an absent loginctl is its own outcome" do
      opts = [username: fn _opts -> "operator" end, find_executable: fn _name -> nil end]

      assert Systemd.linger_state(opts) == {:error, :loginctl_absent}
    end

    test "an undeterminable account refuses instead of guessing one" do
      opts = [username: fn _opts -> nil end, find_executable: fn _name -> "/usr/bin/loginctl" end]

      assert Systemd.linger_state(opts) == {:error, :no_identity}
    end

    test "an unreadable property is unknown, never assumed off" do
      assert {:error, {:linger_unknown, "Failed to get user: No such process"}} =
               Systemd.linger_state(
                 linger_opts(recorder({"Failed to get user: No such process\n", 1}))
               )
    end
  end

  describe "ensure_linger/1" do
    test "an account that already lingers is left alone" do
      assert Systemd.ensure_linger(linger_opts(recorder({"yes\n", 0}))) == :already_enabled
      assert_received {:ran, "loginctl", ["show-user" | _rest]}
      refute_received {:ran, "loginctl", ["enable-linger" | _rest]}
    end

    test "an account that does not linger is enabled once" do
      assert Systemd.ensure_linger(linger_opts(scripted([{"no\n", 0}, {"", 0}]))) == :ok

      assert_received {:ran, "loginctl", ["show-user" | _rest]}
      assert_received {:ran, "loginctl", ["enable-linger", "operator"]}
    end

    # Linger failure is fatal before enablement (M38 §4.3): there is no
    # "works while logged in" half-state to degrade to.
    test "a denied authorization carries the manager's own words back" do
      opts = linger_opts(scripted([{"no\n", 0}, {"Access denied\n", 1}]))

      assert Systemd.ensure_linger(opts) == {:error, {:linger_denied, "Access denied"}}
    end

    test "an absent loginctl and an undeterminable account stay distinct" do
      absent = [username: fn _opts -> "operator" end, find_executable: fn _name -> nil end]

      nameless = [
        username: fn _opts -> nil end,
        find_executable: fn _n -> "/usr/bin/loginctl" end
      ]

      assert Systemd.ensure_linger(absent) == {:error, :loginctl_absent}
      assert Systemd.ensure_linger(nameless) == {:error, :no_identity}
    end
  end

  defp linger_opts(cmd) do
    [
      cmd: cmd,
      username: fn _opts -> "operator" end,
      find_executable: fn _name -> "/usr/bin/loginctl" end
    ]
  end

  # A scripted runner answers each call in order, so a two-step sequence proves
  # the second command ran rather than the first one answering twice.
  defp scripted(results) do
    test = self()
    {:ok, agent} = Agent.start_link(fn -> results end)

    fn executable, args ->
      send(test, {:ran, executable, args})
      Agent.get_and_update(agent, fn [head | tail] -> {head, tail} end)
    end
  end
end
