defmodule FermixCore.PhoneCalls.Config do
  @moduledoc """
  `[fermix_core.phone_calls]`, the owner's phone-call settings (M94 §12,
  decision D5): whether Fermix may place calls, the voice that speaks on them,
  the owner's caller number, and the username and password of the owner's
  Telnyx trunk connection. Everything else a call needs is a constant: the
  carrier, the trunk address and the model are `CarrierProfile`'s, every bound
  and retention period is `Limits`'.

  The section is the home's, in `config.toml`, never a computer's. It is its
  own: nothing here reads `[fermix_core.realtime]`, so the voice the owner talks
  to and the voice that calls a business are chosen apart. The phone voice is
  validated against the engine's one catalog of GPT-Live voices
  (`Realtime.Config.valid_voices/1`), never a copy of it.

  `sip_password` is a secret (`Setup.SecretPaths`, `:phone_calls_sip_password`):
  the file holds its store's sentinel, and application environment the value
  resolved out of that store at boot, or the sentinel when the store could not
  be read. `sip_password/1` and `openai_api_key/0` are the two credential reads,
  shared by readiness and by the call's I/O boundary. The phone engine reuses
  the OpenAI provider's Platform key; a SpaceXAI key never stands in for it.

  The settings file's loader runs `normalize/1` (which raises naming the
  section, each key and why) and the persist path writes `to_keyword/1`, its
  inverse, which writes only what is set: the default section renders nothing.
  `validate/1` is the same check returning every problem, for a caller that
  answers rather than raises.
  """

  alias FermixCore.Config, as: CoreConfig
  alias FermixCore.PhoneCalls.CarrierProfile
  alias FermixCore.PhoneCalls.OpenAILive
  alias FermixCore.PhoneCalls.UsNumbers
  alias FermixCore.Realtime.Config, as: RealtimeConfig
  alias FermixCore.Setup.SecretWriter

  @section "config.toml [fermix_core.phone_calls]"
  @config_keys [:enabled, :voice, :caller_number, :sip_username, :sip_password]
  @key_names Enum.map(@config_keys, &Atom.to_string/1)
  @default_voice RealtimeConfig.default_voice(CarrierProfile.voice_engine())

  # The provider's digest bounds (OpenAI's create reference): a username of at
  # most 256 bytes, a password of at most 4096, neither carrying CR, LF or NUL.

  @derive {Inspect, except: [:sip_password]}
  defstruct enabled: false,
            voice: @default_voice,
            caller_number: nil,
            sip_username: nil,
            sip_password: nil

  @type t :: %__MODULE__{
          enabled: boolean(),
          voice: String.t(),
          caller_number: String.t() | nil,
          sip_username: String.t() | nil,
          sip_password: String.t() | nil
        }

  @type reason ::
          :not_boolean
          | :not_a_string
          | :unknown_voice
          | :too_long
          | :control_characters
          | :invalid_utf8
          | :unknown_key
          | UsNumbers.reason()

  @type problem :: {atom() | String.t(), reason()}

  @doc "The section's keys, in the order `to_keyword/1` writes them."
  @spec config_keys() :: [atom(), ...]
  def config_keys, do: @config_keys

  @doc "The voices a phone call may speak in: the GPT-Live catalog."
  @spec voices() :: [String.t(), ...]
  def voices, do: RealtimeConfig.valid_voices(CarrierProfile.voice_engine())

  @doc "The voice an unset `voice` is."
  @spec default_voice() :: String.t()
  def default_voice, do: @default_voice

  @doc "The running section, from application environment."
  @spec get() :: t()
  def get, do: :fermix_core |> Application.get_env(:phone_calls, []) |> normalize()

  @doc "Whether the owner turned phone calls on. Not whether they are ready (`Readiness`)."
  @spec enabled?() :: boolean()
  def enabled?, do: get().enabled

  @doc "The section from a raw block, or every problem with it."
  @spec validate(nil | map() | keyword()) :: {:ok, t()} | {:error, [problem(), ...]}
  def validate(nil), do: validate([])

  def validate(raw) when is_map(raw) or is_list(raw) do
    entries = Enum.map(raw, fn {key, value} -> {key_name(key), value} end)
    unknown = for {key, _value} <- entries, key not in @key_names, do: {key, :unknown_key}

    {fields, problems} =
      Enum.reduce(@config_keys, {%{}, []}, fn key, {fields, problems} ->
        case field(key, lookup(entries, key)) do
          {:ok, value} -> {Map.put(fields, key, value), problems}
          {:error, reason} -> {fields, [{key, reason} | problems]}
        end
      end)

    case Enum.reverse(problems) ++ unknown do
      [] -> {:ok, struct!(__MODULE__, fields)}
      all -> {:error, all}
    end
  end

  @doc "The section from a raw block. Raises naming the section, each key and why."
  @spec normalize(nil | map() | keyword()) :: t()
  def normalize(raw) when is_nil(raw) or is_map(raw) or is_list(raw) do
    case validate(raw) do
      {:ok, config} -> config
      {:error, problems} -> raise ArgumentError, message(problems)
    end
  end

  @doc """
  The inverse of `normalize/1`, as the persist path writes it: each key that is
  set, in `config_keys/0` order. `enabled` is written only when on and `voice`
  only when not the default, so a section nobody set renders nothing and an
  unchosen voice follows the default.
  """
  @spec to_keyword(t()) :: keyword()
  def to_keyword(%__MODULE__{} = config) do
    [
      enabled: if(config.enabled, do: true),
      voice: if(config.voice != @default_voice, do: config.voice),
      caller_number: config.caller_number,
      sip_username: config.sip_username,
      sip_password: config.sip_password
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  @doc """
  The credentials a call's I/O needs, resolved now: the OpenAI Platform key
  and the trunk connection's username and password, never kept. The first
  one missing is named in `PhoneCalls.Readiness`'s words, the one vocabulary
  for what a call lacks.
  """
  @spec credentials(t()) ::
          {:ok, %{api_key: String.t(), sip_username: String.t(), sip_password: String.t()}}
          | {:error, :openai_api_key_missing | :sip_username_missing | :sip_password_missing}
  def credentials(%__MODULE__{} = config) do
    with {:ok, api_key} <- openai_api_key(),
         {:ok, username} <- sip_username(config),
         {:ok, password} <- sip_password(config) do
      {:ok, %{api_key: api_key, sip_username: username, sip_password: password}}
    end
  end

  defp sip_username(%__MODULE__{sip_username: username})
       when is_binary(username) and username != "",
       do: {:ok, username}

  defp sip_username(%__MODULE__{}), do: {:error, :sip_username_missing}

  @doc "The trunk password, or `:sip_password_missing` when none is stored or it did not resolve."
  @spec sip_password(t()) :: {:ok, String.t()} | {:error, :sip_password_missing}
  def sip_password(%__MODULE__{sip_password: password}) do
    if is_binary(password) and password != "" and not SecretWriter.sentinel?(password),
      do: {:ok, password},
      else: {:error, :sip_password_missing}
  end

  @doc """
  The OpenAI Platform key the phone engine authenticates with: the `openai`
  provider's, the existing `:openai_api_key` secret. An unresolved sentinel is
  no key.
  """
  @spec openai_api_key() :: {:ok, String.t()} | {:error, :openai_api_key_missing}
  def openai_api_key do
    case CoreConfig.provider_api_key(:openai) do
      {:ok, key} -> if SecretWriter.sentinel?(key), do: missing_key(), else: {:ok, key}
      {:error, :not_configured} -> missing_key()
    end
  end

  defp missing_key, do: {:error, :openai_api_key_missing}

  defp field(:enabled, nil), do: {:ok, false}
  defp field(:enabled, value) when is_boolean(value), do: {:ok, value}
  defp field(:enabled, _value), do: {:error, :not_boolean}

  defp field(:voice, nil), do: {:ok, @default_voice}
  defp field(:voice, value) when not is_binary(value), do: {:error, :not_a_string}
  defp field(:voice, value), do: if(value in voices(), do: {:ok, value}, else: unknown_voice())

  defp field(:caller_number, value), do: optional(value, &caller_number/1)
  defp field(:sip_username, value), do: optional(value, &username/1)
  defp field(:sip_password, value), do: optional(value, &password/1)

  defp unknown_voice, do: {:error, :unknown_voice}

  # A blank optional value is unset, so a form that clears a field clears it.
  defp optional(nil, _check), do: {:ok, nil}
  defp optional(value, _check) when not is_binary(value), do: {:error, :not_a_string}

  defp optional(value, check) do
    cond do
      not String.valid?(value) -> {:error, :invalid_utf8}
      String.trim(value) == "" -> {:ok, nil}
      true -> check.(value)
    end
  end

  defp caller_number(value) do
    number = String.trim(value)

    case UsNumbers.classify(number) do
      :ok -> {:ok, number}
      {:error, reason} -> {:error, reason}
    end
  end

  defp username(value), do: credential(:username, String.trim(value))

  # Never trimmed: a password is the bytes the owner gave.
  defp password(value), do: credential(:password, value)

  # The call's own create request's rule, so a saved credential is one the
  # call can send (`OpenAILive.check_credential/2`).
  defp credential(kind, value) do
    case OpenAILive.check_credential(kind, value) do
      :ok -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  defp key_name(key) when is_atom(key), do: Atom.to_string(key)
  defp key_name(key) when is_binary(key), do: key
  defp key_name(key), do: inspect(key)

  defp lookup(entries, key) do
    case List.keyfind(entries, Atom.to_string(key), 0) do
      {_name, value} -> value
      nil -> nil
    end
  end

  defp message(problems) do
    "#{@section} is invalid: " <> Enum.map_join(problems, "; ", &problem_text/1) <> "."
  end

  defp problem_text({key, reason}), do: "#{key} #{describe(reason)}"

  defp describe(:not_boolean), do: "must be true or false"
  defp describe(:not_a_string), do: "must be a string"
  defp describe(:unknown_voice), do: "must be one of #{Enum.join(voices(), ", ")}"
  defp describe(:too_long), do: "is too long"
  defp describe(:control_characters), do: "must not contain a line break or NUL"
  defp describe(:invalid_utf8), do: "must be UTF-8 text"
  defp describe(:not_e164), do: "must be an E.164 number, a + and its digits"
  defp describe(:not_nanp_number), do: "is not a number the North American plan assigns"
  defp describe(:destination_not_us), do: "must be a number in a US state or DC"

  defp describe(:emergency_or_special_number),
    do: "must not be an emergency, service, toll-free or premium number"

  defp describe(:unknown_key),
    do: "is not a setting here; the section takes #{Enum.join(@key_names, ", ")}"
end
