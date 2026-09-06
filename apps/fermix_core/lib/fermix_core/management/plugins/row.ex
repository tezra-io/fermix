defmodule FermixCore.Management.Plugins.Row do
  @moduledoc """
  One integration row, in the daemon's own words (M34 native setup §5.6).

  Every string a surface renders is built here: the status sentence, the verb
  labels, the consent line and the remote disclosure. The client arranges them
  and writes none of them, which is why the status vocabulary and the verb
  vocabulary are published rather than reproduced on the far side.

  A word is not a routing key, so every verb is published TWICE: `verbs` carries
  the words to draw, and `actions` carries a closed id per word, in the same
  order, saying which method that button runs. `primary_verb` and
  `primary_action` are the same pair for the verb the row leads with. Without
  the ids a client has to guess the method from the row's own state, and the
  guess and the word disagree: a needs_workspace row drew a button labelled
  "Choose workspace" that ran the health check, and a needs_client_config row
  drew "Set up the sign-in client" onto a sign-in the daemon refuses.

  Two halves feed one shape. An installed plugin's row comes from the registry
  manifest plus `Plugins.Status`'s local ladder, refined by
  `Capabilities.MCP.RuntimeStatus` where a live remote client exists. A
  not-yet-installed row comes from the baked catalog index alone: nothing has
  been fetched, so it carries the branding and the pre-install consent sentence
  and nothing else.

  The consent sentence is the field the plugin catalog shipped wrong once (a
  hosted plugin rendering the local-process line), so it is derived from the
  runtime kind on both halves and never defaulted: a plugin with no runtime
  block runs inside Fermix itself, which is its own sentence rather than the
  absence of one.
  """

  alias FermixCore.Capabilities.MCP.RuntimeStatus
  alias FermixCore.Plugins.Config
  alias FermixCore.Plugins.Plugin
  alias FermixCore.Plugins.Status

  # The catalog half answers one status the registry ladder cannot: an entry
  # that exists in the index and nowhere else.
  @catalog_statuses [:available]

  # The closed verb vocabulary. A client renders these words; it never composes
  # one and never switches on the string.
  @verbs [
    "Install…",
    "Turn on",
    "Turn off",
    "Sign in",
    "Sign in again",
    "Add token…",
    "Replace the token",
    "Set up the sign-in client",
    "Choose workspace",
    "Check again",
    "Disconnect"
  ]

  # The verb word to the action it runs. Two words share one id on purpose:
  # "Sign in" and "Sign in again" are the same method with different copy, and a
  # client must not need to know which one it was handed.
  @actions %{
    "Install…" => "install",
    "Turn on" => "enable",
    "Turn off" => "disable",
    "Sign in" => "sign_in",
    "Sign in again" => "sign_in",
    "Add token…" => "add_token",
    "Replace the token" => "replace_token",
    "Set up the sign-in client" => "set_up_client",
    "Choose workspace" => "choose_workspace",
    "Check again" => "check",
    "Disconnect" => "disconnect"
  }

  # How a plugin's code runs, as the manifest and the index spell it. `nil` is
  # not "unknown": it is the http rail, which runs inside Fermix itself.
  @runtime_kinds ~w(local_stdio remote_mcp)
  @auth_kinds ~w(oauth api_key)

  @type t :: %{String.t() => term()}

  @doc "Every status a row's sentence covers, ordered."
  @spec statuses() :: [atom()]
  def statuses do
    Enum.uniq(Status.statuses() ++ RuntimeStatus.statuses() ++ @catalog_statuses)
  end

  @doc "Every verb a row may publish, ordered."
  @spec verbs() :: [String.t()]
  def verbs, do: @verbs

  @doc """
  Every action id a row may publish, in verb order.

  `null` is not in this set: it is the `primary_action` of a row whose next step
  is not a button this surface owns.
  """
  @spec actions() :: [String.t()]
  def actions, do: @verbs |> Enum.map(&Map.fetch!(@actions, &1)) |> Enum.uniq()

  @doc "Every runtime kind a row may publish. `null` is the http rail and is not in this set."
  @spec runtime_kinds() :: [String.t()]
  def runtime_kinds, do: @runtime_kinds

  @doc "Every credential kind a row may publish. `null` is a plugin that needs none."
  @spec auth_kinds() :: [String.t()]
  def auth_kinds, do: @auth_kinds

  @doc """
  Why a health check refused a plugin that is not ready.

  The check needs a started plugin, so the answer is the ladder's own sentence
  for where it actually stands rather than a second vocabulary for the same
  fact.
  """
  @spec check_sentence(atom()) :: String.t()
  def check_sentence(status) when is_atom(status) do
    "The check needs a plugin that is ready. " <> sentence(status, empty_facts())
  end

  @doc """
  One installed plugin's row.

  `context` carries what the caller resolved once for the whole listing:
  `:enabled` (the enabled names), `:status` (the resolved status atom) and
  `:workspaces` (what the last discovery found).
  """
  @spec installed(Plugin.t(), map()) :: t()
  def installed(%Plugin{} = plugin, context) when is_map(context) do
    kind = runtime_kind(plugin)
    status = Map.fetch!(context, :status)
    facts = installed_facts(plugin, context)
    verbs = verb_list(status, facts)

    %{
      "name" => plugin.name,
      "title" => plugin.display_name,
      "version" => plugin.version,
      "runtime_kind" => kind,
      "auth_kind" => auth_kind(plugin.auth[:type]),
      "auth_provider" => plugin.auth[:provider],
      "installed" => true,
      "enabled" => facts.enabled,
      "status" => Atom.to_string(status),
      "status_sentence" => sentence(status, facts),
      "primary_verb" => primary_verb(status),
      "primary_action" => action(primary_verb(status)),
      "verbs" => verbs,
      "actions" => Enum.map(verbs, &action/1),
      "settings" => settings(plugin),
      "account_label" => facts.account_label,
      "credential_present" => facts.credential_present,
      "consent_sentence" => consent(kind),
      "remote_disclosure" => disclosure(kind, plugin.display_name),
      "summary" => plugin.description,
      "access_profiles" => access_profiles(plugin),
      "workspaces" => Map.fetch!(context, :workspaces),
      "workspace_id" => facts.workspace_id,
      "workspace_label" => facts.workspace_label
    }
  end

  @doc "One catalog entry's row: branding and consent, before anything is fetched."
  @spec available(map()) :: t()
  def available(entry) when is_map(entry) do
    status = catalog_status(entry)
    kind = entry.runtime_kind
    verbs = verb_list(status, empty_facts())

    %{
      "name" => entry.name,
      "title" => entry.display_name,
      "version" => entry.latest,
      "runtime_kind" => kind,
      "auth_kind" => auth_kind(entry.auth_type),
      "auth_provider" => entry.provider,
      "installed" => false,
      "enabled" => false,
      "status" => Atom.to_string(status),
      "status_sentence" => sentence(status, empty_facts()),
      "primary_verb" => primary_verb(status),
      "primary_action" => action(primary_verb(status)),
      "verbs" => verbs,
      "actions" => Enum.map(verbs, &action/1),
      "settings" => [],
      "account_label" => nil,
      "credential_present" => false,
      "consent_sentence" => consent(kind),
      "remote_disclosure" => disclosure(kind, entry.display_name),
      "summary" => entry.description,
      "access_profiles" => [],
      "workspaces" => [],
      "workspace_id" => nil,
      "workspace_label" => nil
    }
  end

  defp installed_facts(plugin, context) do
    selection = Config.workspace_selection(plugin.name)
    account = Status.account_label(plugin)

    %{
      enabled: plugin.name in Map.fetch!(context, :enabled),
      account_label: account,
      credential_present: credential_present?(plugin, account),
      workspace_id: selection.workspace_id,
      workspace_label: selection.workspace_label
    }
  end

  defp empty_facts do
    %{
      enabled: false,
      account_label: nil,
      credential_present: false,
      workspace_id: nil,
      workspace_label: nil
    }
  end

  # A credential sits behind this plugin. For an OAuth plugin the stored session
  # is the credential; for an api_key plugin it is the keychained token. This is
  # published rather than left to be inferred from `account_label`, which an
  # api_key plugin never has: inferring it there hides the token that is
  # actually stored and takes Disconnect off the row that most needs it.
  defp credential_present?(%Plugin{auth: %{type: :oauth2}}, account), do: account != nil

  defp credential_present?(%Plugin{auth: %{type: :api_key}, name: name}, _account),
    do: Config.plugin_secret(name) not in [nil, ""]

  defp credential_present?(%Plugin{}, _account), do: false

  defp catalog_status(%{compat: {:error, _reason}}), do: :incompatible
  defp catalog_status(_entry), do: :available

  defp runtime_kind(%Plugin{runtime: runtime}) when is_map(runtime) do
    case Map.get(runtime, "kind") do
      kind when kind in @runtime_kinds -> kind
      _absent_or_unknown -> nil
    end
  end

  defp runtime_kind(%Plugin{}), do: nil

  defp auth_kind(:oauth2), do: "oauth"
  defp auth_kind(:api_key), do: "api_key"
  defp auth_kind(_none), do: nil

  defp settings(%Plugin{name: name, config: entries}) do
    configured = Config.plugin_settings(name)

    Enum.map(entries, fn entry ->
      %{
        "key" => entry.key,
        "label" => entry.prompt,
        "value" => Map.get(configured, entry.key),
        "required" => entry.required
      }
    end)
  end

  defp access_profiles(%Plugin{tool_profiles: profiles}) do
    Enum.map(profiles, fn profile ->
      %{
        "id" => Map.get(profile, "name"),
        "label" => Map.get(profile, "display_name"),
        "write" => Map.get(profile, "required_credential_scope") == "write"
      }
    end)
  end

  # --- words ---

  defp consent("remote_mcp"), do: "Runs on the plugin's own servers, not on this Mac."
  defp consent("local_stdio"), do: "Runs on this Mac as a separate process."
  defp consent(nil), do: "Runs inside Fermix on this Mac."

  defp disclosure("remote_mcp", title) do
    "Your prompt and the content this plugin reads leave this Mac and reach #{title}."
  end

  defp disclosure(_kind, _title), do: nil

  defp sentence(:ready, %{account_label: account, workspace_label: workspace})
       when is_binary(account) and is_binary(workspace),
       do: "Connected as #{account}, bound to the #{workspace} workspace."

  defp sentence(:ready, %{account_label: account}) when is_binary(account),
    do: "Connected as #{account}."

  defp sentence(:ready, %{workspace_label: workspace}) when is_binary(workspace),
    do: "Connected, bound to the #{workspace} workspace."

  defp sentence(:ready, _facts), do: "Turned on and ready."
  defp sentence(:not_configured, _facts), do: "Installed and turned off."
  defp sentence(:needs_auth, _facts), do: "Turned on and waiting for a sign-in."
  defp sentence(:needs_secret, _facts), do: "Turned on and waiting for a token."
  defp sentence(:needs_client_config, _facts), do: "Turned on and waiting for a sign-in client."
  defp sentence(:needs_config, _facts), do: "Turned on and waiting for a setting."
  defp sentence(:needs_workspace, _facts), do: "Signed in and waiting for a workspace."
  defp sentence(:reauthorization_required, _facts), do: "The sign-in expired and needs renewing."
  defp sentence(:not_installed, _facts), do: "Not installed."
  defp sentence(:available, _facts), do: "Not installed."
  defp sentence(:connecting, _facts), do: "Connecting."

  defp sentence(:missing_host_runtime, _facts),
    do: "Turned on, but the runtime it needs is not on this Mac."

  defp sentence(:incompatible, _facts),
    do: "This build of Fermix cannot run it."

  defp sentence(:invalid_remote_config, _facts),
    do: "Turned on, but its hosted settings are not usable."

  defp sentence(:insufficient_credential_scope, _facts),
    do: "The stored token does not carry enough access."

  defp sentence(:remote_unreachable, _facts),
    do: "Turned on, but its service could not be reached."

  defp sentence(:upstream_contract_mismatch, _facts),
    do: "Turned on, but its service no longer offers what was signed."

  defp sentence(:capability_conflict, _facts),
    do: "Turned on, but one of its tools collides with another."

  defp sentence(:remote_security_blocked, _facts),
    do: "Turned on, but the connection was refused for safety."

  defp sentence(:remote_protocol_error, _facts),
    do: "Turned on, but its service answered something Fermix could not read."

  defp sentence(:error, _facts), do: "Turned on, but its state could not be read."

  # The one verb the row leads with. `nil` where the next step is not a button
  # this surface owns (a manifest setting, a host runtime, an incompatible
  # build, a connection already in flight), so the client uses its own word for
  # whatever action it drew rather than a daemon word that names something else.
  defp primary_verb(status) when status in [:not_installed, :available], do: "Install…"
  defp primary_verb(:not_configured), do: "Turn on"
  defp primary_verb(:needs_auth), do: "Sign in"
  defp primary_verb(:reauthorization_required), do: "Sign in again"
  defp primary_verb(:needs_secret), do: "Add token…"
  defp primary_verb(:insufficient_credential_scope), do: "Replace the token"
  defp primary_verb(:needs_client_config), do: "Set up the sign-in client"
  defp primary_verb(:needs_workspace), do: "Choose workspace"
  defp primary_verb(status) when status in [:connecting, :needs_config], do: nil
  defp primary_verb(status) when status in [:missing_host_runtime, :incompatible], do: nil
  defp primary_verb(_status), do: "Check again"

  defp action(nil), do: nil
  defp action(verb) when is_binary(verb), do: Map.fetch!(@actions, verb)

  defp verb_list(status, _facts) when status in [:not_installed, :available], do: ["Install…"]
  defp verb_list(:not_configured, _facts), do: ["Turn on"]

  defp verb_list(status, facts) do
    lead = List.wrap(primary_verb(status))
    disconnect = if facts.credential_present, do: ["Disconnect"], else: []

    Enum.uniq(lead ++ ["Check again"] ++ disconnect ++ ["Turn off"])
  end
end
