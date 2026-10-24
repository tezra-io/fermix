defmodule FermixChannels.Mobile.Push.FcmConfig do
  @moduledoc """
  `[fermix_channels.mobile.fcm]`: the owner's Firebase project and the service
  account that sends to it (M51 §10), a sibling of APNs' `Push.Config` with its
  own switch.

  The service account is the key file Firebase hands out, as one JSON string,
  and a secret: it reaches the config through the secret store
  (`FERMIX_FCM_SERVICE_ACCOUNT` or the OS keychain), never the TOML. Only the
  two fields that sign a token are kept, and no error repeats any of it.
  """

  @keys [:enabled, :project_id, :service_account]
  # Firebase's own rule for a project ID: 6 to 30 lowercase letters, digits and
  # hyphens, starting with a letter and not ending with a hyphen.
  @project_id_regex ~r/\A[a-z][a-z0-9-]{4,28}[a-z0-9]\z/
  @max_service_account_bytes 16_384

  @derive {Inspect, except: [:credentials]}
  defstruct enabled: false, project_id: nil, credentials: nil

  @type credentials :: %{String.t() => String.t()}

  @type t :: %__MODULE__{
          enabled: boolean(),
          project_id: String.t() | nil,
          credentials: credentials() | nil
        }

  @spec new(keyword() | map() | t()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{enabled: false} = config), do: {:ok, config}

  def new(%__MODULE__{project_id: project_id, credentials: credentials} = config) do
    with :ok <- validate_project_id(project_id),
         :ok <- validate_credentials(credentials) do
      {:ok, config}
    end
  end

  def new(values) when is_list(values) or is_map(values) do
    with {:ok, attrs} <- normalize(values),
         {:ok, enabled} <- enabled(attrs) do
      build(enabled, attrs)
    end
  end

  def new(_value), do: {:error, {:invalid_fcm_config, :root, :not_a_table}}

  defp normalize(values) when is_list(values) do
    if Keyword.keyword?(values),
      do: values |> Map.new() |> normalize(),
      else: {:error, {:invalid_fcm_config, :root, :not_a_table}}
  end

  defp normalize(values) when is_map(values) do
    Enum.reduce_while(values, {:ok, %{}}, fn {key, value}, {:ok, attrs} ->
      case known_key(key) do
        {:ok, known} -> {:cont, {:ok, Map.put(attrs, known, value)}}
        :error -> {:halt, {:error, {:invalid_fcm_config, :unknown_key, key}}}
      end
    end)
  end

  defp known_key(key) when key in @keys, do: {:ok, key}

  defp known_key(key) when is_binary(key) do
    case Enum.find(@keys, &(Atom.to_string(&1) == key)) do
      nil -> :error
      atom -> {:ok, atom}
    end
  end

  defp known_key(_key), do: :error

  # The switch is off until the table turns it on: a home with no FCM table,
  # or one that names only the service account, sends nothing through FCM.
  defp enabled(attrs) do
    case Map.get(attrs, :enabled, false) do
      value when is_boolean(value) -> {:ok, value}
      _value -> {:error, {:invalid_fcm_config, :enabled, :not_a_boolean}}
    end
  end

  defp build(false, _attrs), do: {:ok, %__MODULE__{enabled: false}}

  defp build(true, attrs) do
    with {:ok, project_id} <- fetch(attrs, :project_id),
         :ok <- validate_project_id(project_id),
         {:ok, service_account} <- fetch(attrs, :service_account),
         {:ok, credentials} <- credentials(service_account) do
      {:ok, %__MODULE__{enabled: true, project_id: project_id, credentials: credentials}}
    end
  end

  defp fetch(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:invalid_fcm_config, key, :missing}}
    end
  end

  defp validate_project_id(value) when is_binary(value) do
    if Regex.match?(@project_id_regex, value),
      do: :ok,
      else: {:error, {:invalid_fcm_config, :project_id, :not_a_firebase_project_id}}
  end

  defp validate_project_id(_value),
    do: {:error, {:invalid_fcm_config, :project_id, :not_a_firebase_project_id}}

  defp credentials(json)
       when is_binary(json) and byte_size(json) in 1..@max_service_account_bytes do
    case Jason.decode(json) do
      {:ok, %{"type" => "service_account"} = account} ->
        credentials = Map.take(account, ["client_email", "private_key"])

        with :ok <- validate_credentials(credentials), do: {:ok, credentials}

      {:ok, _other} ->
        {:error, {:invalid_fcm_config, :service_account, :not_a_service_account}}

      {:error, _reason} ->
        {:error, {:invalid_fcm_config, :service_account, :invalid_json}}
    end
  end

  defp credentials(_value),
    do: {:error, {:invalid_fcm_config, :service_account, :not_a_service_account}}

  defp validate_credentials(%{"client_email" => email, "private_key" => pem})
       when is_binary(email) and email != "" and is_binary(pem) do
    if rsa_private_key?(pem),
      do: :ok,
      else: {:error, {:invalid_fcm_config, :service_account, :invalid_private_key}}
  end

  defp validate_credentials(_credentials),
    do: {:error, {:invalid_fcm_config, :service_account, :missing_client_email_or_key}}

  # Google signs the token request with RS256, so the key is an RSA private key
  # (PKCS #8, as Firebase writes it, or PKCS #1).
  defp rsa_private_key?(pem) do
    case :public_key.pem_decode(pem) do
      [entry] -> entry |> decode_entry() |> rsa_record?()
      _entries -> false
    end
  end

  defp rsa_record?(record) when is_tuple(record) and tuple_size(record) > 0,
    do: elem(record, 0) == :RSAPrivateKey

  defp rsa_record?(_record), do: false

  defp decode_entry(entry) do
    :public_key.pem_entry_decode(entry)
  rescue
    _error in [ArgumentError, ErlangError, MatchError] -> :invalid
  end
end
