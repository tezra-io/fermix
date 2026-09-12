defmodule FermixCore.Meetings.Config do
  @moduledoc """
  Reader for the `[fermix_core.meetings]` configuration block.

  `load/0` returns the whole block as one snapshot. The Session resolves it once
  when a meeting is requested and never re-reads it, so an operator edit made
  while a meeting runs cannot change the posture of that meeting mid-flight.

  Two values are resolved here rather than by the callers:

  - `announce_message` — a blank configured value means the built-in template
    (design D8), filled with `bot_name` and the owner's name from
    `[fermix_core.personalization] user_name` (falling back to a neutral
    "the operator" when personalization has no name yet). The snapshot always
    carries the exact line the notetaker will post, so no caller re-derives it.
  - the RTMS credential set — `rtms_configured?/0` treats the blank and
    unresolved-`@keyring` sentinels as absent (the `Transcription.Support`
    credential rule), so a half-configured Zoom lane refuses at the join gate
    instead of failing deep inside the handshake.
  """

  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.Wizard

  @default_bot_name "Fermix Notetaker"
  @default_owner_name "the operator"

  # Owner-approved default announcement (design D8). The notetaker posts this
  # once in the meeting chat on admit; it never speaks.
  @announce_template "👋 {bot_name} here — {owner_name}'s AI notetaker. " <>
                       "Taking text notes only (no audio kept); the host can remove me anytime."

  # A configured value equal to one of these carries no credential: "" is unset
  # and "@keyring" is the marker for a secret that never resolved out of the
  # keyring. Neither may reach a signature or a bearer token.
  @sentinels ["", "@keyring"]

  # The Server-to-Server OAuth secret mints tokens for the whole Zoom account,
  # and this struct lives in the state of the Session and RtmsSource GenServers —
  # one crash report's `State: %Meetings.Config{...}` would otherwise print it in
  # plaintext into the daemon log (the `Auth.OAuthProvider` precedent).
  @derive {Inspect, except: [:zoom_client_secret]}
  defstruct enabled: false,
            bot_name: @default_bot_name,
            announce: true,
            announce_message: "",
            transcription_backend: "",
            retain_audio: false,
            zoom_account_id: "",
            zoom_client_id: "",
            zoom_client_secret: "",
            zoom_ws_subscription_id: ""

  @type t :: %__MODULE__{
          enabled: boolean(),
          bot_name: String.t(),
          announce: boolean(),
          announce_message: String.t(),
          transcription_backend: String.t(),
          retain_audio: boolean(),
          zoom_account_id: String.t(),
          zoom_client_id: String.t(),
          zoom_client_secret: String.t(),
          zoom_ws_subscription_id: String.t()
        }

  @doc "The notetaker's shipped name, published so a settings row shows the same default."
  @spec default_bot_name() :: String.t()
  def default_bot_name, do: @default_bot_name

  @doc "Snapshots the whole `[fermix_core.meetings]` block, with `announce_message` resolved."
  @spec load() :: t()
  def load do
    config = Application.get_env(:fermix_core, :meetings, [])
    bot_name = string(config, :bot_name, @default_bot_name)

    %__MODULE__{
      enabled: boolean(config, :enabled, false),
      bot_name: bot_name,
      announce: boolean(config, :announce, true),
      announce_message: announce_message(string(config, :announce_message, ""), bot_name),
      transcription_backend: string(config, :transcription_backend, ""),
      retain_audio: boolean(config, :retain_audio, false),
      zoom_account_id: string(config, :zoom_account_id, ""),
      zoom_client_id: string(config, :zoom_client_id, ""),
      zoom_client_secret: string(config, :zoom_client_secret, ""),
      zoom_ws_subscription_id: string(config, :zoom_ws_subscription_id, "")
    }
  end

  @doc """
  Persists a partial change to `[fermix_core.meetings]`.

  The one writer for this block, and it commits through the wizard's shared
  write tail rather than saving and applying on its own: that tail is where the
  external-change refusal executes and where the persisted baseline is
  re-recorded, and a second save-plus-apply beside it would revert an outside
  edit silently and then leave every later write refusing against a file this
  daemon had just written.

  Values are validated where every other value of this block is validated, by
  the normalizer `save_snapshot/2` runs, so a bad one raises `ArgumentError`
  with its own sentence instead of landing.
  """
  @spec save(keyword()) :: {:ok, map()} | {:error, term()}
  def save(changes) when is_list(changes) do
    snapshot = ConfigStore.current_snapshot()
    core = Map.get(snapshot, :fermix_core, [])
    meetings = core |> Keyword.get(:meetings, []) |> Keyword.merge(changes)

    snapshot
    |> Map.put(:fermix_core, Keyword.put(core, :meetings, meetings))
    |> Wizard.commit_snapshot()
  end

  @doc "Whether the meetings subsystem is enabled (the config toggle alone)."
  @spec enabled?() :: boolean()
  def enabled?, do: load().enabled

  @doc "Whether the Zoom RTMS lane has a complete, resolved credential set."
  @spec rtms_configured?() :: boolean()
  def rtms_configured?, do: rtms_configured?(load())

  @spec rtms_configured?(t()) :: boolean()
  def rtms_configured?(%__MODULE__{} = config) do
    present?(config.zoom_account_id) and present?(config.zoom_client_id) and
      present?(config.zoom_client_secret) and present?(config.zoom_ws_subscription_id)
  end

  defp announce_message("", bot_name) do
    @announce_template
    |> String.replace("{bot_name}", bot_name)
    |> String.replace("{owner_name}", owner_name())
  end

  defp announce_message(configured, _bot_name), do: configured

  defp owner_name do
    :fermix_core
    |> Application.get_env(:personalization, [])
    |> Keyword.get(:user_name)
    |> trimmed()
    |> case do
      "" -> @default_owner_name
      name -> name
    end
  end

  defp string(config, key, default) do
    case config |> Keyword.get(key) |> trimmed() do
      "" -> default
      value -> value
    end
  end

  defp boolean(config, key, default) do
    case Keyword.get(config, key) do
      value when is_boolean(value) -> value
      _other -> default
    end
  end

  defp trimmed(value) when is_binary(value), do: String.trim(value)
  defp trimmed(_value), do: ""

  defp present?(value), do: value not in @sentinels
end
