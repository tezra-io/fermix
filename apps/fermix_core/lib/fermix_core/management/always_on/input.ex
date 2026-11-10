defmodule FermixCore.Management.AlwaysOn.Input do
  @moduledoc """
  What an Always On step was given (Always On setup §3.4): `home.act`'s
  `input`, decoded where it arrived (the router, the setup page's event, the
  CLI) and passed on as this struct alone, never as the map it came in. Its
  `Inspect` withholds the recovery passphrase, so a crash report, a log line
  or a page's last event never names it.

    * `recovery_passphrase`: for `move_now` and `try_again`, checked against
      the recovery key set, or set when none is; for `restore_here`, the one
      that opens the copy restored. Text, or nil when not given.
    * `keep_offers` (M97 §7.3): for `move_now` and `try_again`, what this
      computer keeps on for its server after the move, the lines of the
      review's block left ticked; for `review_offers`, what it keeps on after
      the owner's review. A list of offer ids, or nil when not given (the
      block as the engine proposed it).
  """

  @fields %{"recovery_passphrase" => :recovery_passphrase, "keep_offers" => :keep_offers}
  @shape_sentence "Always On takes a recovery passphrase, as text, and the offers to keep on, " <>
                    "as a list, and nothing else."
  @field_sentences %{
    "recovery_passphrase" => "Type the recovery passphrase as text.",
    "keep_offers" => "Send the offers to keep on as a list of their ids."
  }
  @max_offers 32

  defstruct recovery_passphrase: nil, keep_offers: nil

  @type t :: %__MODULE__{recovery_passphrase: String.t() | nil, keep_offers: [String.t()] | nil}

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

  defp given?("keep_offers", value) when is_list(value),
    do: length(value) <= @max_offers and Enum.all?(value, &is_binary/1)

  defp given?(field, value) when is_map_key(@fields, field),
    do: is_nil(value) or (field == "recovery_passphrase" and is_binary(value))

  defp given?(_field, _value), do: false

  defp put({field, value}, input), do: Map.put(input, Map.fetch!(@fields, field), value)

  defp refusal(field) when is_map_key(@field_sentences, field),
    do: {:invalid_params, field, Map.fetch!(@field_sentences, field)}

  defp refusal(_field), do: {:invalid_params, "input", @shape_sentence}

  defimpl Inspect do
    import Inspect.Algebra

    # The secret shows only whether it was given.
    def inspect(input, opts) do
      shown = [
        recovery_passphrase: withheld(input.recovery_passphrase),
        keep_offers: input.keep_offers
      ]

      concat(["#FermixCore.Management.AlwaysOn.Input<", to_doc(shown, opts), ">"])
    end

    defp withheld(nil), do: nil
    defp withheld(_secret), do: :withheld
  end
end
