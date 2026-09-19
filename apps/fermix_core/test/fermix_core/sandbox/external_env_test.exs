defmodule FermixCore.Sandbox.ExternalEnvTest do
  @moduledoc """
  The one place M45 §4.1 validation and the §4.2 managed predicate live.

  Every rule here is a refusal a management call answers before any keychain
  I/O, so the cases are the rule's edges rather than a representative sample.
  """

  use ExUnit.Case, async: false

  alias FermixCore.Sandbox.Config
  alias FermixCore.Sandbox.ExternalEnv
  alias FermixCore.Setup.SecretWriter
  alias FermixTestSupport.SecretWriterStub

  # The predicate reads the active writer and profile, so both are established
  # here rather than inherited from whatever an earlier module left behind.
  setup do
    writer = Application.get_env(:fermix_core, :secret_writer)
    profile = Application.get_env(:fermix_core, :profile)

    Application.put_env(:fermix_core, :secret_writer, SecretWriterStub)
    Application.delete_env(:fermix_core, :profile)

    on_exit(fn ->
      restore(:secret_writer, writer)
      restore(:profile, profile)
    end)

    :ok
  end

  describe "validate_name/1" do
    test "accepts a name a POSIX shell can export" do
      for name <- ["ALPACA_API_KEY", "_PRIVATE", "a", "x1", String.duplicate("A", 128)] do
        assert ExternalEnv.validate_name(name) == :ok, name
      end
    end

    test "refuses what the pattern does not match, exactly and case-sensitively" do
      for name <- ["", "1ABC", "MY-VAR", "MY VAR", "NAME=1", "ÄPFEL", String.duplicate("A", 129)] do
        assert ExternalEnv.validate_name(name) == {:error, :invalid_name}, inspect(name)
      end
    end

    test "refuses a name Fermix sets itself, and only the exact spelling" do
      for name <- ~w(PATH HOME USER LANG SHELL TMPDIR FERMIX_HOME LC_ALL LC_CTYPE LC_) do
        assert ExternalEnv.validate_name(name) == {:error, :reserved_name}, name
      end

      for name <- ~w(path Home PATHS MY_HOME lc_all XLC_ALL) do
        assert ExternalEnv.validate_name(name) == :ok, name
      end
    end
  end

  describe "validate_value/1" do
    test "accepts one line from one byte up to the ceiling" do
      assert ExternalEnv.validate_value("x") == :ok
      assert ExternalEnv.validate_value(String.duplicate("x", 8_192)) == :ok
    end

    test "refuses an empty value and one above the ceiling" do
      assert ExternalEnv.validate_value("") == {:error, :empty_value}

      assert ExternalEnv.validate_value(String.duplicate("x", 8_193)) ==
               {:error, :value_too_large}
    end

    # The command-source reader refuses multi-line output, so a value that
    # carries a line break would store fine and never read back.
    test "refuses a line break or a NUL anywhere in the value" do
      for value <- ["a\nb", "a\rb", "a\0b", "trailing\n", "\r"] do
        assert ExternalEnv.validate_value(value) == {:error, :value_not_single_line},
               inspect(value)
      end
    end
  end

  describe "managed?/3 and source_kind/3" do
    test "a source equal to the writer's own lookup is managed" do
      env = env_with(%{"ALPACA_API_KEY" => ExternalEnv.managed_source("ALPACA_API_KEY")})

      assert ExternalEnv.source_kind(env, "ALPACA_API_KEY") == :managed
      assert ExternalEnv.managed?(env.sources["ALPACA_API_KEY"], "ALPACA_API_KEY")
    end

    test "the writer's lookup for another name is a helper, not this name's reference" do
      env = env_with(%{"ALPACA_API_KEY" => ExternalEnv.managed_source("OTHER_KEY")})

      assert ExternalEnv.source_kind(env, "ALPACA_API_KEY") == :helper
    end

    # A provider key the wizard linked reads a registry item, which is a
    # different keychain item from the skill's own, so it is never managed here.
    test "a provider key the wizard linked is a helper" do
      provider = SecretWriter.command_source(:openai_api_key)
      env = env_with(%{"OPENAI_API_KEY" => provider})

      assert ExternalEnv.source_kind(env, "OPENAI_API_KEY") == :helper
    end

    test "no entry, or an env entry under its own name, is the engine's environment" do
      assert ExternalEnv.source_kind(env_with(%{}), "X_KEY") == :engine_env

      env = env_with(%{"X_KEY" => %{source: :env}, "Y_KEY" => %{source: :env, name: "Y_KEY"}})
      assert ExternalEnv.source_kind(env, "X_KEY") == :engine_env
      assert ExternalEnv.source_kind(env, "Y_KEY") == :engine_env
    end

    test "an env entry under another name is an alias" do
      env = env_with(%{"X_KEY" => %{source: :env, name: "OTHER"}})

      assert ExternalEnv.source_kind(env, "X_KEY") == :alias
    end

    # Managed is "the value comes from the writer's lookup", so the timeout an
    # operator tuned for a slow keychain does not turn the entry into a helper.
    test "a managed entry with a tuned timeout is still managed" do
      source = %{ExternalEnv.managed_source("X_KEY") | timeout_ms: 9_000}

      assert ExternalEnv.source_kind(env_with(%{"X_KEY" => source}), "X_KEY") == :managed
    end

    test "the predicate is scoped to the active profile" do
      source = ExternalEnv.managed_source("X_KEY", profile: "work")
      env = env_with(%{"X_KEY" => source})

      assert ExternalEnv.source_kind(env, "X_KEY", profile: "work") == :managed
      assert ExternalEnv.source_kind(env, "X_KEY") == :helper
    end

    # An operator may point any name at a helper, including one Fermix would
    # never store. That entry is a helper, and asking must not raise: the rows
    # of the whole sandbox pane are built from this answer.
    test "a command source under a name Fermix cannot store is a helper" do
      helper = %{source: :command, command: "/usr/local/bin/helper"}
      env = env_with(%{"PATH" => helper, "MY-VAR" => helper}, ["PATH", "MY-VAR"])

      assert ExternalEnv.source_kind(env, "PATH") == :helper
      assert ExternalEnv.source_kind(env, "MY-VAR") == :helper
      assert ExternalEnv.managed_names(env) == []
    end

    test "a writer-less host manages nothing, even an empty command entry" do
      Application.put_env(:fermix_core, :secret_writer, FermixTestSupport.UnavailableSecretWriter)
      env = env_with(%{"X_KEY" => %{source: :command, args: []}})

      assert ExternalEnv.source_kind(env, "X_KEY") == :helper
      assert ExternalEnv.managed_names(env) == []
    end

    test "managed_names lists every managed entry, sorted, allowed or not" do
      env =
        env_with(
          %{
            "ZED_KEY" => ExternalEnv.managed_source("ZED_KEY"),
            "ALPHA_KEY" => ExternalEnv.managed_source("ALPHA_KEY"),
            "HELPER_KEY" => %{source: :command, command: "/usr/local/bin/helper"}
          },
          ["ZED_KEY"]
        )

      assert ExternalEnv.managed_names(env) == ["ALPHA_KEY", "ZED_KEY"]
    end
  end

  describe "the config transforms" do
    test "put_managed allows the name, removes it from deny and writes the reference" do
      env = env_with(%{}, ["FIRST"], ["X_KEY", "OTHER"])

      updated = ExternalEnv.put_managed(env, "X_KEY")

      assert updated.allow == ["FIRST", "X_KEY"]
      assert updated.deny == ["OTHER"]
      assert ExternalEnv.source_kind(updated, "X_KEY") == :managed
    end

    test "put_managed keeps an existing allow position" do
      env = env_with(%{}, ["X_KEY", "LAST"])

      assert ExternalEnv.put_managed(env, "X_KEY").allow == ["X_KEY", "LAST"]
    end

    test "drop_managed drops a managed reference and keeps the name allowed" do
      env = ExternalEnv.put_managed(env_with(%{}, []), "X_KEY")

      updated = ExternalEnv.drop_managed(env, "X_KEY")

      assert updated.allow == ["X_KEY"]
      refute Map.has_key?(updated.sources, "X_KEY")
      assert ExternalEnv.source_kind(updated, "X_KEY") == :engine_env
    end

    test "drop_managed never touches a source that is not managed" do
      helper = %{source: :command, command: "/usr/local/bin/helper"}
      env = env_with(%{"X_KEY" => helper, "Y_KEY" => %{source: :env, name: "Z"}}, ["X_KEY"])

      assert ExternalEnv.drop_managed(env, "X_KEY") == env
      assert ExternalEnv.drop_managed(env, "Y_KEY") == env
    end
  end

  test "the managed-entry ceiling is the published one" do
    assert ExternalEnv.max_managed() == 64
  end

  defp env_with(sources, allow \\ [], deny \\ []) do
    Config.normalize(env: [allow: allow, deny: deny, sources: sources]).env
  end

  defp restore(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore(key, value), do: Application.put_env(:fermix_core, key, value)
end
