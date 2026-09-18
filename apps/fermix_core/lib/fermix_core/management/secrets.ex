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

  `anthropic_setup_token` is the fourth id and the one that is a DIFFERENT
  mechanism: a `claude setup-token` value is a long-lived subscription
  credential, so it writes through `Auth.Store` under the `anthropic_oauth`
  profile and touches neither the keychain nor a `SecretPaths` path. It is
  Anthropic's second way in beside adopting a Claude Code login, so storing one
  also selects the route that reads it — a stored token the runtime never calls
  would report success and change nothing — and clearing one is the same
  operation as signing out, which is where that mechanism already lives.

  `env:<NAME>` is the fifth family and the second different mechanism: a
  skill's own credential, passed to every sandboxed command as the allowed
  environment variable `NAME` (M45 §4.3). It is not a `SecretPaths` key and not
  boot-bound, so it skips `SecretWriteLog` and provider promotion. The value is
  stored under `{:external_env, NAME}`, read back and compared, and only then
  referenced from `[sandbox.env.<NAME>]` by the writer's own lookup; that
  reference is what "present" means. Every rule about which names and values
  may be stored, and which entries count as stored, is `Sandbox.ExternalEnv`'s.
  """

  alias FermixCore.Auth.AnthropicLogin
  alias FermixCore.Auth.Store, as: AuthStore
  alias FermixCore.Auth.TokenSupervisor
  alias FermixCore.Management.Auth
  alias FermixCore.Management.Settings
  alias FermixCore.Sandbox.Config, as: SandboxConfig
  alias FermixCore.Sandbox.ExternalEnv
  alias FermixCore.Setup.ConfigStore
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

  @doc "Stores one secret and answers with its presence, never its value."
  @spec set(String.t(), String.t()) :: {:ok, map()} | {:error, error()}
  def set(@setup_token_id = id, value) when is_binary(value) do
    with :ok <- validate_value(value) do
      store_setup_token(id, String.trim(value))
    end
  end

  # M45 §4.3 step 1: every refusal that needs no storage call comes first.
  def set(@env_prefix <> name = id, value) when is_binary(value) do
    with :ok <- validate_env_name(name),
         :ok <- validate_env_value(value),
         {:ok, new_entry?} <- env_storable(name) do
      store_env(id, name, value, new_entry?)
    end
  end

  def set(id, value) when is_binary(id) and is_binary(value) do
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
    with {:ok, _entry} <- AnthropicLogin.store_setup_token(value),
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
    %{"id" => id, "present" => setup_token_present?(), "restart" => Settings.restart()}
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
    with :ok <- env_store_available(),
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

  defp env_store_available do
    if SecretWriter.available?(), do: :ok, else: {:error, :unavailable}
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
    with :ok <- SecretWriter.delete(ExternalEnv.key(name)),
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
    %{"id" => id, "present" => present, "restart" => Settings.restart()}
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

  defp view(id, key) do
    %{
      "id" => id,
      "present" => present?(key),
      "restart" => Settings.restart()
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
  defp store_reason(_reason), do: "unavailable"
end
