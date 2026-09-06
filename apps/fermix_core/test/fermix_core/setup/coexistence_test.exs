defmodule FermixCore.Setup.CoexistenceTest do
  @moduledoc """
  The three coexistence facts from M34 native setup §15.2. Every unit path and
  every reader is injected, so no case reads the operator's real LaunchAgents
  directory or their keychain.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Setup.Coexistence
  alias FermixCore.Setup.SecretAclState
  alias FermixCore.Setup.SecretWriter
  alias FermixTestSupport.SafeRm

  @unit """
  <?xml version="1.0" encoding="UTF-8"?>
  <plist version="1.0"><dict>
  <key>Label</key><string>io.tezra.fermix</string>
  <key>ProgramArguments</key><array><string>%PROGRAM%</string><string>run</string></array>
  </dict></plist>
  """

  setup do
    dir = SafeRm.make_tmp_dir!("coexistence")
    on_exit(fn -> SafeRm.rm_rf!(dir) end)
    %{dir: dir}
  end

  describe "legacy_service_unit" do
    test "absent when neither scope has a unit", %{dir: dir} do
      assert Coexistence.legacy_service_unit(unit_opts(dir)) ==
               %{present: false, scope: nil, path: nil}
    end

    test "present at user scope when the program is not inside this bundle", %{dir: dir} do
      path = write_unit(dir, "user.plist", "/opt/homebrew/bin/fermix")

      assert %{present: true, scope: :user, path: ^path} =
               Coexistence.legacy_service_unit(unit_opts(dir, user: "user.plist"))
    end

    # The scope is on the wire because removing a system unit needs
    # administrator rights, so it has its own sentence and its own action;
    # neither front-end can choose between them from a bare boolean.
    test "reports system scope distinctly", %{dir: dir} do
      path = write_unit(dir, "system.plist", "/opt/homebrew/bin/fermix")

      assert %{present: true, scope: :system, path: ^path} =
               Coexistence.legacy_service_unit(unit_opts(dir, system: "system.plist"))
    end

    test "the user scope is reported first when both exist", %{dir: dir} do
      write_unit(dir, "user.plist", "/opt/homebrew/bin/fermix")
      write_unit(dir, "system.plist", "/opt/homebrew/bin/fermix")

      assert %{scope: :user} =
               Coexistence.legacy_service_unit(
                 unit_opts(dir, user: "user.plist", system: "system.plist")
               )
    end

    # A unit whose program is inside the running bundle is this engine's own
    # and is not a coexistence fact at all.
    test "a unit this bundle owns is not reported", %{dir: dir} do
      write_unit(dir, "user.plist", "/Applications/Fermix.app/Contents/MacOS/fermix")

      opts =
        dir
        |> unit_opts(user: "user.plist")
        |> Keyword.put(:bundle_dir, "/Applications/Fermix.app")

      assert %{present: false} = Coexistence.legacy_service_unit(opts)
    end

    # A unit with no readable program is one this bundle did not write and
    # cannot account for, which is exactly what the row exists to name.
    test "a unit with no ProgramArguments is still reported", %{dir: dir} do
      path = Path.join(dir, "user.plist")
      File.write!(path, "<plist><dict></dict></plist>")

      assert %{present: true} =
               Coexistence.legacy_service_unit(unit_opts(dir, user: "user.plist"))
    end
  end

  describe "secret_acl_restricted" do
    setup do
      # A private recorder, so a measurement taken here never lands in the
      # tree-wide one every other module reads.
      name = :"acl_#{System.unique_integer([:positive])}"
      start_supervised!({SecretAclState, name: name})
      %{state: name}
    end

    test "reports nothing when no path holds the keyring sentinel", %{state: state} do
      opts = [
        snapshot: %{},
        secret_acl_state: state,
        secret_writer_available?: fn _opts -> true end,
        secret_reader: fn _key, _opts -> {:error, :unavailable} end
      ]

      assert Coexistence.secret_acl_restricted(opts) == %{present: false, keys: []}
    end

    test "names the keys the reader refuses", %{state: state} do
      opts = [
        snapshot: sentinel_snapshot(),
        secret_acl_state: state,
        secret_writer_available?: fn _opts -> true end,
        secret_reader: fn :openai_api_key, _opts -> {:error, :timeout} end
      ]

      assert %{present: true, keys: ["openai_api_key"]} = Coexistence.secret_acl_restricted(opts)
    end

    test "a readable key is not restricted", %{state: state} do
      opts = [
        snapshot: sentinel_snapshot(),
        secret_acl_state: state,
        secret_writer_available?: fn _opts -> true end,
        secret_reader: fn _key, _opts -> {:ok, "sk-live"} end
      ]

      assert Coexistence.secret_acl_restricted(opts) == %{present: false, keys: []}
    end

    # "There is no keychain on this host" is not "the ACL refuses". Reporting
    # every key as restricted on a writer-less host would put a security row in
    # front of every Linux operator with nothing they could do about it.
    test "a host with no writer reports nothing rather than everything", %{state: state} do
      opts = [
        snapshot: sentinel_snapshot(),
        secret_acl_state: state,
        secret_writer_available?: fn _opts -> false end,
        secret_reader: fn _key, _opts -> {:error, :unavailable} end
      ]

      assert Coexistence.secret_acl_restricted(opts) == %{present: false, keys: []}
    end
  end

  # Measuring prompts, so only Doctor measures and everything else reads the
  # record. "Not measured" is published as its own value, never as "nothing
  # restricted".
  describe "last_secret_acl_restricted" do
    setup do
      name = :"acl_last_#{System.unique_integer([:positive])}"
      start_supervised!({SecretAclState, name: name})
      %{state: name}
    end

    test "is not measured before a measurement", %{state: state} do
      assert Coexistence.last_secret_acl_restricted(secret_acl_state: state) ==
               %{present: nil, keys: []}
    end

    test "is the last measurement after one", %{state: state} do
      opts = [
        snapshot: sentinel_snapshot(),
        secret_acl_state: state,
        secret_writer_available?: fn _opts -> true end,
        secret_reader: fn :openai_api_key, _opts -> {:error, :timeout} end
      ]

      assert %{present: true} = Coexistence.secret_acl_restricted(opts)

      assert Coexistence.last_secret_acl_restricted(secret_acl_state: state) ==
               %{present: true, keys: ["openai_api_key"]}
    end

    test "answers not measured with no recorder running" do
      assert Coexistence.last_secret_acl_restricted(secret_acl_state: :no_such_acl_recorder) ==
               %{present: nil, keys: []}
    end
  end

  test "every config state has exactly one public word" do
    assert Coexistence.config_state_word(:clear) == "clear"
    assert Coexistence.config_state_word({:external_change, ["providers"]}) == "external_change"
    assert Coexistence.config_state_word({:config_unreadable, "bad"}) == "config_unreadable"
  end

  defp sentinel_snapshot do
    %{
      fermix_core: [
        providers: [openai: [api_key: SecretWriter.sentinel()]]
      ]
    }
  end

  defp unit_opts(dir, names \\ []) do
    [
      user_unit_path: Path.join(dir, Keyword.get(names, :user, "absent-user.plist")),
      system_unit_path: Path.join(dir, Keyword.get(names, :system, "absent-system.plist"))
    ]
  end

  defp write_unit(dir, name, program) do
    path = Path.join(dir, name)
    File.write!(path, String.replace(@unit, "%PROGRAM%", program))
    path
  end
end
