defmodule FermixCore.Realtime.Config do
  @moduledoc """
  Runtime configuration for the local Realtime voice subsystem.

  Two engines share this section and the one OpenAI Platform key:
  `openai_realtime` (the Realtime API, integrated tools) and `openai_live`
  (the Live API, which delegates every tool call back to the Fermix agent).
  The engine is the first axis — model, voice and the Realtime-only settings
  are all validated against it, so a cross-engine config is refused at the
  boundary instead of reaching a provider that cannot honor it.
  """

  alias FermixCore.Setup.ConfigStore

  # The engine axis. `provider` stays `"openai"` for both: the same Platform key
  # authenticates the Realtime and the Live wire.
  @valid_engines ~w(openai_realtime openai_live)

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

  # Realtime reasoning-effort levels, exactly as the Realtime `session.update`
  # accepts them (note: `minimal`, no `none`/`max` — this differs from the main
  # agent's `ReasoningEffort` vocabulary, so it is validated separately here).
  # Ordered low→high for the dropdown; `low` is OpenAI's recommended default for
  # a voice agent (responsiveness plus basic reasoning).
  @valid_reasoning_efforts ~w(minimal low medium high xhigh)

  # Settings the Live wire has no equivalent for. Present under `openai_live`
  # they are refused (Rule 12 — no silently-ignored settings); absent, they
  # normalize to nil so nothing downstream can read a Realtime default and put
  # it on a Live payload.
  @realtime_only_keys [:reasoning_effort, :transcription_model, :max_response_output_tokens]

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
          persist_audio?: boolean()
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
            persist_audio?: false

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

  @doc """
  Every model slug both engines ship, Realtime first, then Live.

  The order of the one combined dropdown: the operator picks a model and the
  engine follows from it, so this list and `engine_for_model/1` are the two
  halves of that single choice.
  """
  @spec all_models() :: [String.t()]
  def all_models, do: @realtime_models ++ @live_models

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

  @doc "Realtime reasoning-effort levels, ordered low→high for the setup dropdown."
  @spec valid_reasoning_efforts() :: [String.t()]
  def valid_reasoning_efforts, do: @valid_reasoning_efforts

  @doc "The model a fresh config takes for one engine."
  @spec default_model(String.t()) :: String.t()
  def default_model("openai_realtime"), do: "gpt-realtime-2"
  def default_model("openai_live"), do: "gpt-live-1"

  @doc "True when this config selects the OpenAI Live engine."
  @spec live?(t()) :: boolean()
  def live?(%__MODULE__{engine: engine}), do: engine == "openai_live"

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

    realtime = %__MODULE__{
      enabled?: bool(config, :enabled, false),
      provider: string(config, :provider, "openai"),
      engine: engine,
      model: string(config, :model, default_model(engine)),
      reasoning_effort: reasoning_effort(config, engine),
      voice: string(config, :voice, "marin"),
      input_audio_format: string(config, :input_audio_format, "pcm16"),
      output_audio_format: string(config, :output_audio_format, "pcm16"),
      transcription_model: transcription_model(config, engine),
      max_chunk_bytes: positive_int(config, :max_chunk_bytes, 16_384),
      max_response_output_tokens: max_response_output_tokens(config, engine),
      max_session_minutes: positive_int(config, :max_session_minutes, 15),
      max_estimated_cost_cents_per_session:
        positive_int(config, :max_estimated_cost_cents_per_session, 100),
      screen_share?: bool(config, :screen_share, true),
      persist_transcripts?: bool(config, :persist_transcripts, false),
      persist_audio?: bool(config, :persist_audio, false)
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
      ]
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
  # must never render a key the parser refuses: under Live, `reasoning_effort`
  # is exactly such a key.
  defp reasoning_effort_keyword(%__MODULE__{engine: "openai_live"}), do: []

  defp reasoning_effort_keyword(%__MODULE__{reasoning_effort: effort}),
    do: [reasoning_effort: effort]

  defp engine(config) do
    engine = string(config, :engine, "openai_realtime")
    assert_one_of!(engine, @valid_engines, :engine)
    engine
  end

  defp reject_realtime_only_keys!(_config, "openai_realtime"), do: :ok

  defp reject_realtime_only_keys!(config, "openai_live") do
    Enum.each(@realtime_only_keys, fn key ->
      unless is_nil(lookup(config, key)) do
        raise ArgumentError,
              "realtime.#{key} is a Realtime-only setting; remove it from " <>
                ~s([fermix_core.realtime] or set engine = "openai_realtime")
      end
    end)
  end

  defp reasoning_effort(_config, "openai_live"), do: nil

  defp reasoning_effort(config, "openai_realtime"),
    do: string(config, :reasoning_effort, "low")

  defp transcription_model(_config, "openai_live"), do: nil

  defp transcription_model(config, "openai_realtime"),
    do: string(config, :transcription_model, "whisper-1")

  defp max_response_output_tokens(_config, "openai_live"), do: nil

  defp max_response_output_tokens(config, "openai_realtime"),
    do: positive_int(config, :max_response_output_tokens, 4_096)

  defp validate!(%__MODULE__{} = config) do
    assert_equal!(config.provider, "openai", :provider)
    assert_model!(config.model, config.engine)
    assert_reasoning_effort!(config.reasoning_effort, config.engine)
    assert_one_of!(config.voice, valid_voices(config.engine), :voice)
    assert_equal!(config.input_audio_format, "pcm16", :input_audio_format)
    assert_equal!(config.output_audio_format, "pcm16", :output_audio_format)

    if config.persist_audio? do
      raise ArgumentError, "realtime.persist_audio is not supported in V1"
    end

    config
  end

  defp assert_model!(model, "openai_live") do
    unless model in @live_models do
      raise ArgumentError,
            "realtime.model must be #{Enum.join(@live_models, ", ")} " <>
              ~s(when engine = "openai_live", got: #{inspect(model)})
    end
  end

  defp assert_model!(model, "openai_realtime") do
    if model in @live_models do
      raise ArgumentError,
            ~s(realtime.model #{model} requires engine = "openai_live"; set ) <>
              ~s([fermix_core.realtime] engine = "openai_live" or pick a Realtime model)
    end

    assert_one_of!(model, @realtime_models, :model)
  end

  defp assert_reasoning_effort!(nil, "openai_live"), do: :ok

  defp assert_reasoning_effort!(effort, "openai_realtime"),
    do: assert_one_of!(effort, @valid_reasoning_efforts, :reasoning_effort)

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
