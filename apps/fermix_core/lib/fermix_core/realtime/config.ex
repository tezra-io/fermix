defmodule FermixCore.Realtime.Config do
  @moduledoc """
  Runtime configuration for the local Realtime voice subsystem.
  """

  alias FermixCore.Setup.ConfigStore

  @valid_models ~w(gpt-realtime-2)
  @valid_tool_policy ~w(read_only broad)

  @type t :: %__MODULE__{
          enabled?: boolean(),
          provider: String.t(),
          model: String.t(),
          voice: String.t(),
          input_audio_format: String.t(),
          output_audio_format: String.t(),
          transcription_model: String.t(),
          max_chunk_bytes: pos_integer(),
          max_response_output_tokens: pos_integer(),
          max_session_minutes: pos_integer(),
          max_estimated_cost_cents_per_session: pos_integer(),
          tool_policy: String.t(),
          allow_network_tools?: boolean(),
          persist_transcripts?: boolean(),
          persist_audio?: boolean()
        }

  defstruct enabled?: false,
            provider: "openai",
            model: "gpt-realtime-2",
            voice: "marin",
            input_audio_format: "pcm16",
            output_audio_format: "pcm16",
            transcription_model: "whisper-1",
            max_chunk_bytes: 16_384,
            max_response_output_tokens: 4_096,
            max_session_minutes: 15,
            max_estimated_cost_cents_per_session: 100,
            tool_policy: "read_only",
            allow_network_tools?: false,
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

  @spec normalize(keyword() | map() | nil) :: t()
  def normalize(nil), do: normalize([])

  def normalize(config) when is_list(config) or is_map(config) do
    reject_removed_key!(config, :activation)
    reject_removed_key!(config, :turn_detection)
    reject_removed_key!(config, :max_buffer_chunks)
    reject_removed_key!(config, :idle_timeout_ms)
    reject_removed_key!(config, :max_input_audio_seconds_per_session)

    realtime = %__MODULE__{
      enabled?: bool(config, :enabled, false),
      provider: string(config, :provider, "openai"),
      model: string(config, :model, "gpt-realtime-2"),
      voice: string(config, :voice, "marin"),
      input_audio_format: string(config, :input_audio_format, "pcm16"),
      output_audio_format: string(config, :output_audio_format, "pcm16"),
      transcription_model: string(config, :transcription_model, "whisper-1"),
      max_chunk_bytes: positive_int(config, :max_chunk_bytes, 16_384),
      max_response_output_tokens: positive_int(config, :max_response_output_tokens, 4_096),
      max_session_minutes: positive_int(config, :max_session_minutes, 15),
      max_estimated_cost_cents_per_session:
        positive_int(config, :max_estimated_cost_cents_per_session, 100),
      tool_policy: string(config, :tool_policy, "read_only"),
      allow_network_tools?: bool(config, :allow_network_tools, false),
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
      model: config.model,
      voice: config.voice,
      max_session_minutes: config.max_session_minutes,
      max_estimated_cost_cents_per_session: config.max_estimated_cost_cents_per_session,
      tool_policy: config.tool_policy,
      allow_network_tools: config.allow_network_tools?,
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

  defp validate!(%__MODULE__{} = config) do
    assert_equal!(config.provider, "openai", :provider)
    assert_one_of!(config.model, @valid_models, :model)
    assert_equal!(config.input_audio_format, "pcm16", :input_audio_format)
    assert_equal!(config.output_audio_format, "pcm16", :output_audio_format)
    assert_one_of!(config.tool_policy, @valid_tool_policy, :tool_policy)

    if config.persist_audio? do
      raise ArgumentError, "realtime.persist_audio is not supported in V1"
    end

    config
  end

  defp reject_removed_key!(config, key) do
    unless is_nil(lookup(config, key)) do
      raise ArgumentError,
            "realtime.#{key} was removed; realtime uses one full-duplex server_vad mode"
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
