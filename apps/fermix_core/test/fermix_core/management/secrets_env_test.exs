defmodule FermixCore.Management.SecretsEnvTest do
  @moduledoc """
  `secret.set` and `secret.clear` for the `env:<NAME>` family (M45 §4.3).

  A skill's credential is an ordinary allowed name whose source is the
  writer's own lookup. The properties worth proving are the ones a wrong
  implementation gets silently wrong: the value is verified before the
  settings file points at it, a failed commit does not orphan a new item, an
  operator's helper or alias is never rewritten, a provider's key of the same
  variable name is never touched, and storing a key asks for no restart.

  Every writer here is the stub or a thin wrapper around it: no case reaches
  the real keychain, and every case runs against its own home.
  """

  use ExUnit.Case, async: false

  alias FermixCore.Management.Secrets
  alias FermixCore.Sandbox.Config, as: SandboxConfig
  alias FermixCore.Sandbox.Env, as: SandboxEnv
  alias FermixCore.Sandbox.ExternalEnv
  alias FermixCore.Setup.RestartState
  alias FermixCore.Setup.SecretWriter
  alias FermixCore.Setup.Wizard
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.SecretWriterStub
  alias FermixTestSupport.UnavailableSecretWriter

  # The stub, with every storage call reported to the calling process. The
  # management call runs in the test process, so `self()` is the observer.
  defmodule RecordingWriter do
    @moduledoc false
    @behaviour FermixCore.Setup.SecretWriter

    alias FermixTestSupport.SecretWriterStub

    @impl true
    def available?(opts \\ []), do: SecretWriterStub.available?(opts)

    @impl true
    def probe(opts \\ []), do: SecretWriterStub.probe(opts)

    @impl true
    def put(key, value, opts \\ []) do
      send(self(), {:writer, :put, key})
      SecretWriterStub.put(key, value, opts)
    end

    @impl true
    def get(key, opts \\ []) do
      send(self(), {:writer, :get, key})
      SecretWriterStub.get(key, opts)
    end

    @impl true
    def delete(key, opts \\ []) do
      send(self(), {:writer, :delete, key})
      SecretWriterStub.delete(key, opts)
    end

    @impl true
    def command_source(key, opts \\ []), do: SecretWriterStub.command_source(key, opts)
  end

  # Stores fine, reads back something else: a keychain that silently kept an
  # older value, or a helper that transformed it.
  defmodule MismatchWriter do
    @moduledoc false
    @behaviour FermixCore.Setup.SecretWriter

    alias FermixCore.Management.SecretsEnvTest.RecordingWriter

    @impl true
    def get(key, opts \\ [])

    def get({:external_env, _name} = key, _opts) do
      send(self(), {:writer, :get, key})
      {:ok, "a-different-value"}
    end

    def get(key, opts), do: RecordingWriter.get(key, opts)

    @impl true
    defdelegate available?(opts \\ []), to: RecordingWriter
    @impl true
    defdelegate probe(opts \\ []), to: RecordingWriter
    @impl true
    defdelegate put(key, value, opts \\ []), to: RecordingWriter
    @impl true
    defdelegate delete(key, opts \\ []), to: RecordingWriter
    @impl true
    defdelegate command_source(key, opts \\ []), to: RecordingWriter
  end

  # Stores fine, then cannot read it back: a keychain that locked in between.
  defmodule UnreadableWriter do
    @moduledoc false
    @behaviour FermixCore.Setup.SecretWriter

    alias FermixCore.Management.SecretsEnvTest.RecordingWriter

    @impl true
    def get(key, opts \\ [])

    def get({:external_env, _name} = key, _opts) do
      send(self(), {:writer, :get, key})
      {:error, {:helper_failed, "/usr/bin/security", 51, "User interaction is not allowed."}}
    end

    def get(key, opts), do: RecordingWriter.get(key, opts)

    @impl true
    defdelegate available?(opts \\ []), to: RecordingWriter
    @impl true
    defdelegate probe(opts \\ []), to: RecordingWriter
    @impl true
    defdelegate put(key, value, opts \\ []), to: RecordingWriter
    @impl true
    defdelegate delete(key, opts \\ []), to: RecordingWriter
    @impl true
    defdelegate command_source(key, opts \\ []), to: RecordingWriter
  end

  # A delete the keychain refuses: the reference must survive it.
  defmodule LockedDeleteWriter do
    @moduledoc false
    @behaviour FermixCore.Setup.SecretWriter

    alias FermixCore.Management.SecretsEnvTest.RecordingWriter

    @impl true
    def delete(key, opts \\ [])

    def delete({:external_env, _name} = key, _opts) do
      send(self(), {:writer, :delete, key})
      {:error, {:helper_failed, "/usr/bin/security", 51, "The keychain is locked."}}
    end

    def delete(key, opts), do: RecordingWriter.delete(key, opts)

    @impl true
    defdelegate available?(opts \\ []), to: RecordingWriter
    @impl true
    defdelegate probe(opts \\ []), to: RecordingWriter
    @impl true
    defdelegate put(key, value, opts \\ []), to: RecordingWriter
    @impl true
    defdelegate get(key, opts \\ []), to: RecordingWriter
    @impl true
    defdelegate command_source(key, opts \\ []), to: RecordingWriter
  end

  # A keychain stand-in whose lookup is a real command, so the resolver the
  # shell tool reads on every call can run it and hand back the stored value.
  # Items are files under the case's own tmp dir, which the test process names.
  defmodule FileBackedWriter do
    @moduledoc false
    @behaviour FermixCore.Setup.SecretWriter

    alias FermixTestSupport.SafeRm

    @impl true
    def available?(_opts \\ []), do: true

    # A probe reads nothing; this double stands in for a store that answers.
    @impl true
    def probe(opts \\ []),
      do: %{store: Keyword.get(opts, :store, :keyring), state: :available, sentence: "double"}

    @impl true
    def put(key, value, opts \\ []) do
      File.write!(path(key, opts), value)
    end

    @impl true
    def get(key, opts \\ []) do
      case File.read(path(key, opts)) do
        {:ok, value} -> {:ok, value}
        {:error, :enoent} -> {:error, :missing_secret}
      end
    end

    @impl true
    def delete(key, opts \\ []), do: SafeRm.rm(path(key, opts))

    @impl true
    def command_source(key, opts \\ []) do
      %{source: :command, command: "cat", args: [path(key, opts)], timeout_ms: 3_000}
    end

    defp path({:external_env, name}, opts),
      do: Path.join(Process.get(__MODULE__), "#{SecretWriter.scoped_prefix(opts)}-#{name}")

    defp path(key, opts) when is_atom(key),
      do: Path.join(Process.get(__MODULE__), "#{SecretWriter.scoped_prefix(opts)}-#{key}")
  end

  @core_keys [:providers, :sandbox, :secret_writer, :profile, :plugin_secrets, :oauth]
  @value "alpaca-live-secret-0123"

  setup do
    home = System.get_env("FERMIX_HOME")
    core = Map.new(@core_keys, fn key -> {key, Application.get_env(:fermix_core, key)} end)
    telegram = Application.get_env(:fermix_channels, :telegram)

    Application.put_env(:fermix_core, :secret_writer, RecordingWriter)
    Application.delete_env(:fermix_core, :profile)
    # Only the environment policy is reset: the rest of the section stays what
    # the tree booted with, so a reason about it can only come from this case.
    put_env_policy([])
    SecretWriterStub.reset()

    tmp = SafeRm.make_tmp_dir!("management_secrets_env_home")
    System.put_env("FERMIX_HOME", tmp)
    :ok = RestartState.record_persisted_baseline()

    on_exit(fn ->
      Enum.each(core, fn {key, value} -> restore(:fermix_core, key, value) end)
      restore(:fermix_channels, :telegram, telegram)
      SecretWriterStub.reset()

      case home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      SafeRm.rm_rf!(tmp)
      :ok = RestartState.record_persisted_baseline()
    end)

    %{home: tmp}
  end

  describe "storing a value (S1)" do
    test "stores, verifies, then allows and references the name", %{home: home} do
      put_env_policy(deny: ["ALPACA_API_KEY", "OTHER"])

      assert {:ok, view} = Secrets.set("env:ALPACA_API_KEY", @value)

      assert view["id"] == "env:ALPACA_API_KEY"
      assert view["present"] == true
      assert Map.keys(view) |> Enum.sort() == ~w(id present restart)

      assert_received {:writer, :put, {:external_env, "ALPACA_API_KEY"}}
      assert_received {:writer, :get, {:external_env, "ALPACA_API_KEY"}}
      assert SecretWriter.get({:external_env, "ALPACA_API_KEY"}) == {:ok, @value}

      live = SandboxConfig.current()
      assert live.env.allow == ["ALPACA_API_KEY"]
      assert live.env.deny == ["OTHER"]
      assert ExternalEnv.source_kind(live.env, "ALPACA_API_KEY") == :managed

      persisted = File.read!(Path.join(home, "config.toml"))
      assert persisted =~ "[sandbox.env.ALPACA_API_KEY]"
      refute persisted =~ @value
    end

    # A restart state that started just before the write, so every reason it
    # reports was caused by this write and nothing earlier in the suite. The
    # tree's own state is not the operand: the rest of the suite leaves boot-bound
    # sections, the sandbox's included, differing from what the tree booted with.
    test "a restart state captured before the write reports nothing after it" do
      server = start_restart_state()

      assert {:ok, _view} = Secrets.set("env:ALPACA_API_KEY", @value)
      # The daemon's own save re-records the tree's baseline; this one mirrors it.
      :ok = RestartState.record_persisted_baseline(server: server)

      assert RestartState.restart(server: server) == %{required: false, reasons: []}
    end

    test "a replacement keeps one allow entry and stays managed" do
      assert {:ok, _first} = Secrets.set("env:ALPACA_API_KEY", @value)
      assert {:ok, %{"present" => true}} = Secrets.set("env:ALPACA_API_KEY", "rotated-value-99")

      assert SecretWriter.get({:external_env, "ALPACA_API_KEY"}) == {:ok, "rotated-value-99"}
      assert SandboxConfig.current().env.allow == ["ALPACA_API_KEY"]
    end

    # The live path the shell tool reads on every call: the config just applied,
    # resolved by the same builder a command's environment comes from.
    test "the environment built for the next command carries the value", %{home: home} do
      Process.put(FileBackedWriter, home)
      Application.put_env(:fermix_core, :secret_writer, FileBackedWriter)

      assert {:ok, _view} = Secrets.set("env:ALPACA_API_KEY", @value)

      assert {:ok, %{env: env}} = SandboxEnv.build(SandboxConfig.current())
      assert {"ALPACA_API_KEY", @value} in env
    end
  end

  describe "refusals before any storage call (S2)" do
    test "a name the pattern refuses", %{home: home} do
      for name <- ["MY-VAR", "1ABC", "", String.duplicate("A", 129)] do
        assert {:error, {:invalid_params, "id", sentence}} = Secrets.set("env:" <> name, @value)

        assert sentence ==
                 "A variable name is letters, digits and underscores, " <>
                   "does not start with a digit, and is at most 128 characters."
      end

      assert_nothing_happened(home)
    end

    test "a name Fermix sets itself", %{home: home} do
      for name <- ~w(PATH HOME FERMIX_HOME LC_ALL) do
        assert {:error, {:invalid_params, "id", sentence}} = Secrets.set("env:" <> name, @value)
        assert sentence == "Fermix sets this variable itself, so it cannot be stored."
      end

      assert_nothing_happened(home)
    end

    test "an empty value, one above the ceiling, and one that is not a single line", %{
      home: home
    } do
      assert {:error, {:invalid_params, "value", "A secret cannot be empty."}} =
               Secrets.set("env:X_KEY", "")

      assert {:error, {:invalid_params, "value", "A secret is at most 8192 bytes."}} =
               Secrets.set("env:X_KEY", String.duplicate("x", 8_193))

      for value <- ["line\nbreak", "carriage\rreturn", "nul\0byte"] do
        assert {:error, {:invalid_params, "value", sentence}} = Secrets.set("env:X_KEY", value)
        assert sentence == "A stored variable is one line with no null characters."
      end

      assert_nothing_happened(home)
    end

    test "a sixty-fifth stored name", %{home: home} do
      names = for n <- 1..64, do: "STORED_#{n}"
      put_env_policy(sources: Map.new(names, &{&1, ExternalEnv.managed_source(&1)}))
      before = SandboxConfig.current()

      assert {:error, {:invalid_params, "id", sentence}} = Secrets.set("env:ONE_MORE", @value)
      assert sentence == "At most 64 variables can be stored. Remove one first."

      assert_nothing_happened(home)
      assert SandboxConfig.current() == before
    end

    # Replacing a value already stored adds no entry, so the ceiling is no
    # reason to refuse it.
    test "a replacement at the ceiling is not a new entry" do
      names = for n <- 1..64, do: "STORED_#{n}"
      put_env_policy(sources: Map.new(names, &{&1, ExternalEnv.managed_source(&1)}))

      assert {:ok, %{"present" => true}} = Secrets.set("env:STORED_7", @value)
    end
  end

  describe "a name whose value comes from elsewhere (S3)" do
    test "a helper command is refused and nothing changes", %{home: home} do
      helper = %{source: :command, command: "/usr/local/bin/op", args: ["read", "x"]}
      put_env_policy(allow: ["ALPACA_API_KEY"], sources: %{"ALPACA_API_KEY" => helper})
      before = SandboxConfig.current()

      assert {:error, {:invalid_params, "id", sentence}} =
               Secrets.set("env:ALPACA_API_KEY", @value)

      assert sentence ==
               "This variable is read from a helper command or another variable. " <>
                 "Change that in the settings file first."

      assert_nothing_happened(home)
      assert SandboxConfig.current() == before
    end

    test "an alias is refused and nothing changes", %{home: home} do
      alias_source = %{source: :env, name: "OLD_ALPACA_KEY"}
      put_env_policy(allow: ["ALPACA_API_KEY"], sources: %{"ALPACA_API_KEY" => alias_source})
      before = SandboxConfig.current()

      assert {:error, {:invalid_params, "id", _sentence}} =
               Secrets.set("env:ALPACA_API_KEY", @value)

      assert_nothing_happened(home)
      assert SandboxConfig.current() == before
    end
  end

  describe "no OS secret store (S4)" do
    test "answers unavailable and changes nothing", %{home: home} do
      Application.put_env(:fermix_core, :secret_writer, UnavailableSecretWriter)

      assert {:error, {:secret_store_failed, "env:ALPACA_API_KEY", "unavailable"}} =
               Secrets.set("env:ALPACA_API_KEY", @value)

      assert SandboxConfig.current().env.allow == []
      refute File.exists?(Path.join(home, "config.toml"))
    end
  end

  describe "a locked keyring (M38 §7.2)" do
    test "a cancelled unlock prompt answers locked, and nothing was written", %{home: home} do
      SecretWriterStub.set_verdict(%{
        store: :keyring,
        state: :locked,
        sentence: "the login keyring is locked"
      })

      on_exit(fn -> SecretWriterStub.clear_verdict(:keyring) end)

      assert {:error, {:secret_store_failed, "env:ALPACA_API_KEY", "locked"}} =
               Secrets.set("env:ALPACA_API_KEY", @value)

      SecretWriterStub.clear_verdict(:keyring)
      assert SecretWriterStub.get({:external_env, "ALPACA_API_KEY"}) == {:error, :missing_secret}
      assert SandboxConfig.current().env.allow == []
      refute File.exists?(Path.join(home, "config.toml"))
    end

    test "an answered unlock prompt stores the key, as it always did" do
      SecretWriterStub.set_verdict(
        %{store: :keyring, state: :locked, sentence: "the login keyring is locked"},
        unlock_on_prompt: true
      )

      on_exit(fn -> SecretWriterStub.clear_verdict(:keyring) end)

      assert {:ok, _view} = Secrets.set("env:ALPACA_API_KEY", @value)
      assert {:ok, @value} = SecretWriterStub.get({:external_env, "ALPACA_API_KEY"})
    end
  end

  describe "a write that does not verify or does not commit (S5)" do
    test "a read-back mismatch is an error, and the new item is deleted once" do
      Application.put_env(:fermix_core, :secret_writer, MismatchWriter)

      assert {:error, {:secret_store_failed, "env:ALPACA_API_KEY", reason}} =
               Secrets.set("env:ALPACA_API_KEY", @value)

      assert reason in ~w(unavailable locked timeout)
      assert deletes_of("ALPACA_API_KEY") == 1
      assert SecretWriterStub.get({:external_env, "ALPACA_API_KEY"}) == {:error, :missing_secret}
      assert SandboxConfig.current().env.allow == []
    end

    test "a read-back failure is an error, and the new item is deleted once" do
      Application.put_env(:fermix_core, :secret_writer, UnreadableWriter)

      assert {:error, {:secret_store_failed, "env:ALPACA_API_KEY", "locked"}} =
               Secrets.set("env:ALPACA_API_KEY", @value)

      assert deletes_of("ALPACA_API_KEY") == 1
      assert SandboxConfig.current().env.allow == []
    end

    test "no failure sentence or reason carries the value" do
      Application.put_env(:fermix_core, :secret_writer, MismatchWriter)

      assert {:error, error} = Secrets.set("env:ALPACA_API_KEY", @value)
      refute inspect(error) =~ @value
      refute inspect(error) =~ "a-different-value"
    end

    test "a refused commit deletes an item this call created, then returns the refusal", %{
      home: home
    } do
      write_outside_edit(home)

      assert {:error, {:external_change, _sections}} = Secrets.set("env:ALPACA_API_KEY", @value)

      assert deletes_of("ALPACA_API_KEY") == 1
      assert SecretWriterStub.get({:external_env, "ALPACA_API_KEY"}) == {:error, :missing_secret}
    end

    # The entry already points at the item, so deleting it would leave a
    # reference to nothing.
    # Seeded rather than stored through `set/2`: a write re-records the tree's
    # restart state, whose one-second read cache would then hide the outside
    # edit this case depends on.
    test "a refused commit keeps an item the settings file already points at", %{home: home} do
      :ok = SecretWriterStub.put({:external_env, "ALPACA_API_KEY"}, @value)

      put_env_policy(
        allow: ["ALPACA_API_KEY"],
        sources: %{"ALPACA_API_KEY" => ExternalEnv.managed_source("ALPACA_API_KEY")}
      )

      write_outside_edit(home)

      assert {:error, {:external_change, _sections}} =
               Secrets.set("env:ALPACA_API_KEY", "rotated-value-99")

      assert deletes_of("ALPACA_API_KEY") == 0
      assert {:ok, _kept} = SecretWriterStub.get({:external_env, "ALPACA_API_KEY"})
      assert ExternalEnv.source_kind(SandboxConfig.current().env, "ALPACA_API_KEY") == :managed
    end
  end

  describe "forgetting a value (S6)" do
    test "deletes the item, then drops the reference, and the name stays allowed" do
      assert {:ok, _stored} = Secrets.set("env:ALPACA_API_KEY", @value)
      flush_writer_calls()

      assert {:ok, view} = Secrets.clear("env:ALPACA_API_KEY")

      assert view["id"] == "env:ALPACA_API_KEY"
      assert view["present"] == false
      assert deletes_of("ALPACA_API_KEY") == 1
      assert SecretWriterStub.get({:external_env, "ALPACA_API_KEY"}) == {:error, :missing_secret}

      live = SandboxConfig.current()
      assert live.env.allow == ["ALPACA_API_KEY"]
      assert ExternalEnv.source_kind(live.env, "ALPACA_API_KEY") == :engine_env
    end

    test "a delete the keychain refuses keeps the reference and changes nothing" do
      assert {:ok, _stored} = Secrets.set("env:ALPACA_API_KEY", @value)
      Application.put_env(:fermix_core, :secret_writer, LockedDeleteWriter)
      before = SandboxConfig.current()

      assert {:error, {:secret_store_failed, "env:ALPACA_API_KEY", "locked"}} =
               Secrets.clear("env:ALPACA_API_KEY")

      assert SandboxConfig.current() == before
      assert ExternalEnv.source_kind(before.env, "ALPACA_API_KEY") == :managed
    end

    test "forgetting a name never stored succeeds" do
      assert {:ok, %{"present" => false}} = Secrets.clear("env:NEVER_STORED")
    end

    test "a helper source is never touched, though its item is still forgotten" do
      helper = %{source: :command, command: "/usr/local/bin/op", args: ["read", "x"]}
      put_env_policy(allow: ["ALPACA_API_KEY"], sources: %{"ALPACA_API_KEY" => helper})
      before = SandboxConfig.current()

      assert {:ok, %{"present" => false}} = Secrets.clear("env:ALPACA_API_KEY")

      assert deletes_of("ALPACA_API_KEY") == 1
      assert SandboxConfig.current() == before
    end

    test "a name that fails validation is refused before any storage call", %{home: home} do
      assert {:error, {:invalid_params, "id", _sentence}} = Secrets.clear("env:MY-VAR")
      assert_nothing_happened(home)
    end

    test "a stored name no longer allowed is still forgettable" do
      assert {:ok, _stored} = Secrets.set("env:ALPACA_API_KEY", @value)
      assert {:ok, _report} = Wizard.set_sandbox_overrides(nil, nil, [])
      assert ExternalEnv.managed_names(SandboxConfig.current().env) == ["ALPACA_API_KEY"]

      assert {:ok, %{"present" => false}} = Secrets.clear("env:ALPACA_API_KEY")

      assert ExternalEnv.managed_names(SandboxConfig.current().env) == []
      assert SandboxConfig.current().env.allow == []
    end
  end

  describe "a skill key named like a provider key (S7)" do
    test "storing and clearing it never touches the provider's registry item" do
      assert {:ok, _provider} = Secrets.set("openai_api_key", "sk-provider-value")
      flush_writer_calls()

      assert {:ok, _skill} = Secrets.set("env:OPENAI_API_KEY", "sk-skill-value-0001")
      assert {:ok, _cleared} = Secrets.clear("env:OPENAI_API_KEY")

      refute_received {:writer, :put, :openai_api_key}
      refute_received {:writer, :delete, :openai_api_key}
      assert SecretWriter.get(:openai_api_key) == {:ok, "sk-provider-value"}

      provider = get_in(Application.get_env(:fermix_core, :providers), [:openai, :api_key])
      assert provider == "sk-provider-value"
    end
  end

  describe "a named profile (S8)" do
    test "stores under the profile and references the profile's own lookup" do
      Application.put_env(:fermix_core, :profile, "work")

      assert {:ok, %{"present" => true}} = Secrets.set("env:X_KEY", @value)
      assert SecretWriter.get({:external_env, "X_KEY"}) == {:ok, @value}

      # The stub files items by explicit `profile:` only; the per-profile keychain
      # address itself is pinned in `SecretWriterTest` for both real writers.
      source = SandboxConfig.current().env.sources["X_KEY"]
      assert source.args == ["fermix:work:external_env:X_KEY"]
      assert ExternalEnv.managed?(source, "X_KEY", profile: "work")
      refute ExternalEnv.managed?(source, "X_KEY", profile: "general")
    end
  end

  describe "the published contract" do
    # The fixtures illustrate what this family adds to the restart state, which
    # is nothing. The shared tree may have unrelated reasons standing from the
    # rest of the suite, and the shape of one reason is pinned by the registry
    # family's own case, so the list is compared empty.
    test "the set and clear fixtures for this family carry the shape the writer returns" do
      assert {:ok, stored} = Secrets.set("env:ALPACA_API_KEY", @value)
      assert shape(no_reasons(stored)) == shape(fixture_result("secret_set_external_env"))

      assert {:ok, cleared} = Secrets.clear("env:ALPACA_API_KEY")
      assert shape(no_reasons(cleared)) == shape(fixture_result("secret_clear_external_env"))
    end
  end

  defp no_reasons(view), do: put_in(view, ["restart", "reasons"], [])

  # Replaces the environment policy and keeps the rest of the section as it is.
  defp put_env_policy(env) do
    policy = SandboxConfig.normalize(env: env).env
    Application.put_env(:fermix_core, :sandbox, %{SandboxConfig.current() | env: policy})
  end

  # A settings file edited by something other than this daemon: the one state
  # in which every write refuses.
  defp write_outside_edit(home) do
    path = Path.join(home, "config.toml")
    existing = if File.exists?(path), do: File.read!(path), else: ""
    File.write!(path, existing <> "\n[fermix_core.memory]\nreview_interval_hours = 12\n")
  end

  # No storage call for any skill key, and no settings file written.
  defp assert_nothing_happened(home) do
    refute_received {:writer, _op, {:external_env, _name}}
    refute File.exists?(Path.join(home, "config.toml"))
  end

  defp deletes_of(name) do
    count_messages({:writer, :delete, {:external_env, name}}, 0)
  end

  defp count_messages(message, count) do
    receive do
      ^message -> count_messages(message, count + 1)
    after
      0 -> count
    end
  end

  defp flush_writer_calls do
    receive do
      {:writer, _op, _key} -> flush_writer_calls()
    after
      0 -> :ok
    end
  end

  defp start_restart_state do
    name = :"secrets_env_restart_#{System.unique_integer([:positive, :monotonic])}"
    start_supervised!({RestartState, name: name, cache_ttl_ms: 0}, id: name)
    name
  end

  defp fixture_result(name) do
    :fermix_core
    |> Application.app_dir("priv/management/fixtures/success.jsonl")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.find(&(&1["name"] == name))
    |> result_of(name)
  end

  defp result_of(nil, name), do: flunk("no success fixture named #{name}")
  defp result_of(record, _name), do: get_in(record, ["response", "result"])

  defp shape(value) when is_map(value), do: Map.new(value, fn {k, v} -> {k, shape(v)} end)
  defp shape([]), do: []
  defp shape([head | _rest]), do: [shape(head)]
  defp shape(_value), do: :scalar

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
