defmodule Fermix.CLI.ServiceInvocationTest do
  # Always On setup §9, the GNOME case: gnome-terminal-server is a systemd user
  # unit, so every shell it opens inherits `INVOCATION_ID`, and `fermix run`
  # there must still read as an engine nothing starts again. Sync: it sets the
  # VM's own `INVOCATION_ID`, as such a shell has it, and puts it back.
  use ExUnit.Case, async: false

  alias Fermix.CLI.Service
  alias FermixCore.Management.Lifecycle

  @terminal_server_unit "0::/user.slice/user-1000.slice/user@1000.service/app.slice/" <>
                          "gnome-terminal-server.service\n"

  setup do
    previous = System.get_env("INVOCATION_ID")
    System.put_env("INVOCATION_ID", "0f3b1c9a2d4e4f6a8b7c5d3e1f2a4b6c")

    on_exit(fn ->
      case previous do
        nil -> System.delete_env("INVOCATION_ID")
        value -> System.put_env("INVOCATION_ID", value)
      end
    end)
  end

  test "a shell a terminal server's unit opened is not Fermix's unit" do
    foreign = fn -> {:ok, @terminal_server_unit} end

    refute Service.systemd_invocation?(cgroup: foreign)

    refute Lifecycle.restarts_itself?(app_engine?: false, supervised?: false, cgroup: foreign)
  end
end
