defmodule FermixCore.Management.Cues.SourceRow do
  @moduledoc """
  One cue source as the management socket publishes it (M60 app surface
  §3.4), and the only place its wire shape is written.

  Every field is always present, null where it does not apply. `state` is
  published for logs and support; a client draws `status_sentence` and
  switches on `primary_action` and `actions` (closed: `enable`, `disable`,
  `set_secret`, `new_token`, `get_url`), never on `state`. Edit and remove
  are always available and are the app's controls, not row verbs.

  `state` is read from the configuration first: `off` (switched off, since a
  disabled source keeps its last `cue_sources.status`), `needs_secret`
  (waiting for a secret it needs: its kind's, or one a stream's sign-in
  names), `not_running` (cues off, or on and not yet restarted), then the
  `cue_sources` status the source last wrote, `idle` before it wrote one.

  Never on the wire: a payload, an item's text or snapshot, a cursor, a
  secret's value, a webhook's address. A secret's presence is its sentinel in
  the settings file, never a keychain read.
  """

  alias FermixCore.Cues.Config, as: CuesConfig
  alias FermixCore.Management.Cues.SourceForm

  @actions ~w(enable disable set_secret new_token get_url)
  @states ~w(off needs_secret not_running idle polling connected reconnecting auth_failed
             over_budget stopped unavailable)
  @attention ~w(needs_secret auth_failed over_budget stopped unavailable)

  @type facts :: %{
          row: map() | nil,
          summary: map() | nil,
          running?: boolean(),
          cues_on?: boolean(),
          memory?: boolean(),
          window_s: pos_integer()
        }

  @doc "Every action a source row can carry."
  @spec actions() :: [String.t()]
  def actions, do: @actions

  @doc "Every state a source row can carry, in the order it is derived."
  @spec states() :: [String.t()]
  def states, do: @states

  @doc "The states a source row counts as needing the owner's attention."
  @spec attention_states() :: [String.t()]
  def attention_states, do: @attention

  @doc "The row of `source` (a resolved `Cues.Config` source) with the daemon's facts."
  @spec build(CuesConfig.source(), facts()) :: map()
  def build(source, facts) when is_map(source) and is_map(facts) do
    state = state(source, facts)
    primary = primary_action(source, state)

    %{
      "ref" => source.ref,
      "kind" => Atom.to_string(source.kind),
      "preset" => source.preset,
      "label" => label(source),
      "enabled" => source.enabled?,
      "state" => state,
      "status_sentence" => sentence(state, source, facts),
      "primary_action" => primary,
      "actions" => actions(source),
      "location" => location(source),
      "url" => source_url(source),
      "daily_budget" => source.daily_budget,
      "secrets" => secrets(source),
      "missing_secret" => source.missing_secret && Atom.to_string(source.missing_secret),
      "has_url" => source.kind == :webhook and Map.has_key?(source.secrets, :path_secret),
      "counts" => counts(facts),
      "last_good_at" => stamp(facts.row, :last_good_at),
      "last_accepted_at" => stamp(facts.row, :last_accepted_at),
      "listening" => listening(facts.summary)
    }
  end

  # --- state ---------------------------------------------------------------------

  defp state(%{enabled?: false}, _facts), do: "off"
  defp state(%{missing_secret: field}, _facts) when not is_nil(field), do: "needs_secret"
  defp state(_source, %{running?: false}), do: "not_running"
  defp state(_source, %{row: nil}), do: "idle"
  defp state(_source, %{row: %{status: status}}), do: status

  defp sentence("off", _source, _facts), do: "Off."
  defp sentence("needs_secret", %{missing_secret: :token}, _facts), do: "Waiting for its token."
  defp sentence("needs_secret", %{missing_secret: :key}, _facts), do: "Waiting for its key."
  defp sentence("needs_secret", source, _facts), do: "Waiting for its #{secret_label(source)}."

  defp sentence("not_running", _source, %{memory?: false}),
    do: "Cues keep their records in memory, which is off."

  defp sentence("not_running", _source, %{cues_on?: false}), do: "Cues are off."
  defp sentence("not_running", _source, _facts), do: "Starts when Fermix restarts."

  defp sentence("idle", %{kind: kind} = source, facts) when kind in [:webhook, :local_push],
    do: delivery_sentence(source, facts)

  defp sentence("idle", _source, _facts), do: "Waiting to start."
  defp sentence("polling", _source, _facts), do: "Checking for new items on its schedule."
  defp sentence("connected", _source, _facts), do: "Connected."
  defp sentence("reconnecting", _source, _facts), do: "Reconnecting."
  defp sentence("auth_failed", _source, _facts), do: "Its credentials were refused."

  defp sentence("over_budget", _source, _facts),
    do: "Over its daily limit. It takes new items again tomorrow."

  defp sentence("stopped", _source, _facts),
    do: "Stopped after repeated failures. Save it again or restart Fermix to try again."

  defp sentence("unavailable", _source, _facts), do: "Fermix could not reach it."
  defp sentence(_unknown, _source, _facts), do: "Running."

  defp delivery_sentence(%{kind: :webhook} = source, _facts)
       when not is_map_key(source.secrets, :path_secret),
       do: "Ready. Copy its URL into the service that sends it items."

  defp delivery_sentence(_source, %{row: %{last_accepted_at: %DateTime{}}}),
    do: "Ready for deliveries."

  defp delivery_sentence(_source, _facts), do: "Waiting for its first delivery."

  # --- actions -------------------------------------------------------------------

  defp primary_action(_source, "off"), do: "enable"
  defp primary_action(%{missing_secret: :token}, "needs_secret"), do: "new_token"
  defp primary_action(_source, "needs_secret"), do: "set_secret"

  defp primary_action(%{kind: :webhook} = source, _state)
       when not is_map_key(source.secrets, :path_secret),
       do: "get_url"

  defp primary_action(_source, _state), do: nil

  defp actions(source) do
    switch = if source.enabled?, do: "disable", else: "enable"
    secret = if typed_missing?(source), do: ["set_secret"], else: []
    [switch] ++ secret ++ kind_actions(source.kind)
  end

  defp typed_missing?(%{missing_secret: field}), do: field in [:key, :secret]

  defp kind_actions(:local_push), do: ["new_token"]
  defp kind_actions(:webhook), do: ["get_url"]
  defp kind_actions(_kind), do: []

  # --- fields --------------------------------------------------------------------

  defp label(%{preset: preset}) when is_binary(preset), do: SourceForm.preset_label(preset)
  defp label(source), do: SourceForm.kind_label(source.kind)

  defp location(%{kind: kind, url: url}) when kind in [:feed, :stream] and is_binary(url),
    do: URI.parse(url).host

  defp location(_source), do: nil

  defp source_url(%{kind: kind, url: url}) when kind in [:feed, :stream], do: url
  defp source_url(_source), do: nil

  # Every secret it needs (its kind's, or those a stream's sign-in names), a
  # webhook's address, and any other field whose sentinel the section holds,
  # each with its own presence.
  defp secrets(source) do
    needed = CuesConfig.needed_secrets(source)

    source.kind
    |> CuesConfig.secret_fields()
    |> Enum.filter(&(&1 in needed or &1 == :path_secret or Map.has_key?(source.secrets, &1)))
    |> Enum.map(fn field ->
      %{
        "field" => Atom.to_string(field),
        "label" => field_label(source, field),
        "present" => Map.has_key?(source.secrets, field)
      }
    end)
  end

  defp field_label(_source, :token), do: "Token"
  defp field_label(_source, :key), do: "API key"
  defp field_label(_source, :path_secret), do: "Address"
  defp field_label(%{kind: :webhook} = source, :secret), do: secret_label(source) |> capital()
  defp field_label(_source, :secret), do: "API secret"

  defp secret_label(%{verify: :shared_secret}), do: "shared secret"
  defp secret_label(%{kind: :webhook}), do: "signing secret"
  defp secret_label(_source), do: "secret"

  defp capital(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest

  defp counts(facts) do
    summary = facts.summary || %{}

    %{
      "window_s" => facts.window_s,
      "received" => Map.get(summary, :cues, 0),
      "routed" => Map.get(summary, :routed, 0),
      "not_routed" => max(Map.get(summary, :not_routed, 0), 0),
      "open_gaps" => Map.get(summary, :open_gaps, 0)
    }
  end

  defp listening(nil), do: []
  defp listening(summary), do: Map.get(summary, :listening, [])

  defp stamp(nil, _key), do: nil

  defp stamp(row, key) do
    case Map.get(row, key) do
      %DateTime{} = at -> DateTime.to_iso8601(at)
      _absent -> nil
    end
  end
end
