defmodule FermixCore.Realtime.Config do
  @moduledoc """
  Runtime configuration for the local Realtime voice subsystem.

  Three engines share this section: `openai_realtime` (the Realtime API,
  integrated tools), `openai_live` (the Live API, which delegates every tool
  call back to the Fermix agent) and `xai_realtime` (Grok Voice, which does the
  same through SpaceXAI). The engine is the first axis — provider, model, voice
  and the Realtime-only settings are all validated against it, so a
  cross-engine config is refused at the boundary instead of reaching a
  provider that cannot honor it.

  `api_key/1` is the one voice credential resolver: startup, readiness,
  health, doctor and call construction all read the key through it.
  """

  alias FermixCore.Config, as: CoreConfig
  alias FermixCore.Setup.ConfigStore

  # The engine axis. Each engine names the provider it bills (`@engine_providers`):
  # the same OpenAI Platform key authenticates the Realtime and the Live wire, and
  # Grok takes the SpaceXAI provider's own key.
  @valid_engines ~w(openai_realtime openai_live xai_realtime)
  @engine_providers %{
    "openai_realtime" => "openai",
    "openai_live" => "openai",
    "xai_realtime" => "xai"
  }
  # The providers block each voice provider's key lives in.
  @provider_atoms %{"openai" => :openai, "xai" => :xai}

  # The engines that hand every task to the Fermix agent through `VoiceBridge`.
  @task_engines ~w(openai_live xai_realtime)

  # The one source of truth for realtime model slugs: the API validation
  # (`validate!/1`) and the setup dropdown (`RealtimeConfig.valid_models/0`)
  # both read this. Ordered for the dropdown — the first entry is shown at the
  # top. The struct default below stays `gpt-realtime-2` so an existing config
  # is untouched; new setups pick a model in the dropdown.
  @realtime_models ~w(gpt-realtime-2.1-mini gpt-realtime-2.1 gpt-realtime-2)

  # The Live frontend ships one model. A Live model under the Realtime engine
  # (or the reverse) is a configuration error with a named remedy, never a
  # silent substitution.
  @live_models ~w(gpt-live-1)

  # Grok Voice is pinned to one model (M70 §06).
  @grok_models ~w(grok-voice-3.0)

  # The full official OpenAI Realtime voice set, ordered for the setup dropdown
  # with the recommended voices first (`marin`/`cedar` are OpenAI's picks).
  # Validation accepts ALL of them: a config upgraded from an earlier Fermix
  # (which took any voice) may carry `alloy`, `echo`, etc., and normalization
  # runs on both setup render and daemon boot/readiness — rejecting those would
  # crash the upgrade. The dropdown just recommends the curated four up top.
  @realtime_voices ~w(marin sage verse cedar alloy ash ballad coral echo shimmer)

  # Live's documented built-ins: the ten Realtime names plus twelve of its own.
  @live_voices ~w(marin cedar sage verse alloy ash ballad coral echo shimmer beacon bossa
                  cinder delta gleam meridian quartz ripple stone tempo vesper willow)

  # Grok's documented built-ins, the first one its default. Custom voices are
  # a separate, reviewed extension (M70 §06).
  @grok_voices ~w(eve ara rex sal leo)

  # Realtime reasoning-effort levels, exactly as the Realtime `session.update`
  # accepts them (note: `minimal`, no `none`/`max` — this differs from the main
  # agent's `ReasoningEffort` vocabulary, so it is validated separately here).
  # Ordered low→high for the dropdown; `low` is OpenAI's recommended default for
  # a voice agent (responsiveness plus basic reasoning).
  @valid_reasoning_efforts ~w(minimal low medium high xhigh)

  # Settings neither task engine's wire has an equivalent for. Present under
  # `openai_live` or `xai_realtime` they are refused (Rule 12 — no
  # silently-ignored settings); absent, they normalize to nil so nothing
  # downstream can read a Realtime default and put it on a task engine's payload.
  @realtime_only_keys [:reasoning_effort, :transcription_model, :max_response_output_tokens]

  # The mirror image: settings the Realtime wire has no use for, refused under
  # `openai_realtime` the same way (M56 §5).
  @live_only_keys [:conversation]

  # Where a task engine's hand-offs run (M56 §5): in the chat's own
  # conversation, or, `private`, in one of the call's own as before.
  @conversations ~w(chat private)

  # A secret reference that never resolved out of the keychain or the secrets
  # directory is a marker, not a key, and an empty value is no key at all.
  @unresolved_keys ["", "@keyring", "@file"]

  @type t :: %__MODULE__{
          enabled?: boolean(),
          provider: String.t(),
          engine: String.t(),
          model: String.t(),
          reasoning_effort: String.t() | nil,
          voice: String.t(),
          input_audio_format: String.t(),
          output_audio_format: String.t(),
          transcription_model: String.t() | nil,
          max_chunk_bytes: pos_integer(),
          max_response_output_tokens: pos_integer() | nil,
          max_session_minutes: pos_integer(),
          max_estimated_cost_cents_per_session: pos_integer(),
          screen_share?: boolean(),
          persist_transcripts?: boolean(),
          persist_audio?: boolean(),
          conversation: String.t() | nil
        }

  defstruct enabled?: false,
            provider: "openai",
            engine: "openai_realtime",
            model: "gpt-realtime-2",
            reasoning_effort: "low",
            voice: "marin",
            input_audio_format: "pcm16",
            output_audio_format: "pcm16",
            transcription_model: "whisper-1",
            max_chunk_bytes: 16_384,
            max_response_output_tokens: 4_096,
            max_session_minutes: 15,
            max_estimated_cost_cents_per_session: 100,
            # Continuous screen perception during a call (M9.5). On by default but
            # inert on its own: it needs computer-use enabled AND installed to
            # capture anything, and only ever starts because the operator asked for
            # it by voice. The flag exists as a hard off switch for a
            # privacy-sensitive machine — the ONE knob this feature adds; every
            # cadence/retention/budget bound is an internal constant.
            screen_share?: true,
            persist_transcripts?: false,
            persist_audio?: false,
            # What the file says, `nil` while nobody has set it: `conversation/1`
            # is the value in force, and only a set value is written back.
            conversation: nil

  @spec current() :: t()
  def current do
    :fermix_core
    |> Application.get_env(:realtime, [])
    |> normalize()
  end

  @spec enabled?() :: boolean()
  def enabled?, do: current().enabled?

  @doc "The supported voice engines, ordered for the setup dropdown (first = default)."
  @spec valid_engines() :: [String.t()]
  def valid_engines, do: @valid_engines

  @doc "Supported realtime model slugs, ordered for the setup dropdown (first = top)."
  @spec valid_models() :: [String.t()]
  def valid_models, do: @realtime_models

  @doc "Supported model slugs for one engine."
  @spec valid_models(String.t()) :: [String.t()]
  def valid_models("openai_realtime"), do: @realtime_models
  def valid_models("openai_live"), do: @live_models
  def valid_models("xai_realtime"), do: @grok_models

  @doc """
  Every model slug the engines ship, Realtime first, then Live, then Grok.

  The order of the one combined dropdown: the operator picks a model and the
  engine follows from it, so this list and `engine_for_model/1` are the two
  halves of that single choice.
  """
  @spec all_models() :: [String.t()]
  def all_models, do: @realtime_models ++ @live_models ++ @grok_models

  @doc """
  The engine a model slug belongs to, or `:error` for a slug no engine ships.

  The one derivation. Every door that takes a model — the app's voice pane, the
  browser pane, the setup answers — reads the engine from here rather than
  asking for it, so the pair can never be written out of agreement.
  """
  @spec engine_for_model(String.t()) :: {:ok, String.t()} | :error
  def engine_for_model(model) when is_binary(model) do
    cond do
      model in @realtime_models -> {:ok, "openai_realtime"}
      model in @live_models -> {:ok, "openai_live"}
      model in @grok_models -> {:ok, "xai_realtime"}
      true -> :error
    end
  end

  @doc "Curated realtime voices, ordered for the setup dropdown (first = default)."
  @spec valid_voices() :: [String.t()]
  def valid_voices, do: @realtime_voices

  @doc "Supported voices for one engine."
  @spec valid_voices(String.t()) :: [String.t()]
  def valid_voices("openai_realtime"), do: @realtime_voices
  def valid_voices("openai_live"), do: @live_voices
  def valid_voices("xai_realtime"), do: @grok_voices

  @doc "Realtime reasoning-effort levels, ordered low→high for the setup dropdown."
  @spec valid_reasoning_efforts() :: [String.t()]
  def valid_reasoning_efforts, do: @valid_reasoning_efforts

  @doc "The model a fresh config takes for one engine."
  @spec default_model(String.t()) :: String.t()
  def default_model("openai_realtime"), do: "gpt-realtime-2"
  def default_model("openai_live"), do: "gpt-live-1"
  def default_model("xai_realtime"), do: "grok-voice-3.0"

  @doc """
  The voice a fresh config, and an engine switch that strands a voice, lands on.

  `marin` opens both OpenAI catalogs; Grok's catalog opens with `eve`.
  """
  @spec default_voice(String.t()) :: String.t()
  def default_voice(engine) when engine in ["openai_realtime", "openai_live"], do: "marin"
  def default_voice("xai_realtime"), do: "eve"

  @doc ~S(The provider an engine dials and bills: `"openai"` or `"xai"`.)
  @spec provider_for_engine(String.t()) :: String.t()
  def provider_for_engine(engine) when is_map_key(@engine_providers, engine),
    do: Map.fetch!(@engine_providers, engine)

  @doc "True when this config selects the OpenAI Live engine (its wire, not Grok's)."
  @spec live?(t()) :: boolean()
  def live?(%__MODULE__{engine: engine}), do: engine == "openai_live"

  @doc """
  True when this config selects a task engine: one that hands every task to
  the Fermix agent through `VoiceBridge` (`openai_live` and `xai_realtime`).
  """
  @spec hands_off_tasks?(t()) :: boolean()
  def hands_off_tasks?(%__MODULE__{engine: engine}), do: engine in @task_engines

  @doc """
  The voice provider's API key, or the provider that has none.

  The one resolver every reader of the voice key goes through. OpenAI's engines
  read the `openai` provider key; Grok reads the `xai` provider's `api_key`
  slot, never a SpaceXAI sign-in and never the voice-notes override, because
  the realtime endpoint documents API-key authentication only. An empty value
  and an unresolved secret reference are no key.
  """
  @spec api_key(t()) :: {:ok, String.t()} | {:error, {:missing_api_key, String.t()}}
  def api_key(%__MODULE__{provider: provider}) when is_map_key(@provider_atoms, provider) do
    case CoreConfig.provider_api_key(Map.fetch!(@provider_atoms, provider)) do
      {:ok, key} when key in @unresolved_keys -> {:error, {:missing_api_key, provider}}
      {:ok, key} -> {:ok, key}
      {:error, :not_configured} -> {:error, {:missing_api_key, provider}}
    end
  end

  @doc "Whether `api_key/1` resolves a key for this config."
  @spec api_key_present?(t()) :: boolean()
  def api_key_present?(%__MODULE__{} = config), do: match?({:ok, _key}, api_key(config))

  @doc "The values `conversation` takes, in the order a pane offers them."
  @spec conversations() :: [String.t()]
  def conversations, do: @conversations

  @doc """
  Where a task engine's hand-offs run (M56 §5): `"chat"`, the chat's own
  conversation, unless the owner chose `"private"`. Task engines only: the
  Realtime engine has no hand-offs, and asking it is a defect.
  """
  @spec conversation(t()) :: String.t()
  def conversation(%__MODULE__{engine: engine, conversation: nil}) when engine in @task_engines,
    do: "chat"

  def conversation(%__MODULE__{engine: engine, conversation: conversation})
      when engine in @task_engines,
      do: conversation

  @spec normalize(keyword() | map() | nil) :: t()
  def normalize(nil), do: normalize([])

  def normalize(config) when is_list(config) or is_map(config) do
    reject_removed_key!(config, :activation)
    reject_removed_key!(config, :turn_detection)
    reject_removed_key!(config, :max_buffer_chunks)
    reject_removed_key!(config, :idle_timeout_ms)
    reject_removed_key!(config, :max_input_audio_seconds_per_session)

    reject_removed_key!(
      config,
      :tool_policy,
      "realtime now uses the same capability surface as the main agent; remove the line from [fermix_core.realtime]. Sandbox mode + command profile cover voice scope."
    )

    reject_removed_key!(
      config,
      :allow_network_tools,
      "realtime now uses the same capability surface as the main agent; remove the line from [fermix_core.realtime]. Restrict network tools at the capability layer if you need them off."
    )

    engine = engine(config)
    reject_realtime_only_keys!(config, engine)
    reject_live_only_keys!(config, engine)

    realtime = %__MODULE__{
      enabled?: bool(config, :enabled, false),
      provider: string(config, :provider, provider_for_engine(engine)),
      engine: engine,
      model: string(config, :model, default_model(engine)),
      reasoning_effort: reasoning_effort(config, engine),
      voice: string(config, :voice, default_voice(engine)),
      input_audio_format: string(config, :input_audio_format, "pcm16"),
      output_audio_format: string(config, :output_audio_format, "pcm16"),
      transcription_model: transcription_model(config, engine),
      max_chunk_bytes: positive_int(config, :max_chunk_bytes, 16_384),
      max_response_output_tokens: max_response_output_tokens(config, engine),
      max_session_minutes: positive_int(config, :max_session_minutes, 15),
      max_estimated_cost_cents_per_session:
        positive_int(config, :max_estimated_cost_cents_per_session, 100),
      screen_share?: screen_share(config, engine),
      persist_transcripts?: bool(config, :persist_transcripts, false),
      persist_audio?: bool(config, :persist_audio, false),
      conversation: conversation_setting(config, engine)
    }

    validate!(realtime)
  end

  @spec to_keyword(t()) :: keyword()
  def to_keyword(%__MODULE__{} = config) do
    [
      enabled: config.enabled?,
      provider: config.provider,
      engine: config.engine,
      model: config.model
    ] ++
      reasoning_effort_keyword(config) ++
      [
        voice: config.voice,
        max_session_minutes: config.max_session_minutes,
        max_estimated_cost_cents_per_session: config.max_estimated_cost_cents_per_session,
        screen_share: config.screen_share?,
        persist_transcripts: config.persist_transcripts?
      ] ++ conversation_keyword(config)
  end

  @spec socket_path() :: String.t()
  def socket_path do
    ConfigStore.fermix_home()
    |> socket_path()
  end

  @spec socket_path(String.t()) :: String.t()
  def socket_path(fermix_home) when is_binary(fermix_home) do
    Path.join(fermix_home, "realtime.sock")
  end

  # `to_keyword/1` is the inverse of `normalize/1` on the persist path, so it
  # must never render a key the parser refuses: under a task engine,
  # `reasoning_effort` is exactly such a key.
  defp reasoning_effort_keyword(%__MODULE__{engine: "openai_realtime", reasoning_effort: effort}),
    do: [reasoning_effort: effort]

  defp reasoning_effort_keyword(%__MODULE__{}), do: []

  # Written only once someone set it, so the file keeps "never chosen" apart
  # from a chosen default (M56 D2).
  defp conversation_keyword(%__MODULE__{conversation: nil}), do: []

  defp conversation_keyword(%__MODULE__{conversation: conversation}),
    do: [conversation: conversation]

  defp engine(config) do
    engine = string(config, :engine, "openai_realtime")
    assert_one_of!(engine, @valid_engines, :engine)
    engine
  end

  defp reject_realtime_only_keys!(_config, "openai_realtime"), do: :ok

  defp reject_realtime_only_keys!(config, engine) do
    Enum.each(@realtime_only_keys, fn key ->
      unless is_nil(lookup(config, key)) do
        raise ArgumentError, realtime_only_message(key, engine)
      end
    end)
  end

  defp realtime_only_message(key, "openai_live") do
    "realtime.#{key} is a Realtime-only setting; remove it from " <>
      ~s([fermix_core.realtime] or set engine = "openai_realtime")
  end

  defp realtime_only_message(key, engine) do
    "realtime.#{key} is a Realtime-only setting, not supported by engine #{engine}; " <>
      ~s(remove it from [fermix_core.realtime] or set engine = "openai_realtime")
  end

  defp reject_live_only_keys!(_config, engine) when engine in @task_engines, do: :ok

  defp reject_live_only_keys!(config, "openai_realtime") do
    Enum.each(@live_only_keys, fn key ->
      unless is_nil(lookup(config, key)) do
        raise ArgumentError,
              "realtime.#{key} is a Live-only setting; remove it from " <>
                ~s([fermix_core.realtime] or set engine = "openai_live")
      end
    end)
  end

  defp conversation_setting(_config, "openai_realtime"), do: nil

  defp conversation_setting(config, _task_engine) do
    case string(config, :conversation, nil) do
      nil -> nil
      conversation -> one_of!(conversation, @conversations, :conversation)
    end
  end

  # Grok receives audio and permitted text only (M70 §07), so continuous screen
  # perception is off under it, and a hand-set `true` is refused rather than
  # silently ignored.
  defp screen_share(config, "xai_realtime") do
    if bool(config, :screen_share, false) do
      raise ArgumentError,
            "realtime.screen_share is not supported by engine xai_realtime; " <>
              "set it to false or pick another model"
    end

    false
  end

  defp screen_share(config, _openai_engine), do: bool(config, :screen_share, true)

  defp reasoning_effort(config, "openai_realtime"),
    do: string(config, :reasoning_effort, "low")

  defp reasoning_effort(_config, _task_engine), do: nil

  defp transcription_model(config, "openai_realtime"),
    do: string(config, :transcription_model, "whisper-1")

  defp transcription_model(_config, _task_engine), do: nil

  defp max_response_output_tokens(config, "openai_realtime"),
    do: positive_int(config, :max_response_output_tokens, 4_096)

  defp max_response_output_tokens(_config, _task_engine), do: nil

  defp validate!(%__MODULE__{} = config) do
    assert_model!(config.model, config.engine)
    assert_provider!(config)
    assert_reasoning_effort!(config.reasoning_effort, config.engine)
    assert_one_of!(config.voice, valid_voices(config.engine), :voice)
    assert_equal!(config.input_audio_format, "pcm16", :input_audio_format)
    assert_equal!(config.output_audio_format, "pcm16", :output_audio_format)

    if config.persist_audio? do
      raise ArgumentError, "realtime.persist_audio is not supported in V1"
    end

    config
  end

  defp assert_model!(model, "openai_realtime") do
    case engine_for_model(model) do
      {:ok, "openai_realtime"} ->
        :ok

      {:ok, engine} ->
        raise ArgumentError,
              ~s(realtime.model #{model} requires engine = "#{engine}"; set ) <>
                ~s([fermix_core.realtime] engine = "#{engine}" or pick a Realtime model)

      :error ->
        assert_one_of!(model, @realtime_models, :model)
    end
  end

  defp assert_model!(model, engine) do
    models = valid_models(engine)

    unless model in models do
      raise ArgumentError,
            "realtime.model must be #{Enum.join(models, ", ")} " <>
              ~s(when engine = "#{engine}", got: #{inspect(model)})
    end
  end

  # The provider follows from the engine, so a hand-written one that disagrees
  # is two choices that cannot both hold: neither wins, and all three are named.
  defp assert_provider!(%__MODULE__{provider: provider, engine: engine, model: model}) do
    expected = provider_for_engine(engine)

    if provider != expected do
      raise ArgumentError,
            ~s(realtime.provider "#{provider}" contradicts engine #{engine} and model #{model}, ) <>
              ~s(which take provider "#{expected}"; remove provider from [fermix_core.realtime] ) <>
              "or pick a model that provider ships"
    end
  end

  defp assert_reasoning_effort!(effort, "openai_realtime"),
    do: assert_one_of!(effort, @valid_reasoning_efforts, :reasoning_effort)

  defp assert_reasoning_effort!(nil, _task_engine), do: :ok

  defp reject_removed_key!(config, key, message \\ nil) do
    unless is_nil(lookup(config, key)) do
      detail = message || "realtime uses one full-duplex server_vad mode"
      raise ArgumentError, "realtime.#{key} was removed; #{detail}"
    end
  end

  defp assert_equal!(actual, expected, key) do
    if actual != expected do
      raise ArgumentError,
            "realtime.#{key} must be #{inspect(expected)}, got: #{inspect(actual)}"
    end
  end

  defp assert_one_of!(actual, valid, key) do
    unless actual in valid do
      raise ArgumentError,
            "realtime.#{key} must be one of #{Enum.join(valid, ", ")}, got: #{inspect(actual)}"
    end
  end

  defp one_of!(actual, valid, key) do
    assert_one_of!(actual, valid, key)
    actual
  end

  defp bool(config, key, default) do
    case lookup(config, key) do
      nil -> default
      value when is_boolean(value) -> value
      "true" -> true
      "false" -> false
      value -> raise ArgumentError, "realtime.#{key} must be a boolean, got: #{inspect(value)}"
    end
  end

  defp string(config, key, default) do
    case lookup(config, key) do
      nil ->
        default

      value when is_atom(value) ->
        Atom.to_string(value)

      value when is_binary(value) and value != "" ->
        value

      value ->
        raise ArgumentError, "realtime.#{key} must be a non-empty string, got: #{inspect(value)}"
    end
  end

  defp positive_int(config, key, default) do
    case lookup(config, key) do
      nil ->
        default

      value when is_integer(value) and value > 0 ->
        value

      value ->
        raise ArgumentError, "realtime.#{key} must be a positive integer, got: #{inspect(value)}"
    end
  end

  defp lookup(config, key) when is_list(config) do
    case Keyword.fetch(config, key) do
      {:ok, value} -> value
      :error -> keyword_string_value(config, Atom.to_string(key))
    end
  end

  defp lookup(config, key) when is_map(config) do
    Map.get(config, key) || Map.get(config, Atom.to_string(key))
  end

  defp keyword_string_value(config, string_key) do
    Enum.find_value(config, fn
      {^string_key, value} -> value
      _other -> nil
    end)
  end
end
