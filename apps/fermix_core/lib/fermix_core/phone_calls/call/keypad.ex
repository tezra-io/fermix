defmodule FermixCore.PhoneCalls.Call.Keypad do
  @moduledoc """
  One keypad press sequence of a phone call (M94 §08: "one event character
  ... wait for its acknowledgement before the next key"). Pure: the worker
  (`PhoneCalls.Call`) counts each key on the ledger, sends it, arms its
  acknowledgement timer and answers the caller; this module holds which turn
  asked, what is left, what was confirmed and the key in flight.

  A key whose acknowledgement does not come is unconfirmed, never sent
  again: the sequence stops, and the key in flight and every key after it
  come back unconfirmed with why it stopped. The sequence belongs to the turn
  that asked (`turn`), and ends with it.
  """

  alias FermixCore.PhoneCalls.OpenAILive.Controls

  @enforce_keys [:from, :turn]
  defstruct [:from, :turn, pending: [], confirmed: "", current: nil]

  @type stopped ::
          nil
          | :ack_timeout
          | :refused
          | :not_sent
          | :send_unknown
          | :invalid_key
          | :turn_ended
          | :call_ending
          | {:cap_reached, :dtmf_keys}

  @type t :: %__MODULE__{
          from: GenServer.from(),
          turn: String.t(),
          pending: [String.t()],
          confirmed: String.t(),
          current: {String.t(), String.t()} | nil
        }

  @doc "A sequence of `keys` for the caller `from`, asked by the turn `turn`."
  @spec new(GenServer.from(), String.t(), String.t()) :: t()
  def new(from, turn, keys) when is_binary(turn) and is_binary(keys) and keys != "",
    do: %__MODULE__{from: from, turn: turn, pending: String.graphemes(keys)}

  @doc "The next key to press, or `:done` once every key is confirmed."
  @spec next(t()) :: {:press, String.t()} | :done
  def next(%__MODULE__{pending: [key | _rest], current: nil}), do: {:press, key}
  def next(%__MODULE__{pending: []}), do: :done

  @doc "`key` went out as the client event `event_id`; its acknowledgement is awaited."
  @spec pressing(t(), String.t(), String.t()) :: t()
  def pressing(%__MODULE__{pending: [key | _rest], current: nil} = keypad, key, event_id)
      when is_binary(event_id),
      do: %{keypad | current: {key, event_id}}

  @doc """
  What a sideband event says of the key in flight: `{:confirmed, keypad}`
  with it confirmed, `:refused` when the vendor refused it, `:unrelated` for
  any other event (a late acknowledgement of a key given up on included).
  """
  @spec acknowledge(t(), term()) :: {:confirmed, t()} | :refused | :unrelated
  def acknowledge(%__MODULE__{current: {key, event_id}} = keypad, event) do
    case Controls.dtmf_outcome(event_id, event) do
      :acknowledged -> {:confirmed, confirmed(keypad, key)}
      {:refused, _error} -> :refused
      :unrelated -> :unrelated
    end
  end

  def acknowledge(%__MODULE__{current: nil}, _event), do: :unrelated

  @doc "Why a key the sideband would not take stopped the sequence."
  @spec send_stopped(term()) :: stopped()
  def send_stopped({:not_sent, _reason}), do: :not_sent
  def send_stopped({:unknown, _reason}), do: :send_unknown
  def send_stopped(:invalid_dtmf_key), do: :invalid_key

  @doc "Whether the turn `id` asked for this sequence."
  @spec asked_by?(t(), String.t()) :: boolean()
  def asked_by?(%__MODULE__{turn: turn}, id), do: turn == id

  @doc """
  The caller and its one answer: what was confirmed, what was not, and why
  the sequence stopped (`nil` when every key was confirmed). A cap reached
  before any key is the caller's refusal, not a partial sequence.
  """
  @spec answer(t(), stopped()) :: {GenServer.from(), {:ok, map()} | {:error, term()}}
  def answer(%__MODULE__{from: from, confirmed: ""}, {:cap_reached, :dtmf_keys} = cap),
    do: {from, {:error, cap}}

  def answer(%__MODULE__{from: from} = keypad, stopped) do
    {from,
     {:ok,
      %{confirmed: keypad.confirmed, unconfirmed: Enum.join(keypad.pending), stopped: stopped}}}
  end

  @doc "The sequence as a status prints it: counts, never the keys."
  @spec printable(t() | nil) :: map() | nil
  def printable(nil), do: nil

  def printable(%__MODULE__{} = keypad) do
    %{
      turn: keypad.turn,
      pending: length(keypad.pending),
      confirmed: String.length(keypad.confirmed),
      in_flight: not is_nil(keypad.current)
    }
  end

  defp confirmed(%{pending: [key | rest]} = keypad, key),
    do: %{keypad | pending: rest, confirmed: keypad.confirmed <> key, current: nil}
end
