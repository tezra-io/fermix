defmodule FermixChannels.Mobile.Push.Config do
  @moduledoc false

  @p256_oid {1, 2, 840, 10_045, 3, 1, 7}
  @default_timeout_ms 5_000
  @max_timeout_ms 30_000
  @keys [:enabled, :team_id, :key_id, :key, :topic, :environment, :timeout_ms]

  @derive {Inspect, except: [:key]}
  defstruct enabled: false,
            team_id: nil,
            key_id: nil,
            key: nil,
            topic: nil,
            environment: nil,
            timeout_ms: @default_timeout_ms

  @type environment :: :development | :production

  @type t :: %__MODULE__{
          enabled: boolean(),
          team_id: String.t() | nil,
          key_id: String.t() | nil,
          key: String.t() | nil,
          topic: String.t() | nil,
          environment: environment() | nil,
          timeout_ms: pos_integer()
        }

  @spec new(keyword() | map() | t()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = config), do: validate_struct(config)

  def new(values) when is_list(values) or is_map(values) do
    with {:ok, attrs} <- normalize(values),
         :ok <- reject_unknown(attrs),
         {:ok, enabled} <- required_boolean(attrs, :enabled) do
      build(enabled, attrs)
    end
  end

  def new(value), do: {:error, {:invalid_push_config, :root, value}}

  @spec pigeon_mode(t()) :: :dev | :prod
  def pigeon_mode(%__MODULE__{environment: :development}), do: :dev
  def pigeon_mode(%__MODULE__{environment: :production}), do: :prod

  @spec max_timeout_ms() :: pos_integer()
  def max_timeout_ms, do: @max_timeout_ms

  defp normalize(values) when is_list(values) do
    if Keyword.keyword?(values) do
      {:ok, Map.new(values)}
    else
      {:error, {:invalid_push_config, :root, :not_keyword}}
    end
  end

  defp normalize(values) when is_map(values) do
    Enum.reduce_while(values, {:ok, %{}}, fn {key, value}, {:ok, attrs} ->
      case normalize_key(key) do
        {:ok, normalized} -> {:cont, {:ok, Map.put(attrs, normalized, value)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp normalize_key(key) when key in @keys, do: {:ok, key}

  defp normalize_key(key) when is_binary(key) do
    case Enum.find(@keys, &(Atom.to_string(&1) == key)) do
      nil -> {:error, {:invalid_push_config, :unknown_key, key}}
      atom -> {:ok, atom}
    end
  end

  defp normalize_key(key), do: {:error, {:invalid_push_config, :unknown_key, key}}

  defp reject_unknown(attrs) do
    case Map.keys(attrs) -- @keys do
      [] -> :ok
      unknown -> {:error, {:invalid_push_config, :unknown_keys, Enum.sort(unknown)}}
    end
  end

  defp required_boolean(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      :error -> {:error, {:invalid_push_config, key, :missing}}
      {:ok, value} -> {:error, {:invalid_push_config, key, value}}
    end
  end

  defp build(false, _attrs), do: {:ok, %__MODULE__{enabled: false}}

  defp build(true, attrs) do
    with {:ok, team_id} <- required_text(attrs, :team_id),
         {:ok, key_id} <- required_text(attrs, :key_id),
         {:ok, key} <- required_private_key(attrs),
         {:ok, topic} <- required_text(attrs, :topic),
         {:ok, environment} <- required_environment(attrs),
         {:ok, timeout_ms} <- timeout(attrs) do
      {:ok,
       %__MODULE__{
         enabled: true,
         team_id: team_id,
         key_id: key_id,
         key: key,
         topic: topic,
         environment: environment,
         timeout_ms: timeout_ms
       }}
    end
  end

  defp required_text(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) and byte_size(value) in 1..255 ->
        if String.valid?(value),
          do: {:ok, value},
          else: {:error, {:invalid_push_config, key, :invalid_utf8}}

      :error ->
        {:error, {:invalid_push_config, key, :missing}}

      {:ok, value} ->
        {:error, {:invalid_push_config, key, value}}
    end
  end

  defp required_private_key(attrs) do
    case Map.fetch(attrs, :key) do
      {:ok, value} when is_binary(value) -> validate_private_key(value)
      :error -> {:error, {:invalid_push_config, :key, :missing}}
      {:ok, _value} -> {:error, {:invalid_push_config, :key, :invalid}}
    end
  end

  defp validate_private_key(pem) do
    case :public_key.pem_decode(pem) do
      [entry] -> validate_decoded_key(:public_key.pem_entry_decode(entry), pem)
      _entries -> {:error, {:invalid_push_config, :key, :invalid_pem}}
    end
  rescue
    error in [ArgumentError, ErlangError] ->
      {:error, {:invalid_push_config, :key, {:invalid_pem, Exception.message(error)}}}
  end

  defp validate_decoded_key(
         {:ECPrivateKey, _version, _private, {:namedCurve, @p256_oid}, _public, _attrs},
         pem
       ),
       do: {:ok, pem}

  defp validate_decoded_key(_decoded, _pem),
    do: {:error, {:invalid_push_config, :key, :not_p256_private_key}}

  defp required_environment(attrs) do
    case Map.fetch(attrs, :environment) do
      {:ok, value} when value in [:development, "development"] -> {:ok, :development}
      {:ok, value} when value in [:production, "production"] -> {:ok, :production}
      :error -> {:error, {:invalid_push_config, :environment, :missing}}
      {:ok, value} -> {:error, {:invalid_push_config, :environment, value}}
    end
  end

  defp timeout(attrs) do
    case Map.get(attrs, :timeout_ms, @default_timeout_ms) do
      value when is_integer(value) and value > 0 and value <= @max_timeout_ms -> {:ok, value}
      value -> {:error, {:invalid_push_config, :timeout_ms, value}}
    end
  end

  defp validate_struct(%__MODULE__{enabled: false} = config), do: {:ok, config}

  defp validate_struct(%__MODULE__{} = config) do
    config
    |> Map.from_struct()
    |> new()
  end
end
