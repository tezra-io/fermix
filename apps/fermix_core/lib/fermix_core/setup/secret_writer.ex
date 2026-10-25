defmodule FermixCore.Setup.SecretWriter do
  @moduledoc """
  Facade for setup-managed secret storage.

  A key is one of four shapes. A registry atom names a `SecretPaths` entry and
  is stored under that entry's environment name. `{:external_env, name}` is a
  skill's own credential (M45 §4.1), stored under `external_env:<NAME>` so it
  can never share an item with a provider key of the same variable name. The
  name never becomes an atom, and it is validated by `Sandbox.ExternalEnv`
  before it becomes an address. `{:mcp, id}` is a value an operator MCP server
  declares (M74 E6), stored under its id, `mcp:<server>/env/<NAME>` and its
  siblings, which `Capabilities.MCP.Secrets` validates the same way.
  `{:cue_source, ref, field}` is one secret field of a cue source (M60 §6.2),
  stored under `cue_source:<ref>:<field>`; the ref is validated by
  `Cues.Config.valid_name?/1` and the field is one of `token`, `key`,
  `secret` or `path_secret` (a webhook URL's random part, M60 §6.5), so
  neither part can become an arbitrary address.

  There are two stores, and `config.toml` says which one a home writes to
  (`[fermix_core] secret_store`, default `keyring`) and which one each secret
  is in: a secret stored in the OS keyring is persisted as `@keyring`, one in
  the file store under the Fermix home as `@file`. Writes go to the configured
  store; reads go to the store the sentinel names. Nothing ever moves a secret
  between them on its own — `fermix setup --migrate-secrets` is the one mover.

  `probe/1` says whether the configured store can be used right now, before a
  write or a boot-time read tries it (M38 §7.2): a locked login keyring is a
  verdict, not a hung `secret-tool` and an unlock dialog nobody asked for.
  """

  alias FermixCore.Capabilities.MCP.Secrets, as: McpSecrets
  alias FermixCore.Cues.Config, as: CuesConfig
  alias FermixCore.Sandbox.ExternalEnv
  alias FermixCore.Setup.SecretPaths

  @sentinel "@keyring"
  @file_sentinel "@file"
  @sentinels [@sentinel, @file_sentinel]
  @stores [:keyring, :file]
  @default_profile "general"
  @compiled_env Mix.env()
  @external_prefix "external_env:"
  @cue_source_prefix "cue_source:"
  @cue_secret_fields [:token, :key, :secret, :path_secret]
  @type external_key :: {:external_env, String.t()}
  @type mcp_key :: {:mcp, String.t()}
  @type cue_source_key :: {:cue_source, String.t(), :token | :key | :secret | :path_secret}
  @type secret_key :: atom() | external_key() | mcp_key() | cue_source_key()
  @type writer_error :: {:error, term()}
  @type store :: :keyring | :file

  @typedoc """
  What a store can do right now. `:available` and `:unknown` let an operation
  proceed (the operation reports its own result); every other state refuses it
  with `sentence`, which is written for the operator and names the fix.
  """
  @type verdict_state ::
          :available
          | :tool_absent
          | :no_session_bus
          | :service_absent
          | :collection_unavailable
          | :locked
          | :unavailable
          | :unknown
  @type verdict :: %{
          required(:store) => store(),
          required(:state) => verdict_state(),
          required(:sentence) => String.t(),
          optional(:evidence) => String.t()
        }

  @doc "Whether `key` is one of the four key shapes every writer accepts."
  defguard is_secret_key(key)
           when is_atom(key) or
                  (is_tuple(key) and tuple_size(key) == 2 and
                     elem(key, 0) in [:external_env, :mcp] and is_binary(elem(key, 1))) or
                  (is_tuple(key) and tuple_size(key) == 3 and elem(key, 0) == :cue_source and
                     is_binary(elem(key, 1)) and
                     elem(key, 2) in [:token, :key, :secret, :path_secret])

  @doc "The secret fields a cue source may declare, in its `{:cue_source, ref, field}` key."
  @spec cue_secret_fields() :: [:token | :key | :secret | :path_secret]
  def cue_secret_fields, do: @cue_secret_fields

  @callback put(secret_key(), String.t(), keyword()) :: :ok | writer_error()
  @callback get(secret_key(), keyword()) :: {:ok, String.t()} | writer_error()
  @callback delete(secret_key(), keyword()) :: :ok | writer_error()
  @callback available?(keyword()) :: boolean()
  @callback probe(keyword()) :: verdict()
  @callback command_source(secret_key(), keyword()) :: map()

  @doc "The value `config.toml` holds for a secret that is in the OS keyring."
  @spec sentinel() :: String.t()
  def sentinel, do: @sentinel

  @doc "The value `config.toml` holds for a secret that is in the file store."
  @spec file_sentinel() :: String.t()
  def file_sentinel, do: @file_sentinel

  @doc "Every value that marks a secret as stored elsewhere than `config.toml`."
  @spec sentinels() :: [String.t()]
  def sentinels, do: @sentinels

  @spec sentinel?(term()) :: boolean()
  def sentinel?(value), do: value in @sentinels

  @spec sentinel_for(store()) :: String.t()
  def sentinel_for(:keyring), do: @sentinel
  def sentinel_for(:file), do: @file_sentinel

  @spec store_of_sentinel(term()) :: {:ok, store()} | :error
  def store_of_sentinel(@sentinel), do: {:ok, :keyring}
  def store_of_sentinel(@file_sentinel), do: {:ok, :file}
  def store_of_sentinel(_value), do: :error

  @doc "The sentinel a write made now would leave behind: the configured store's."
  @spec current_sentinel(keyword()) :: String.t()
  def current_sentinel(opts \\ []) when is_list(opts), do: sentinel_for(store(opts))

  @spec stores() :: [store()]
  def stores, do: @stores

  @doc """
  The store writes go to. `opts[:store]` wins (a snapshot being saved names
  its own), then the `:fermix_core, :secret_store` app-env setting that
  `config.toml` populates at load, then the keyring. Any other value is a
  programming error and raises: a secret must never land in a store nobody
  chose.
  """
  @spec store(keyword()) :: store()
  def store(opts \\ []) when is_list(opts) do
    case Keyword.get(opts, :store) || Application.get_env(:fermix_core, :secret_store, :keyring) do
      store when store in @stores ->
        store

      other ->
        raise ArgumentError, "secret store must be :keyring or :file, got: #{inspect(other)}"
    end
  end

  @doc "Parses the `[fermix_core] secret_store` value; anything unknown is refused by name."
  @spec parse_store(term()) :: {:ok, store()} | {:error, String.t()}
  def parse_store(value) when value in [nil, ""], do: {:ok, :keyring}
  def parse_store(store) when store in @stores, do: {:ok, store}
  def parse_store("keyring"), do: {:ok, :keyring}
  def parse_store("file"), do: {:ok, :file}

  def parse_store(other) do
    {:error,
     "[fermix_core] secret_store must be \"keyring\" or \"file\", and #{inspect(other)} is neither"}
  end

  @spec default_profile() :: String.t()
  def default_profile, do: @default_profile

  @doc """
  Keychain entry-name prefix for the active profile. The default profile
  (`"general"`, and the unconfigured case) uses the bare `fermix` prefix, so
  existing single-profile installs keep their legacy `fermix:<ENV>` entries
  with no migration. A named profile (e.g. `"work"`) gets `fermix:<profile>`,
  isolating its secrets from other profiles on the same machine.

  The profile comes from `opts[:profile]` — passed explicitly on the
  boot-resolve and save paths, where app env is not yet populated — or the
  `:fermix_core, :profile` app-env setting otherwise.
  """
  @spec scoped_prefix(keyword()) :: String.t()
  def scoped_prefix(opts \\ []) when is_list(opts) do
    case Keyword.get(opts, :profile) || Application.get_env(:fermix_core, :profile) do
      profile when profile in [nil, "", @default_profile] ->
        "fermix"

      profile when is_binary(profile) ->
        "fermix:#{profile}"

      other ->
        raise ArgumentError, "[fermix_core] profile must be a string, got: #{inspect(other)}"
    end
  end

  @spec put(secret_key(), String.t(), keyword()) :: :ok | writer_error()
  def put(key, value, opts \\ []) when is_secret_key(key) and is_binary(value) do
    impl(opts).put(key, value, opts)
  end

  @spec get(secret_key(), keyword()) :: {:ok, String.t()} | writer_error()
  def get(key, opts \\ []) when is_secret_key(key), do: impl(opts).get(key, opts)

  @doc """
  Removes the OS-keyring item for `key`. Succeeds when no item exists — the
  postcondition ("this machine no longer stores that credential") already
  holds — and reports every other helper failure, so a caller that must not
  orphan a credential can refuse to drop its config reference.
  """
  @spec delete(secret_key(), keyword()) :: :ok | writer_error()
  def delete(key, opts \\ []) when is_secret_key(key), do: impl(opts).delete(key, opts)

  @spec get!(secret_key(), keyword()) :: String.t()
  def get!(key, opts \\ []) when is_atom(key) do
    case get(key, opts) do
      {:ok, value} -> value
      {:error, reason} -> raise ArgumentError, format_error(key, reason)
    end
  end

  @spec available?(keyword()) :: boolean()
  def available?(opts \\ []), do: impl(opts).available?(opts)

  @doc """
  Whether the store `opts` selects can be used right now. Read-only and
  bounded: it never writes, never reads a secret and never raises an unlock
  prompt, so a daemon may run it at boot.
  """
  @spec probe(keyword()) :: verdict()
  def probe(opts \\ []) when is_list(opts), do: impl(opts).probe(opts)

  @doc "Whether an operation may go ahead on this verdict without anyone's help."
  @spec usable?(verdict()) :: boolean()
  def usable?(%{state: state}), do: state in [:available, :unknown]

  @doc """
  Whether a write someone is present for may be tried on this verdict. A
  locked keyring is the one state a person can change at the moment of the
  write: the desktop raises its unlock prompt, and the write succeeds once
  they answer it. Every other refused state has nothing to answer.
  """
  @spec attemptable?(verdict()) :: boolean()
  def attemptable?(%{state: state} = verdict), do: usable?(verdict) or state == :locked

  # A write, and the read `fermix setup --migrate-secrets` makes of a secret it
  # moves, give the operator time to answer the desktop's unlock prompt. A read
  # with nobody present (boot) never waits for one: the probe refuses it before
  # it is tried.
  @unlock_prompt_timeout_ms 120_000

  @doc "How long a write, or a migration's read, waits for the operator to answer an unlock prompt."
  @spec unlock_prompt_timeout_ms() :: pos_integer()
  def unlock_prompt_timeout_ms, do: @unlock_prompt_timeout_ms

  @spec command_source(secret_key()) :: map()
  def command_source(key) when is_secret_key(key), do: impl([]).command_source(key, [])

  @spec command_source(secret_key(), keyword()) :: map()
  def command_source(key, opts) when is_secret_key(key) and is_list(opts),
    do: impl(opts).command_source(key, opts)

  @doc """
  The name an OS store files `key` under, before the profile prefix: a
  registry key's environment name, `external_env:<NAME>`, an MCP server's id,
  or `cue_source:<ref>:<field>`. Raises for an external name, an id or a ref
  that fails validation, so an unvalidated name can never reach a keychain
  address.
  """
  @spec item_name(secret_key()) :: String.t()
  def item_name(key) when is_atom(key), do: SecretPaths.fetch!(key).env

  def item_name({:external_env, name}) when is_binary(name) do
    case ExternalEnv.validate_name(name) do
      :ok -> @external_prefix <> name
      {:error, reason} -> raise ArgumentError, "external env name refused (#{reason})"
    end
  end

  def item_name({:mcp, id}) when is_binary(id) do
    case McpSecrets.parse_id(id) do
      {:ok, _server, _ref} -> id
      :error -> raise ArgumentError, "MCP secret id refused"
    end
  end

  def item_name({:cue_source, ref, field}) when is_binary(ref) and field in @cue_secret_fields do
    if CuesConfig.valid_name?(ref) do
      @cue_source_prefix <> ref <> ":" <> Atom.to_string(field)
    else
      raise ArgumentError, "cue source ref refused"
    end
  end

  @spec format_error(secret_key(), term()) :: String.t()
  def format_error(key, reason) when is_atom(key) do
    secret = SecretPaths.fetch!(key)
    "#{secret.env} could not be resolved from @keyring: #{format_reason(reason)}"
  end

  @spec format_store_error(secret_key(), term()) :: String.t()
  def format_store_error(key, reason) when is_atom(key) do
    secret = SecretPaths.fetch!(key)
    "#{secret.env} could not be stored in the OS keyring: #{format_reason(reason)}"
  end

  defp impl(opts) do
    explicit = Keyword.get(opts, :impl) || Application.get_env(:fermix_core, :secret_writer)

    cond do
      explicit != nil ->
        explicit

      @compiled_env == :test ->
        raise "no :secret_writer configured under test — config/test.exs must keep the " <>
                "SecretWriterStub default so tests can never reach the OS keychain"

      store(opts) == :file ->
        __MODULE__.File

      true ->
        __MODULE__.Auto
    end
  end

  defp format_reason({:helper_timeout, command, timeout}) do
    "#{command} timed out after #{timeout}ms. Unlock your login keychain or keyring, " <>
      "or reconfigure the secret."
  end

  defp format_reason({:verdict, %{sentence: sentence}}), do: sentence

  defp format_reason({:file_store, {:readable_by_others, path}}) do
    "#{path} is readable by other accounts, so it was not read; run: chmod 600 #{path}"
  end

  defp format_reason({:file_store, reason}),
    do: "the secrets directory refused: #{inspect(reason)}"

  defp format_reason({:helper_failed, command, code, output}) do
    "#{command} exited #{code}: #{String.trim_trailing(output)}"
  end

  defp format_reason(:unavailable), do: "no supported OS secret helper is available"

  defp format_reason(:unreadable_keychain_password),
    do: "the login Keychain answered in a form Fermix does not read, so nothing was used"

  defp format_reason(:helper_output_too_large),
    do: "the secret helper answered with more than Fermix reads, so none of it was used"

  defp format_reason(reason), do: inspect(reason)
end

defmodule FermixCore.Setup.SecretWriter.Auto do
  @moduledoc false

  @behaviour FermixCore.Setup.SecretWriter

  import FermixCore.Setup.SecretWriter, only: [is_secret_key: 1]

  alias FermixCore.Setup.SecretWriter

  @default_candidates [
    SecretWriter.MacOS,
    SecretWriter.SecretTool
  ]

  @impl true
  def available?(opts \\ []), do: selected(opts).available?(opts)

  @impl true
  def probe(opts \\ []), do: selected(opts).probe(opts)

  @impl true
  def put(key, value, opts \\ []) when is_secret_key(key) and is_binary(value) do
    selected(opts).put(key, value, opts)
  end

  @impl true
  def get(key, opts \\ []) when is_secret_key(key), do: selected(opts).get(key, opts)

  @impl true
  def delete(key, opts \\ []) when is_secret_key(key), do: selected(opts).delete(key, opts)

  @impl true
  def command_source(key, opts \\ []) when is_secret_key(key) do
    selected(opts).command_source(key, opts)
  end

  defp selected(opts) do
    opts
    |> candidates()
    |> Enum.find(SecretWriter.None, & &1.available?(opts))
  end

  defp candidates(opts) do
    Keyword.get(opts, :candidates) ||
      Application.get_env(:fermix_core, :secret_writer_candidates, @default_candidates)
  end
end

defmodule FermixCore.Setup.SecretWriter.None do
  @moduledoc """
  No-op writer returned when candidate auto-selection finds nothing available.
  Reports unavailable and refuses reads/writes so callers degrade cleanly.
  """

  @behaviour FermixCore.Setup.SecretWriter

  @impl true
  def available?(_opts \\ []), do: false

  @impl true
  def probe(_opts \\ []) do
    %{
      store: :keyring,
      state: :tool_absent,
      sentence:
        "this machine has no keyring client: on Debian and Ubuntu install libsecret-tools, " <>
          "on Fedora libsecret, on macOS the security command is missing"
    }
  end

  @impl true
  def put(_key, _value, _opts \\ []), do: {:error, :unavailable}

  @impl true
  def get(_key, _opts \\ []), do: {:error, :unavailable}

  @impl true
  def delete(_key, _opts \\ []), do: {:error, :unavailable}

  @impl true
  def command_source(_key, _opts \\ []), do: %{source: :command, command: "", args: []}
end

defmodule FermixCore.Setup.SecretWriter.SecretTool do
  @moduledoc false

  @behaviour FermixCore.Setup.SecretWriter

  import FermixCore.Setup.SecretWriter, only: [is_secret_key: 1]

  alias FermixCore.CommandRunner
  alias FermixCore.Setup.SecretService
  alias FermixCore.Setup.SecretWriter

  @account "fermix"
  @label "Fermix"
  @default_timeout_ms 3_000

  @impl true
  def available?(_opts \\ []), do: not is_nil(secret_tool_binary()) and not is_nil(shell_binary())

  # The tool being installed says nothing about the keyring behind it; the
  # Secret Service probe asks the bus, without touching a secret.
  @impl true
  def probe(opts \\ []) do
    if available?(opts) do
      SecretService.Probe.run(Keyword.take(opts, [:supervised, :runner, :find_executable]))
    else
      SecretWriter.None.probe(opts)
    end
  end

  @impl true
  def put(key, value, opts \\ []) when is_secret_key(key) and is_binary(value) do
    write_opts = Keyword.put_new(opts, :timeout_ms, SecretWriter.unlock_prompt_timeout_ms())

    with {:ok, binary} <- fetch_secret_tool_binary(opts),
         {:ok, shell} <- fetch_shell_binary() do
      with_temp_secret(value, fn secret_file ->
        run_with_stdin(shell, secret_file, binary, put_args(key, opts), write_opts)
      end)
    end
  end

  @impl true
  def get(key, opts \\ []) when is_secret_key(key) do
    with {:ok, binary} <- fetch_secret_tool_binary(opts),
         {:ok, output} <- run(binary, lookup_args(key, opts), opts) do
      output
      |> String.trim_trailing("\n")
      |> case do
        "" -> {:error, :missing_secret}
        value -> {:ok, value}
      end
    end
  end

  # `secret-tool clear` exits 0 whether or not an item matched, so a missing
  # item needs no special case here (unlike macOS `security`, which exits 44).
  @impl true
  def delete(key, opts \\ []) when is_secret_key(key) do
    with {:ok, binary} <- fetch_secret_tool_binary(opts),
         {:ok, _output} <- run(binary, clear_args(key, opts), opts) do
      :ok
    end
  end

  @doc """
  The `secret-tool` argument list `delete/2` runs. Exposed as data so the
  attribute coordinate is unit-testable without a libsecret keyring present.
  """
  @spec clear_command(SecretWriter.secret_key(), keyword()) :: [String.t()]
  def clear_command(key, opts \\ []) when is_secret_key(key), do: clear_args(key, opts)

  @impl true
  def command_source(key, opts \\ []) when is_secret_key(key) do
    %{
      source: :command,
      command: secret_tool_binary() || "secret-tool",
      args: lookup_args(key, opts),
      timeout_ms: @default_timeout_ms
    }
  end

  defp put_args(key, opts) do
    ["store", "--label", @label | attributes(key, opts)]
  end

  defp lookup_args(key, opts), do: ["lookup" | attributes(key, opts)]

  defp clear_args(key, opts), do: ["clear" | attributes(key, opts)]

  defp attributes(key, opts) do
    service = SecretWriter.scoped_prefix(opts)
    ["service", service, "account", @account, "env", SecretWriter.item_name(key)]
  end

  # `opts[:find_executable]` and `opts[:command_runner]` (`CommandRunner.run/3`'s
  # shape) stand in for the host in a test, so every answer the tool can give
  # reaches `get/2` without a keyring or the tool installed.
  defp fetch_secret_tool_binary(opts) do
    case Keyword.get(opts, :find_executable, &System.find_executable/1).("secret-tool") do
      nil -> {:error, :unavailable}
      binary -> {:ok, binary}
    end
  end

  defp fetch_shell_binary do
    case shell_binary() do
      nil -> {:error, :unavailable}
      binary -> {:ok, binary}
    end
  end

  defp secret_tool_binary, do: System.find_executable("secret-tool")

  defp shell_binary do
    System.find_executable("sh") ||
      if File.exists?("/bin/sh"), do: "/bin/sh"
  end

  defp timeout(opts), do: Keyword.get(opts, :timeout_ms, @default_timeout_ms)

  defp with_temp_secret(value, fun) do
    case write_temp_secret(value) do
      {:ok, path} ->
        try do
          fun.(path)
        after
          cleanup_temp_secret(path)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_temp_secret(value) do
    dir = Path.join(System.tmp_dir!(), "fermix-secret-#{System.unique_integer([:positive])}")
    path = Path.join(dir, "secret")

    with :ok <- File.mkdir(dir),
         :ok <- File.chmod(dir, 0o700),
         :ok <- File.write(path, value, [:binary]),
         :ok <- File.chmod(path, 0o600) do
      {:ok, path}
    else
      {:error, reason} -> {:error, {:temp_secret_failed, reason}}
    end
  end

  defp cleanup_temp_secret(path) do
    _ = File.rm(path)
    _ = File.rmdir(Path.dirname(path))
    :ok
  end

  defp run_with_stdin(shell, secret_file, binary, args, opts) do
    script = ~s(secret_file=$1; shift; exec "$@" < "$secret_file")
    run(shell, ["-c", script, "fermix-secret", secret_file, binary | args], opts)
  end

  # `supervised` rides in on `opts` from the caller that knows its world: the
  # boot config-provider chain passes `supervised: false` (no supervision tree
  # yet); the daemon wizard/doctor callers omit it (CommandRunner defaults to
  # the supervised host). CommandRunner defaults an absent key to `true`.
  defp run(binary, args, opts) do
    timeout_ms = timeout(opts)
    command = Enum.join([binary | args], " ")

    case command_runner(opts).(
           binary,
           args,
           [timeout_ms: timeout_ms] ++ Keyword.take(opts, [:supervised])
         ) do
      {:ok, %{exit: 0, stdout: output, truncated?: false}} ->
        {:ok, output}

      # What was read is the start of the answer, which can be the secret.
      {:ok, %{truncated?: true}} ->
        {:error, :helper_output_too_large}

      {:ok, %{exit: code, stdout: output}} ->
        {:error, {:helper_failed, command, code, String.slice(output, 0, 200)}}

      {:error, {:timeout, ^timeout_ms}} ->
        {:error, {:helper_timeout, command, timeout_ms}}

      {:error, {:executable_not_found, _path}} ->
        {:error, :unavailable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp command_runner(opts) do
    case Keyword.get(opts, :command_runner, &CommandRunner.run/3) do
      runner when is_function(runner, 3) ->
        runner

      other ->
        raise ArgumentError,
              ":command_runner must be a function of arity 3, got: #{inspect(other)}"
    end
  end
end

defmodule FermixCore.Setup.SecretWriter.MacOS do
  @moduledoc false

  @behaviour FermixCore.Setup.SecretWriter

  import FermixCore.Setup.SecretWriter, only: [is_secret_key: 1]

  alias FermixCore.CommandRunner
  alias FermixCore.Setup.SecretWriter

  @account "fermix"
  @default_timeout_ms 3_000

  @impl true
  def available?(_opts \\ []), do: not is_nil(security_binary())

  # The login Keychain unlocks with the login password on every macOS session,
  # so its usability is the tool's presence; a locked or slow Keychain still
  # reports itself through the operation's own timeout.
  @impl true
  def probe(opts \\ []) do
    if available?(opts) do
      %{store: :keyring, state: :available, sentence: "the login Keychain answers"}
    else
      SecretWriter.None.probe(opts)
    end
  end

  @impl true
  def put(key, value, opts \\ []) when is_secret_key(key) and is_binary(value) do
    write_opts = Keyword.put_new(opts, :timeout_ms, SecretWriter.unlock_prompt_timeout_ms())

    with {:ok, binary} <- fetch_security_binary(opts) do
      [delete, add] = put_commands(key, value, opts)
      # Best-effort delete FIRST so the add re-creates the item fresh with `-A`'s
      # open ACL (see put_commands/put_args). A missing item just errors and falls
      # through; the add still stores the value.
      _ = run(binary, delete, opts)

      case run(binary, add, write_opts) do
        {:ok, _output} -> :ok
        error -> error
      end
    end
  end

  @doc """
  The ordered `security` commands `put/3` runs: delete the existing item, then add
  it back with `-A`. `-A` only sets the open (no per-application) ACL when an item
  is CREATED — on a `-U` update it leaves a pre-existing item's ACL untouched, so a
  secret first written without `-A` (an older Fermix, a manual Keychain entry, or a
  past "Always Allow") would prompt on every headless daemon read forever. Deleting
  first makes each save self-heal to the open ACL. Exposed as data so the sequence
  is unit-testable without touching the real keychain.
  """
  @spec put_commands(SecretWriter.secret_key(), String.t(), keyword()) :: [[String.t()]]
  def put_commands(key, value, opts \\ []) when is_secret_key(key) and is_binary(value) do
    [delete_args(key, opts), put_args(key, value, opts)]
  end

  @impl true
  def get(key, opts \\ []) when is_secret_key(key) do
    with {:ok, binary} <- fetch_security_binary(opts) do
      binary
      |> run(get_args(key, opts), opts)
      |> get_result()
    end
  end

  @doc """
  The `security` argument list `get/2` runs. It reads with `-g`, never `-w`:
  `-w` prints a value holding any byte outside space to tilde (a newline, a tab,
  any non-ASCII character) as bare hex, which no reader can tell from a value
  made of hex digits. Exposed as data so the flag is unit-testable without a
  keychain.
  """
  @spec get_command(SecretWriter.secret_key(), keyword()) :: [String.t()]
  def get_command(key, opts \\ []) when is_secret_key(key), do: get_args(key, opts)

  @doc """
  Classifies a `get/2` helper result: the stored bytes, `:missing_secret` for
  an empty value, `:unreadable_keychain_password` for an answer in no form
  `security -g` prints, or the helper's own failure, unchanged. Exposed as a
  pure function so every form `security` prints is testable without a keychain.
  """
  @spec get_result({:ok, String.t()} | {:error, term()}) :: {:ok, String.t()} | {:error, term()}
  def get_result({:ok, output}) when is_binary(output) do
    case password_lines(output) do
      [line] -> parse_password(line)
      _none_or_several -> {:error, :unreadable_keychain_password}
    end
  end

  def get_result({:error, reason}), do: {:error, reason}

  # `-g` writes `password: ` and the value to stderr, which the runner captures
  # in one stream with the item's attributes on stdout. Where the line falls in
  # that stream depends on stdio buffering (an attribute dump past the 64 KiB
  # buffer can split a row around it), so the parser does not rely on order: it
  # takes the one line that starts with `password: `, and refuses an answer with
  # none, several, or one in neither form below. No attribute line starts with
  # `password: `, and no form below holds a raw newline.
  @password_prefix "password: "
  # Every byte printable and none a backslash: the bytes themselves, in quotes
  # that are not escaped inside.
  @text_form ~r/\Apassword: "([\x20-\x5B\x5D-\x7E]+)"\z/
  # Any other value: `0x` and every byte in uppercase hex, then one space, or
  # two and the value again with octal escapes when any byte is printable.
  @hex_form ~r/\Apassword: 0x((?:[0-9A-F]{2})+)(?: |  ".*")\z/

  defp password_lines(output) do
    output
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, @password_prefix))
  end

  defp parse_password(@password_prefix), do: {:error, :missing_secret}

  defp parse_password(line) do
    case {Regex.run(@text_form, line), Regex.run(@hex_form, line)} do
      {[_line, text], nil} -> {:ok, text}
      {nil, [_line, hex]} -> {:ok, Base.decode16!(hex)}
      _neither -> {:error, :unreadable_keychain_password}
    end
  end

  # `security` exits 44 (errSecItemNotFound) when there is nothing to delete.
  # The postcondition — this machine no longer stores the credential — already
  # holds, so that is success. Every other non-zero exit is REPORTED here,
  # unlike the best-effort delete inside `put/3` whose result is discarded.
  @item_not_found_exit 44

  @impl true
  def delete(key, opts \\ []) when is_secret_key(key) do
    with {:ok, binary} <- fetch_security_binary(opts) do
      binary
      |> run(delete_args(key, opts), opts)
      |> delete_result()
    end
  end

  @doc """
  The `security` argument list `delete/2` runs — the same one `put/3` runs
  before re-adding, so a forget targets exactly the item a save creates.
  Exposed as data so the coordinate is unit-testable without a keychain.
  """
  @spec delete_command(SecretWriter.secret_key(), keyword()) :: [String.t()]
  def delete_command(key, opts \\ []) when is_secret_key(key), do: delete_args(key, opts)

  @doc """
  Classifies a `delete/2` helper result. Exposed as a pure function so the
  "missing item is already forgotten" rule is testable without a keychain.
  """
  @spec delete_result({:ok, String.t()} | {:error, term()}) :: :ok | {:error, term()}
  def delete_result({:ok, _output}), do: :ok

  def delete_result({:error, {:helper_failed, _command, @item_not_found_exit, _output}}), do: :ok

  def delete_result({:error, reason}), do: {:error, reason}

  # A command source's whole stdout is its value, so it reads with `-w`. Settings
  # files record these exact arguments, and `Sandbox.ExternalEnv` knows a stored
  # name by them, so they stay as they are. `-w` prints any byte outside space
  # to tilde as hex, so only a printable ASCII value arrives intact this way,
  # and `ExternalEnv.validate_value/1` refuses any other when it is stored.
  @impl true
  @spec command_source(SecretWriter.secret_key(), keyword()) :: map()
  def command_source(key, opts \\ []) when is_secret_key(key) do
    %{
      source: :command,
      command: security_binary() || "/usr/bin/security",
      args: lookup_args(key, opts),
      timeout_ms: @default_timeout_ms
    }
  end

  # `-A` stores the item with NO per-application ACL. Without it, macOS pins the
  # item's ACL to the exact code signature of the writing binary; the daemon —
  # an ad-hoc-signed, per-version burrito extraction whose signature the keychain
  # cannot reliably match — is then treated as an untrusted app on every read and
  # macOS blocks on an authorization prompt the headless service can never answer,
  # so the read hangs and times out. `-A` lets the daemon read headlessly. The
  # trade-off (any process running as this user can read the item without a
  # prompt) is no weaker than the pre-0.4.x plaintext-in-config baseline, and the
  # secret is still keychain-stored rather than on disk.
  defp put_args(key, value, opts) do
    ["add-generic-password", "-a", @account, "-s", service(key, opts), "-w", value, "-U", "-A"]
  end

  defp delete_args(key, opts) do
    ["delete-generic-password", "-a", @account, "-s", service(key, opts)]
  end

  defp get_args(key, opts) do
    ["find-generic-password", "-a", @account, "-s", service(key, opts), "-g"]
  end

  defp lookup_args(key, opts) do
    ["find-generic-password", "-a", @account, "-s", service(key, opts), "-w"]
  end

  defp service(key, opts),
    do: "#{SecretWriter.scoped_prefix(opts)}:#{SecretWriter.item_name(key)}"

  # `opts[:find_executable]` and `opts[:command_runner]` (`CommandRunner.run/3`'s
  # shape) stand in for the host in a test, so every answer `security` can give
  # reaches `get/2` without a keychain or a Mac.
  defp fetch_security_binary(opts) do
    case security_binary(Keyword.get(opts, :find_executable, &System.find_executable/1)) do
      nil -> {:error, :unavailable}
      binary -> {:ok, binary}
    end
  end

  defp security_binary(find \\ &System.find_executable/1) do
    find.("security") ||
      if File.exists?("/usr/bin/security"), do: "/usr/bin/security"
  end

  defp timeout(opts), do: Keyword.get(opts, :timeout_ms, @default_timeout_ms)

  # CommandRunner kills the OS child on timeout — the prior Task.async +
  # System.cmd pattern only ended the BEAM task and left `security` running
  # (e.g. hung on a locked keychain). `supervised` rides in on `opts`: the boot
  # config-provider chain passes `supervised: false`; daemon callers omit it and
  # CommandRunner defaults to the supervised host.
  defp run(binary, args, opts) do
    timeout_ms = timeout(opts)
    command = Enum.join([binary | args_without_secret(args)], " ")

    case command_runner(opts).(
           binary,
           args,
           [timeout_ms: timeout_ms] ++ Keyword.take(opts, [:supervised])
         ) do
      {:ok, %{exit: 0, stdout: output, truncated?: false}} ->
        {:ok, output}

      # What was read is the start of the answer, which can be the secret.
      {:ok, %{truncated?: true}} ->
        {:error, :helper_output_too_large}

      {:ok, %{exit: code, stdout: output}} ->
        {:error, {:helper_failed, command, code, String.slice(output, 0, 200)}}

      {:error, {:timeout, ^timeout_ms}} ->
        {:error, {:helper_timeout, command, timeout_ms}}

      {:error, {:executable_not_found, _path}} ->
        {:error, :unavailable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp args_without_secret(["add-generic-password" | rest]) do
    rest
    |> Enum.chunk_every(2)
    |> Enum.flat_map(fn
      ["-w", _value] -> ["-w", "<redacted>"]
      pair -> pair
    end)
    |> then(&["add-generic-password" | &1])
  end

  defp args_without_secret(args), do: args

  defp command_runner(opts) do
    case Keyword.get(opts, :command_runner, &CommandRunner.run/3) do
      runner when is_function(runner, 3) ->
        runner

      other ->
        raise ArgumentError,
              ":command_runner must be a function of arity 3, got: #{inspect(other)}"
    end
  end
end
