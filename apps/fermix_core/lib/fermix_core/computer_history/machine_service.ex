defmodule FermixCore.ComputerHistory.MachineService do
  @moduledoc """
  What a computer does when its home tells it of the owner's narrowing from
  chat (M97 §7.2, §8.5):

  - `history.apply`: a purge or a pause, with the identity of the home store
    they belong to (`home`, `ComputerHistory.home_identity/1`). Each interval
    deletes this computer's raw events stamped inside it and fences any that
    arrive later, a pause that has not ended also pauses recording here until
    it does, and the store's mark is answered: the highest interval of that
    home store this computer has applied, every one below it included, which
    the home records so it never sends them again
    (`ComputerHistory.Delivery`). A mark under another home store (one this
    computer left, or this home's before a restore) is replaced, never
    raised. The store is the one under the
    invocation's home (`Spool.apply_at/3`); a computer that keeps no store
    applied nothing and answers 0, so a store it opens later is sent every
    interval from the first.
  - `history.off`: `/history off` naming this computer. Its history goes off
    as its own switch turns it off (`ComputerHistory.switch_off/1`): the
    recorder stops and stays off, and the `history` offer, which follows the
    recorder (M97 D27), goes off with it, so nothing more is recorded or
    sent. Only someone at this computer turns it on again.

  Narrowing may come from anywhere (§7.2), so this is gated by the computer's
  master switch alone, never by its `history` offer: a computer whose history
  is off still deletes what a purge names.
  """

  @behaviour FermixCore.Computers.Capability

  alias FermixCore.ComputerHistory
  alias FermixCore.ComputerHistory.Spool
  alias FermixCore.Computers.Offers.History, as: HistoryOffer

  @max_intervals 256
  @max_home_bytes 128

  @impl true
  def id, do: :history

  @impl true
  def offer, do: nil

  @impl true
  def ops, do: ["apply", "off"]

  @impl true
  def effect?(op) when op in ["apply", "off"], do: true

  @impl true
  def long_lived?(op) when op in ["apply", "off"], do: false

  @impl true
  def validate("apply", %{"intervals" => intervals, "home" => home} = args)
      when map_size(args) == 2 and is_list(intervals) and intervals != [] and
             length(intervals) <= @max_intervals and is_binary(home) and home != "" and
             byte_size(home) <= @max_home_bytes do
    if Enum.all?(intervals, &interval?/1),
      do: :ok,
      else: {:error, "Each interval needs its id, its times and its kind."}
  end

  def validate("apply", _args),
    do:
      {:error,
       "Apply takes the home's history store and the intervals to apply, at most " <>
         "#{@max_intervals}."}

  def validate("off", args) when args == %{}, do: :ok
  def validate("off", _args), do: {:error, "Off takes nothing."}

  defp interval?(%{"id" => id, "from_ts" => from, "to_ts" => to, "kind" => kind} = interval)
       when is_integer(id) and id > 0 and is_integer(from) and is_integer(to) and from <= to and
              kind in ["purge", "pause"],
       do: is_integer(Map.get(interval, "issued_at", from))

  defp interval?(_other), do: false

  @impl true
  def bounds(op) when op in ["apply", "off"], do: %{result_bytes: 1_024, part_bytes: 0}

  @impl true
  def admit(op, _args, _context) when op in ["apply", "off"], do: :ok

  @impl true
  def run("apply", %{"intervals" => intervals, "home" => store}, nil, %{home: home, clock: clock}) do
    case Spool.apply_at(Spool.path(home), store, Enum.map(intervals, &read/1), clock.()) do
      {:ok, mark} -> {:ok, %{"applied" => mark}, nil}
      {:error, reason} -> {:failed, "This computer could not apply it: #{inspect(reason)}"}
    end
  end

  def run("off", %{}, nil, %{home: home}) do
    case ComputerHistory.switch_off(home: home) do
      %{stop: :ok, save: :ok} ->
        {:ok, %{"off" => true}, nil}

      outcome ->
        {:failed, "This computer could not switch its history off: #{off_failure(outcome)}"}
    end
  end

  def run(_op, _args, _part, _context), do: {:failed, "This takes no file."}

  defp off_failure(outcome) do
    outcome
    |> Enum.reject(fn {_step, result} -> result == :ok end)
    |> Enum.map_join(", ", fn {step, {:error, reason}} -> "#{step}: #{inspect(reason)}" end)
  end

  defp read(%{"id" => id, "from_ts" => from, "to_ts" => to, "kind" => kind} = interval),
    do: %{
      id: id,
      from_ts: from,
      to_ts: to,
      issued_at: Map.get(interval, "issued_at", from),
      kind: kind
    }

  @impl true
  def target("apply", %{"intervals" => intervals}) when is_list(intervals),
    do: "#{length(intervals)} purge or pause interval(s)"

  def target("apply", _args), do: "purge or pause"
  def target("off", _args), do: "computer history"

  # The owner's words for it and each op, which this computer's record of
  # what its server did here shows (`computer.journal.list`).
  @impl true
  def label, do: HistoryOffer.label()

  @impl true
  def op_label("apply"), do: "apply a purge or pause from chat"
  def op_label("off"), do: "switch history off from chat"
end
