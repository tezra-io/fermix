defmodule FermixCore.Setup.SecretService.ProbeTest do
  use ExUnit.Case, async: true

  alias FermixCore.Setup.SecretService.Probe

  @busctl "/usr/bin/busctl"
  @login "/org/freedesktop/secrets/collection/login"

  # A runner that answers each busctl question from a script keyed by the
  # D-Bus member being asked, and records every call, so a test can pin both
  # the verdict and that nothing beyond the three read-only questions ran.
  defp scripted(answers) do
    test_pid = self()

    fn @busctl, args ->
      send(test_pid, {:busctl, args})
      member = Enum.find(["NameHasOwner", "ReadAlias", "Locked"], &(&1 in args))
      Map.fetch!(answers, member)
    end
  end

  defp run(answers, opts \\ []) do
    Probe.run([runner: scripted(answers), find_executable: fn "busctl" -> @busctl end] ++ opts)
  end

  test "an unlocked default collection is available" do
    verdict =
      run(%{
        "NameHasOwner" => {:ok, "b true\n"},
        "ReadAlias" => {:ok, ~s(o "#{@login}"\n)},
        "Locked" => {:ok, "b false\n"}
      })

    assert %{store: :keyring, state: :available} = verdict
  end

  test "a locked default collection is locked, and says how it unlocks" do
    verdict =
      run(%{
        "NameHasOwner" => {:ok, "b true\n"},
        "ReadAlias" => {:ok, ~s(o "#{@login}"\n)},
        "Locked" => {:ok, "b true\n"}
      })

    assert %{state: :locked, sentence: sentence} = verdict
    assert sentence =~ "Passwords and Keys"
    assert sentence =~ "fingerprint"
  end

  test "every question is read-only, in order, bounded, and on the user bus" do
    run(%{
      "NameHasOwner" => {:ok, "b true\n"},
      "ReadAlias" => {:ok, ~s(o "#{@login}"\n)},
      "Locked" => {:ok, "b false\n"}
    })

    assert_received {:busctl, first}
    assert_received {:busctl, second}
    assert_received {:busctl, third}
    refute_received {:busctl, _fourth}

    for args <- [first, second, third] do
      assert "--user" in args
      assert "--timeout=1" in args

      refute Enum.any?(
               args,
               &(&1 in ["Unlock", "GetSecrets", "GetSecret", "CreateItem", "SetSecret"])
             )
    end

    # The first question goes to the bus itself, not to the service, so an
    # activatable keyring daemon is not started by the asking.
    assert ["--user", "--timeout=1", "call", "org.freedesktop.DBus", "/org/freedesktop/DBus" | _] =
             first

    assert "ReadAlias" in second
    assert "get-property" in third
    assert @login in third
  end

  test "no owner on the bus is service_absent, and no more questions are asked" do
    verdict = run(%{"NameHasOwner" => {:ok, "b false\n"}})

    assert %{state: :service_absent} = verdict
    assert_received {:busctl, _first}
    refute_received {:busctl, _second}
  end

  test "a bus that cannot be reached is no_session_bus" do
    # The second line is busctl's own, verbatim, from a Debian 12 shell with
    # neither variable set.
    for output <- [
          "Failed to connect to bus: No such file or directory\n",
          "Failed to set bus address: $DBUS_SESSION_BUS_ADDRESS and $XDG_RUNTIME_DIR not defined " <>
            "(consider using --machine=<user>@.host --user to connect to bus of other user)\n"
        ] do
      verdict = run(%{"NameHasOwner" => {:error, {:helper_failed, 1, output}}})
      assert %{state: :no_session_bus} = verdict
    end
  end

  test "no default collection is collection_unavailable" do
    verdict =
      run(%{
        "NameHasOwner" => {:ok, "b true\n"},
        "ReadAlias" => {:ok, ~s(o "/"\n)}
      })

    assert %{state: :collection_unavailable} = verdict
    refute_received {:busctl, ["--user", "--timeout=1", "get-property" | _]}
  end

  test "a collection path that is not an object path is not passed on" do
    verdict =
      run(%{
        "NameHasOwner" => {:ok, "b true\n"},
        "ReadAlias" => {:ok, ~s(o "/org/freedesktop/secrets/collection/x;rm -rf"\n)}
      })

    assert %{state: :unknown, evidence: evidence} = verdict
    assert evidence =~ "unexpected output"
    refute_received {:busctl, ["--user", "--timeout=1", "get-property" | _]}
  end

  test "an answer the probe cannot read is unknown, with bounded evidence" do
    long = String.duplicate("x", 1_000)

    verdict =
      run(%{
        "NameHasOwner" => {:ok, "b true\n"},
        "ReadAlias" => {:error, {:helper_failed, 1, long <> "\nsecond line"}}
      })

    assert %{state: :unknown, evidence: evidence} = verdict
    assert String.length(evidence) <= 220
    refute evidence =~ "second line"
  end

  test "a timed-out question is unknown, never a guess" do
    verdict =
      run(%{
        "NameHasOwner" => {:ok, "b true\n"},
        "ReadAlias" => {:ok, ~s(o "#{@login}"\n)},
        "Locked" => {:error, :timeout}
      })

    assert %{state: :unknown, evidence: "timed out" <> _} = verdict
  end

  test "without busctl the state is unknown and nothing is run" do
    verdict =
      Probe.run(
        runner: fn _, _ -> flunk("nothing should run") end,
        find_executable: fn _ -> nil end
      )

    assert %{state: :unknown, sentence: sentence} = verdict
    assert sentence =~ "busctl is not installed"
  end
end
