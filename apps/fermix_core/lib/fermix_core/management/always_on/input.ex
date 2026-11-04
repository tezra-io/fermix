defmodule FermixCore.Management.AlwaysOn.Input do
  @moduledoc """
  What an Always On step was given (Always On setup §3.4): `home.act`'s
  `input`, decoded where it arrived (the router, the setup page's event, the
  CLI) and passed on as this struct alone, never as the map it came in. Its
  `Inspect` withholds the recovery passphrase, so a crash report, a log line
  or a page's last event never names it.

    * `recovery_passphrase`: for `move_now` and `try_again`, checked against
      the recovery key set, or set when none is; for `restore_here`, the one
      that opens the copy restored.

  It is text, or nil when not given.
  """

  @fields %{"recovery_passphrase" => :recovery_passphrase}
  @shape_sentence "Always On takes a recovery passphrase, as text, and nothing else."
  @field_sentences %{"recovery_passphrase" => "Type the recovery passphrase as text."}

  defstruct recovery_passphrase: nil

  @type t :: %__MODULE__{recovery_passphrase: String.t() | nil}

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

    # The secret shows only whether it was given.
    def inspect(input, opts) do
      shown = [recovery_passphrase: withheld(input.recovery_passphrase)]
      concat(["#FermixCore.Management.AlwaysOn.Input<", to_doc(shown, opts), ">"])
    end

    defp withheld(nil), do: nil
    defp withheld(_secret), do: :withheld
  end
end
