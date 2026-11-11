defmodule FermixCore.ComputerHistory.MachineService do
  @moduledoc """
  `history.apply` (M97 §8.5): what a computer does when its home tells it of a
  purge or a pause from chat. Each interval deletes this computer's raw events
  stamped inside it and fences any that arrive later, a pause that has not
  ended also pauses recording here until it does, and the highest interval
  applied is answered, which the home records so it never sends it again
  (`ComputerHistory.Delivery`). The store is the one under the invocation's
  home (`Spool.apply_at/3`); a computer that records nothing has nothing to
  delete and answers the same.

  Narrowing may come from anywhere (§7.2), so this is gated by the computer's
  master switch alone, never by its `history` offer: a computer whose history
  is off still deletes what a purge names.
  """

  @behaviour FermixCore.Computers.Capability

  alias FermixCore.ComputerHistory.Spool

  @max_intervals 256

  @impl true
  def id, do: :history

  @impl true
  def offer, do: nil

  @impl true
  def ops, do: ["apply"]

  @impl true
  def effect?("apply"), do: true

  @impl true
  def long_lived?("apply"), do: false

  @impl true
  def validate("apply", %{"intervals" => intervals} = args)
      when map_size(args) == 1 and is_list(intervals) and intervals != [] and
             length(intervals) <= @max_intervals do
    if Enum.all?(intervals, &interval?/1),
      do: :ok,
      else: {:error, "Each interval needs its id, its times and its kind."}
  end

  def validate("apply", _args),
    do: {:error, "Apply takes the intervals to apply, at most #{@max_intervals}."}

  defp interval?(%{"id" => id, "from_ts" => from, "to_ts" => to, "kind" => kind} = interval)
       when is_integer(id) and id > 0 and is_integer(from) and is_integer(to) and from <= to and
              kind in ["purge", "pause"],
       do: is_integer(Map.get(interval, "issued_at", from))

  defp interval?(_other), do: false

  @impl true
  def bounds("apply"), do: %{result_bytes: 1_024, part_bytes: 0}

  @impl true
  def admit("apply", _args, _context), do: :ok

  @impl true
  def run("apply", %{"intervals" => intervals}, nil, %{home: home, clock: clock}) do
    read = Enum.map(intervals, &read/1)

    case Spool.apply_at(Spool.path(home), read, clock.()) do
      :ok -> {:ok, %{"applied" => read |> Enum.map(& &1.id) |> Enum.max()}, nil}
      {:error, reason} -> {:failed, "This computer could not apply it: #{inspect(reason)}"}
    end
  end

  def run("apply", _args, _part, _context), do: {:failed, "Apply takes no file."}

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
end
