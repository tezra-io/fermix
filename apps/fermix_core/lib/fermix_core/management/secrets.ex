defmodule FermixCore.Management.Secrets do
  @moduledoc """
  `secret.set` and `secret.clear`: the only inbound direction a credential ever
  travels over the management socket (M34 native setup §7.4).

  One secret per call, never readable back, and every other method reports
  presence only. "Present" is a sentinel or a plaintext value at the key's own
  `SecretPaths` path, never "the keychain holds an item": a key stored without
  its reference is never read back, so calling it present would describe a
  credential the runtime cannot use.

  Three id families, one mechanism. A bare id is a `SecretPaths` registry key.
  `plugin:<name>` is the static credential an `api_key` plugin authenticates
  with, and `oauth_client:<provider>` is a sign-in client's secret; both already
  have a registered `SecretPaths` entry, so both resolve to a key and take the
  same keychain-first write. That is the point of routing them here rather than
  through `Plugins.Config`: a rotation into a locked keychain fails loud instead
  of reporting success while the old value survives (M34 native setup §7.4).

  Every family asks the settings file's write guard (`RestartState.writable/0`)
  before it touches a store, so a write refused for an outside edit
  (`external_change`, `config_unreadable`) has changed nothing: the refusal is
  the whole answer, and a stored value stays the one it was.

  `anthropic_setup_token` is the fourth id and the one that is a DIFFERENT
  mechanism: a `claude setup-token` value is a long-lived subscription
  credential, so it writes through `Auth.Store` under the `anthropic_oauth`
  profile and touches neither the keychain nor a `SecretPaths` path. It is
  Anthropic's second way in beside adopting a Claude Code login, so storing one
  also selects the route that reads it — a stored token the runtime never calls
  would report success and change nothing — and clearing one is the same
  operation as signing out, which is where that mechanism already lives.

  A registry key's result also names the environment variable this daemon
  uses in place of the stored value, when `config/runtime.exs` layers one over
  it (`environment_override`, else null): storing a value the next start will
  not use is still stored, and the result says so instead of reading as a plain
  success. The other families carry null, because no variable replaces them.

  `env:<NAME>` is the fifth family and the second different mechanism: a
  skill's own credential, passed to every sandboxed command as the allowed
  environment variable `NAME` (M45 §4.3). It is not a `SecretPaths` key and not
  boot-bound, so it skips `SecretWriteLog` and provider promotion. The value is
  stored under `{:external_env, NAME}`, read back and compared, and only then
  referenced from `[sandbox.env.<NAME>]` by the writer's own lookup; that
  reference is what "present" means. Every rule about which names and values
  may be stored, and which entries count as stored, is `Sandbox.ExternalEnv`'s.

  `mcp:<server>/env/<NAME>`, `mcp:<server>/header/<Header-Name>` and
  `mcp:<server>/client_secret` are the sixth family (M74 E6): the values an
  operator MCP server declares. It is open like `env:`, and an id is accepted
  only when its server exists and declares that name; the server's block in
  `config.toml` is the reference, so storing writes nothing else, and present
  means the store reads the value back. A value is not in the server's spec,
  so a reload cannot see it arrive: storing the last value an enabled server
  was missing starts it, and storing a new one restarts it, through
  `McpSupervisor.restart_server/2`, as a rotated plugin credential is.
  Addressing, storage and presence are `Capabilities.MCP.Secrets`'s.
  """

  alias FermixCore.Auth.AnthropicLogin
  alias FermixCore.Auth.Store, as: AuthStore
  alias FermixCore.Auth.TokenSupervisor
  alias FermixCore.Capabilities.MCP.Config, as: McpConfig
  alias FermixCore.Capabilities.MCP.Secrets, as: McpSecrets
  alias FermixCore.Capabilities.MCP.Supervisor, as: McpSupervisor
  alias FermixCore.Management.Auth
  alias FermixCore.Management.Settings
  alias FermixCore.Sandbox.Config, as: SandboxConfig
  alias FermixCore.Sandbox.ExternalEnv
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.RestartState
  alias FermixCore.Setup.SecretPaths
  alias FermixCore.Setup.SecretStore
  alias FermixCore.Setup.SecretWriter
  alias FermixCore.Setup.Wizard

  require Logger

  @max_value_bytes 8_192
  # The two prefixed families, spelled once. They are the ids the integrations
  # surface addresses: a plugin's own token and a sign-in client's secret.
  @plugin_prefix "plugin:"
  @oauth_client_prefix "oauth_client:"
  @oauth_client_root [:fermix_core, :oauth]
  # The one id that is not a `SecretPaths` key. Spelled once.
  @setup_token_id "anthropic_setup_token"
  @setup_token_auth_mode "setup_token"
  # The open family: any name `Sandbox.ExternalEnv` accepts, so it is never
  # enumerated by `ids/0`.
  @env_prefix "env:"
  @env_name_sentence "A variable name is letters, digits and underscores, " <>
                       "does not start with a digit, and is at most 128 characters."
  @env_reserved_sentence "Fermix sets this variable itself, so it cannot be stored."
  @env_line_sentence "A stored variable is one line with no null characters."
  @env_elsewhere_sentence "This variable is read from a helper command or another variable. " <>
                            "Change that in the settings file first."
  # The open family of values an operator MCP server declares.
  @mcp_prefix McpSecrets.prefix()
  @mcp_id_sentence "An MCP server's secret is mcp:<server>/env/<NAME>, " <>
                     "mcp:<server>/header/<Header-Name> or mcp:<server>/client_secret."
  @mcp_legacy_sentence "Fermix keeps no secrets for a server with this name. " <>
                         "Remove the server and add it again under a lowercase name."

  @type error ::
          {:invalid_params, String.t(), String.t()}
          | {:secret_store_failed, String.t(), String.t()}
          | {:external_change, [String.t()]}
          | {:config_unreadable, String.t()}

  @doc """
  Every id this method accepts, as the wire spells them: the registry keys, then
  the prefixed spelling of each one the two other families also reach. The
  `env:<NAME>` family is open, one id per storable name, so it is not listed.
  """
  @spec ids() :: [String.t()]
  def ids do
    Enum.map(SecretPaths.all(), &Atom.to_string(&1.key)) ++
      plugin_ids() ++ oauth_client_ids() ++ [@setup_token_id]
  end

  @doc "The `secret.set` id prefix for one plugin's own token."
  @spec plugin_prefix() :: String.t()
  def plugin_prefix, do: @plugin_prefix

  @doc "The `secret.set` id prefix for one sign-in client's secret."
  @spec oauth_client_prefix() :: String.t()
  def oauth_client_prefix, do: @oauth_client_prefix

  @doc "The `secret.set` id prefix for one sandbox environment variable."
  @spec env_prefix() :: String.t()
  def env_prefix, do: @env_prefix

  @doc "The `secret.set` id prefix for one value an MCP server declares."
  @spec mcp_prefix() :: String.t()
  def mcp_prefix, do: @mcp_prefix

  defp plugin_ids do
    SecretPaths.all()
    |> Enum.filter(&Map.has_key?(&1, :plugin))
    |> Enum.map(&(@plugin_prefix <> &1.plugin))
  end

  defp oauth_client_ids do
    SecretPaths.all()
    |> Enum.filter(&oauth_client_provider(&1.path))
    |> Enum.map(&(@oauth_client_prefix <> oauth_client_provider(&1.path)))
  end

  defp oauth_client_provider(@oauth_client_root ++ [provider, :client_secret])
       when is_binary(provider),
       do: provider

  defp oauth_client_provider(_path), do: nil

  @doc """
  Stores one secret and answers with its presence, never its value.

  `:mcp_supervisor` names the module that starts an MCP server whose values
  are now complete, for a test; every other family takes no option.
  """
  @spec set(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def set(id, value, opts \\ [])

  def set(@setup_token_id = id, value, _opts) when is_binary(value) do
    with :ok <- validate_value(value) do
      store_setup_token(id, String.trim(value))
    end
  end

  # M45 §4.3 step 1: every refusal that needs no storage call comes first.
  def set(@env_prefix <> name = id, value, _opts) when is_binary(value) do
    with :ok <- validate_env_name(name),
         :ok <- validate_env_value(value),
         {:ok, new_entry?} <- env_storable(name) do
      store_env(id, name, value, new_entry?)
    end
  end

  def set(@mcp_prefix <> _rest = id, value, opts) when is_binary(value) and is_list(opts) do
    with {:ok, server, ref} <- mcp_target(id),
         :ok <- validate_mcp_value(value) do
      store_mcp(id, server, ref, value, opts)
    end
  end

  def set(id, value, _opts) when is_binary(id) and is_binary(value) do
    with {:ok, key} <- fetch_key(id),
         :ok <- validate_value(value) do
      commit(id, key, fn -> Wizard.put_secret(key, value) end)
    end
  end

  @doc "Forgets one secret, keyring item first, then the reference that reads it."
  @spec clear(String.t()) :: {:ok, map()} | {:error, error()}
  def clear(@setup_token_id = id), do: forget_setup_token(id)

  def clear(@env_prefix <> name = id) do
    with :ok <- validate_env_name(name), do: forget_env(id, name)
  end

  def clear(@mcp_prefix <> _rest = id) do
    with {:ok, server, ref} <- mcp_target(id), do: forget_mcp(id, server, ref)
  end

  def clear(id) when is_binary(id) do
    with {:ok, key} <- fetch_key(id) do
      commit(id, key, fn -> Wizard.clear_secret(key) end)
    end
  end

  # A stored token is inert until the route selects it, so storing one and
  # selecting it are one operation — the same pairing `auth.start xai` makes.
  # The promotion is the same one every other connect runs: on a home with no
  # configured primary yet, the provider just connected becomes it.
  defp store_setup_token(id, value) do
    with :ok <- RestartState.writable(),
         {:ok, _entry} <- AnthropicLogin.store_setup_token(value),
         {:ok, _report} <- Wizard.set_provider_auth_mode(:anthropic, :oauth),
         {:ok, _token} <- TokenSupervisor.reload(AuthStore.profile(:anthropic)),
         :ok <- Wizard.promote_if_first_configured(:anthropic) do
      {:ok, setup_token_view(id)}
    else
      {:error, reason} -> {:error, error(id, reason)}
    end
  end

  # Forgetting the token, reverting the route it fed and dropping the tokens the
  # running daemon holds is exactly signing out, and that mechanism already
  # exists. Clearing a token that was never stored succeeds: the postcondition
  # already holds, the same rule every other `clear` follows.
  defp forget_setup_token(id) do
    case Auth.logout("anthropic") do
      {:ok, _result} -> {:ok, setup_token_view(id)}
      {:error, reason} -> {:error, error(id, reason)}
    end
  end

  # Presence is "a setup token is stored", not "an Anthropic sign-in exists": an
  # adopted Claude Code login lives under the same profile and is a different
  # credential, reported by `setup.state.get`'s account row rather than here.
  defp setup_token_view(id) do
    %{
      "id" => id,
      "present" => setup_token_present?(),
      "restart" => Settings.restart(),
      "environment_override" => nil
    }
  end

  defp setup_token_present? do
    case AuthStore.read(AuthStore.profile(:anthropic)) do
      {:ok, %{auth_mode: @setup_token_auth_mode}} -> true
      _absent_or_other_mode -> false
    end
  end

  # Steps 2 and 3: a store that exists, then the write. A write the store
  # refused left nothing behind, so there is nothing to undo.
  defp store_env(id, name, value, new_entry?) do
    with :ok <- RestartState.writable(),
         :ok <- env_store_available(),
         :ok <- SecretWriter.put(ExternalEnv.key(name), value) do
      commit_env(id, name, value, new_entry?)
    else
      {:error, reason} -> {:error, env_error(id, name, reason)}
    end
  end

  # Steps 3 to 6: the value is read back and compared before the settings file
  # points at it, and one commit allows and references the name. A failure
  # after the write deletes an item this call created, once; an item the file
  # already pointed at stays, because the entry names it.
  defp commit_env(id, name, value, new_entry?) do
    with :ok <- verify_env(ExternalEnv.key(name), value),
         {:ok, _report} <- Wizard.update_sandbox_env(&ExternalEnv.put_managed(&1, name)) do
      {:ok, env_view(id, name)}
    else
      {:error, reason} ->
        :ok = undo_new_env(name, new_entry?)
        {:error, env_error(id, name, reason)}
    end
  end

  # The store's verdict, not the tool's presence. A locked keyring is tried:
  # the person saving from the app answers the desktop's unlock prompt, and a
  # cancelled prompt is the write's own `locked` failure.
  defp env_store_available do
    verdict = SecretWriter.probe()
    if SecretWriter.attemptable?(verdict), do: :ok, else: {:error, {:verdict, verdict}}
  end

  defp verify_env(key, value) do
    case SecretWriter.get(key) do
      {:ok, ^value} -> :ok
      {:ok, _other} -> {:error, :verify_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp undo_new_env(_name, false), do: :ok

  defp undo_new_env(name, true) do
    case SecretWriter.delete(ExternalEnv.key(name)) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("secret.set env:#{name} left a stored item behind: #{kind(reason)}")
        :ok
    end
  end

  # The item first, then the reference: a refused delete keeps the reference
  # that names the item, never an item nothing names. A source that is not the
  # writer's own lookup is never touched.
  defp forget_env(id, name) do
    with :ok <- RestartState.writable(),
         :ok <- SecretWriter.delete(ExternalEnv.key(name)),
         {:ok, _report} <- drop_env_reference(name) do
      {:ok, env_view(id, name)}
    else
      {:error, reason} -> {:error, env_error(id, name, reason)}
    end
  end

  defp drop_env_reference(name) do
    if ExternalEnv.source_kind(SandboxConfig.current().env, name) == :managed do
      Wizard.update_sandbox_env(&ExternalEnv.drop_managed(&1, name))
    else
      {:ok, :untouched}
    end
  end

  # The server an `mcp:` id names, from the servers this daemon applied, and the
  # value it declares. An id for a server that does not exist, or a name it does
  # not declare, is refused: the family is open, so the declaration is the only
  # thing that makes an id mean something.
  defp mcp_target(id) do
    with {:ok, name, ref} <- parse_mcp_id(id),
         {:ok, server} <- mcp_server(name),
         :ok <- mcp_declared(server, ref) do
      {:ok, server, ref}
    end
  end

  defp parse_mcp_id(id) do
    case McpSecrets.parse_id(id) do
      {:ok, name, ref} ->
        {:ok, name, ref}

      :error ->
        {:error, {:invalid_params, "id", mcp_id_sentence(McpSecrets.server_of(id))}}
    end
  end

  # A server a file named before the name rule loads and runs, and no id can
  # address it: the way to a secret is a name the rule allows.
  defp mcp_id_sentence(name) do
    if not McpConfig.valid_name?(name) and Enum.any?(McpConfig.configured(), &(&1.name == name)),
      do: @mcp_legacy_sentence,
      else: @mcp_id_sentence
  end

  defp mcp_server(name) do
    case Enum.find(McpConfig.configured(), &(&1.name == name)) do
      nil -> {:error, {:invalid_params, "id", "There is no MCP server by that name."}}
      server -> {:ok, server}
    end
  end

  defp mcp_declared(server, ref) do
    if McpSecrets.declares?(server, ref),
      do: :ok,
      else: {:error, {:invalid_params, "id", "This MCP server does not declare that secret."}}
  end

  defp validate_mcp_value(value) do
    case McpSecrets.validate_value(value) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_params, "value", mcp_value_sentence(reason)}}
    end
  end

  defp mcp_value_sentence(:empty_value), do: "A secret cannot be empty."

  defp mcp_value_sentence(:value_too_large),
    do: "A secret is at most #{McpSecrets.max_value_bytes()} bytes."

  defp mcp_value_sentence(:value_not_single_line), do: "A secret is one line."

  defp store_mcp(id, server, ref, value, opts) do
    with :ok <- RestartState.writable(),
         :ok <- McpSecrets.put(server.name, ref, value) do
      :ok = start_when_complete(server, opts)
      {:ok, mcp_view(id, true)}
    else
      {:error, reason} -> {:error, mcp_error(id, reason)}
    end
  end

  # The value just stored is read in the transport's own `init`, so only a
  # start reaches it. A server still missing a value, a disabled one, and one
  # this build does not start are left as they are.
  defp start_when_complete(server, opts) do
    if McpConfig.startable?(server) and McpSecrets.complete?(server) do
      supervisor = Keyword.get(opts, :mcp_supervisor, McpSupervisor)
      started(server.name, supervisor.restart_server({:operator, server.name}, server))
    else
      :ok
    end
  end

  # The value is stored either way, so the answer is the store's; a server that
  # did not start says why in the log and on its row.
  defp started(_name, {:ok, _pid}), do: :ok

  defp started(name, {:error, reason}) do
    Logger.error(
      "MCP server #{name} did not start after its secret was stored: #{inspect(reason)}"
    )

    :ok
  end

  defp forget_mcp(id, server, ref) do
    with :ok <- RestartState.writable(),
         :ok <- McpSecrets.delete(server.name, ref) do
      {:ok, mcp_view(id, false)}
    else
      {:error, reason} -> {:error, mcp_error(id, reason)}
    end
  end

  # The same shape as `env:`: no variable replaces an MCP server's value.
  defp mcp_view(id, present) do
    %{
      "id" => id,
      "present" => present,
      "restart" => Settings.restart(),
      "environment_override" => nil
    }
  end

  # A pasted `Bearer ` with nothing after it is empty once the scheme is off.
  defp mcp_error(_id, reason)
       when reason in [:empty_value, :value_too_large, :value_not_single_line],
       do: {:invalid_params, "value", mcp_value_sentence(reason)}

  defp mcp_error(id, reason) do
    case error(id, reason) do
      {:secret_store_failed, _id, published} = failure ->
        Logger.warning("secret #{id} failed (#{published}): #{kind(reason)}")
        failure

      refusal ->
        refusal
    end
  end

  # Whether storing may go ahead, and whether it creates the entry: a name whose
  # value comes from elsewhere is refused, because storing would silently move
  # it, and a new entry past the ceiling is refused before anything is written.
  defp env_storable(name) do
    env = SandboxConfig.current().env

    case ExternalEnv.source_kind(env, name) do
      :managed -> {:ok, false}
      :engine_env -> env_entry_allowed(env)
      _helper_or_alias -> {:error, {:invalid_params, "id", @env_elsewhere_sentence}}
    end
  end

  defp env_entry_allowed(env) do
    if length(ExternalEnv.managed_names(env)) < ExternalEnv.max_managed() do
      {:ok, true}
    else
      sentence = "At most #{ExternalEnv.max_managed()} variables can be stored. Remove one first."
      {:error, {:invalid_params, "id", sentence}}
    end
  end

  defp env_view(id, name) do
    present = ExternalEnv.source_kind(SandboxConfig.current().env, name) == :managed

    %{
      "id" => id,
      "present" => present,
      "restart" => Settings.restart(),
      "environment_override" => nil
    }
  end

  defp validate_env_name(name) do
    case ExternalEnv.validate_name(name) do
      :ok -> :ok
      {:error, :invalid_name} -> {:error, {:invalid_params, "id", @env_name_sentence}}
      {:error, :reserved_name} -> {:error, {:invalid_params, "id", @env_reserved_sentence}}
    end
  end

  defp validate_env_value(value) do
    case ExternalEnv.validate_value(value) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_params, "value", env_value_sentence(reason)}}
    end
  end

  # The first two are the registry family's own sentences for the same refusal.
  defp env_value_sentence(:empty_value), do: "A secret cannot be empty."

  defp env_value_sentence(:value_too_large),
    do: "A secret is at most #{ExternalEnv.max_value_bytes()} bytes."

  defp env_value_sentence(:value_not_single_line), do: @env_line_sentence

  # The closed reason set collapses what went wrong, so the kind is logged for
  # whoever reads the daemon log. Never the value, never a helper's output.
  defp env_error(id, name, reason) do
    case error(id, reason) do
      {:secret_store_failed, _id, published} = failure ->
        Logger.warning("secret env:#{name} failed (#{published}): #{kind(reason)}")
        failure

      refusal ->
        refusal
    end
  end

  defp kind(reason) when is_atom(reason), do: reason
  defp kind(reason) when is_tuple(reason), do: elem(reason, 0)
  defp kind(_reason), do: :unexpected

  defp commit(id, key, write) do
    case write.() do
      {:ok, _report} -> {:ok, view(id, key)}
      {:error, reason} -> {:error, error(id, reason)}
    end
  end

  # `environment_override` names the variable this daemon uses in place of
  # the stored value (`SecretPaths.env_override/2`), so a write the next start
  # will ignore never reads as a plain success.
  defp view(id, key) do
    %{
      "id" => id,
      "present" => present?(key),
      "restart" => Settings.restart(),
      "environment_override" => SecretPaths.env_override(key)
    }
  end

  defp present?(key) do
    value =
      SecretStore.get_snapshot_value(ConfigStore.current_snapshot(), SecretPaths.fetch!(key).path)

    is_binary(value) and value != ""
  end

  defp fetch_key(@plugin_prefix <> name) do
    case SecretPaths.fetch_plugin(name) do
      %{key: key} -> {:ok, key}
      nil -> {:error, {:invalid_params, "id", "This plugin stores no token of its own."}}
    end
  end

  defp fetch_key(@oauth_client_prefix <> provider) do
    case Enum.find(SecretPaths.all(), &(oauth_client_provider(&1.path) == provider)) do
      %{key: key} -> {:ok, key}
      nil -> {:error, {:invalid_params, "id", "This daemon has no sign-in client for that."}}
    end
  end

  defp fetch_key(id) do
    case Enum.find(SecretPaths.all(), &(Atom.to_string(&1.key) == id)) do
      %{key: key} -> {:ok, key}
      nil -> {:error, {:invalid_params, "id", "This daemon stores no secret by that name."}}
    end
  end

  defp validate_value(value) when byte_size(value) == 0,
    do: {:error, {:invalid_params, "value", "A secret cannot be empty."}}

  defp validate_value(value) when byte_size(value) > @max_value_bytes do
    {:error, {:invalid_params, "value", "A secret is at most #{@max_value_bytes} bytes."}}
  end

  defp validate_value(_value), do: :ok

  defp error(id, {:secret_store_failed, _key, reason}),
    do: {:secret_store_failed, id, store_reason(reason)}

  defp error(_id, {:external_change, sections}), do: {:external_change, sections}
  defp error(_id, {:config_unreadable, sentence}), do: {:config_unreadable, sentence}

  defp error(id, reason),
    do: {:secret_store_failed, id, store_reason(reason)}

  # The closed set the contract publishes. A helper that ran and refused is the
  # locked case on every platform Fermix writes secrets on: macOS `security`
  # exits non-zero on a locked or denied keychain, and `secret-tool` on an
  # unavailable collection.
  defp store_reason({:helper_timeout, _command, _timeout}), do: "timeout"
  defp store_reason({:helper_failed, _command, _code, _output}), do: "locked"
  defp store_reason({:verdict, %{state: :locked}}), do: "locked"
  defp store_reason(_reason), do: "unavailable"
end
