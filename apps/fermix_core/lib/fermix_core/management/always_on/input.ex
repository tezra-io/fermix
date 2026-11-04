defmodule FermixCore.Management.AlwaysOn.Input do
  @moduledoc """
  What an Always On step was given (Always On setup §3.4): `home.act`'s
  `input`, decoded where it arrived (the router, the setup page's event, the
  CLI) and passed on as this struct alone, never as the map it came in. Its
  `Inspect` withholds the token and the recovery passphrase, so a crash
  report, a log line or a page's last event names neither.

    * `token`: a provider's API token, for `paste_token`;
    * `provider`: the provider the token is for (the one provider when only
      one is offered);
    * `recovery_passphrase`: for `move_now` and `try_again`, checked against
      the recovery key set, or set when none is;
    * `type` and `location`: the size and place chosen, for `create_server`
      and `replace_server`: both, or neither for the recommendation.

  Each is text, or nil when not given.
  """

  @fields %{
    "token" => :token,
    "provider" => :provider,
    "recovery_passphrase" => :recovery_passphrase,
    "type" => :type,
    "location" => :location
  }
  @shape_sentence "Always On takes a token, a provider, a recovery passphrase, a size and a " <>
                    "place, each as text, and nothing else."
  @field_sentences %{
    "token" => "Paste the API token as text.",
    "provider" => "Choose one of the providers Fermix creates a server on.",
    "recovery_passphrase" => "Type the recovery passphrase as text.",
    "type" => "Choose one of the server types Fermix offers.",
    "location" => "Choose one of the places Fermix creates a server in."
  }

  defstruct token: nil, provider: nil, recovery_passphrase: nil, type: nil, location: nil

  @type t :: %__MODULE__{
          token: String.t() | nil,
          provider: String.t() | nil,
          recovery_passphrase: String.t() | nil,
          type: String.t() | nil,
          location: String.t() | nil
        }

  @doc "The fields `input` may hold, as the wire names them."
  @spec fields() :: [String.t()]
  def fields, do: @fields |> Map.keys() |> Enum.sort()

  @doc """
  The struct for `input` (`nil` when none was sent): each field text or
  absent. Anything else is refused on `input`, or on the field whose value
  is not text, with the sentence that says what to send; no value is ever
  named in a refusal.
  """
  @spec decode(map() | nil) :: {:ok, t()} | {:error, {:invalid_params, String.t(), String.t()}}
  def decode(nil), do: {:ok, %__MODULE__{}}

  def decode(input) when is_map(input) do
    case Enum.find(input, fn {field, value} -> not given?(field, value) end) do
      nil -> {:ok, Enum.reduce(input, %__MODULE__{}, &put/2)}
      {field, _value} -> {:error, refusal(field)}
    end
  end

  def decode(_input), do: {:error, {:invalid_params, "input", @shape_sentence}}

  defp given?(field, value) when is_map_key(@fields, field), do: is_binary(value) or is_nil(value)
  defp given?(_field, _value), do: false

  defp put({field, value}, input), do: Map.put(input, Map.fetch!(@fields, field), value)

  defp refusal(field) when is_map_key(@field_sentences, field),
    do: {:invalid_params, field, Map.fetch!(@field_sentences, field)}

  defp refusal(_field), do: {:invalid_params, "input", @shape_sentence}

  defimpl Inspect do
    import Inspect.Algebra

    # The two secrets show only whether they were given.
    def inspect(input, opts) do
      shown = [
        provider: input.provider,
        type: input.type,
        location: input.location,
        token: withheld(input.token),
        recovery_passphrase: withheld(input.recovery_passphrase)
      ]

      concat(["#FermixCore.Management.AlwaysOn.Input<", to_doc(shown, opts), ">"])
    end

    defp withheld(nil), do: nil
    defp withheld(_secret), do: :withheld
  end
end
