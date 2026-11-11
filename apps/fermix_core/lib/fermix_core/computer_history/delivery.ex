defmodule FermixCore.ComputerHistory.Delivery do
  @moduledoc """
  How a purge or a pause from chat reaches each computer's raw events (M97
  §8.5): the home sends every connected computer the purge and pause intervals
  it has not yet applied (`history.apply`, `ComputerHistory.MachineService`),
  oldest first, and records the highest one each applied. Asked right after a
  purge or pause from chat, and on the home's scheduler tick, which is how a
  computer that was away gets them once it is back.

  Until a computer has applied an interval, the home refuses any sitting of its
  that touches it (`ComputerHistory.Submission`), so a purged window never gains
  a note in the meantime; delivery is what makes the computer delete its own
  raw events, never what keeps the home clean.

  Options: `:repo`, `:computers` (the home's computers, `Computers.list/0`),
  `:call` (how a computer is asked, `Computers.call/6`'s shape, a test's seam)
  and `:call_opts` (`Computers.call/6`'s options).
  """

  require Logger

  alias FermixCore.ComputerHistory.MachineService
  alias FermixCore.Computers
  alias FermixCore.Computers.Outcome
  alias FermixCore.Memory.Repo

  @max_intervals 256

  @typedoc "What one delivery did: computers that applied, that are away, that failed."
  @type result :: %{applied: [String.t()], away: [String.t()], failed: [String.t()]}

  @doc "Send each connected computer what it has not applied; the names by outcome."
  @spec deliver(keyword()) :: result()
  def deliver(opts \\ []) when is_list(opts) do
    repo = Keyword.get(opts, :repo, Repo)
    computers = Keyword.get_lazy(opts, :computers, &Computers.list/0)

    with {:ok, rows} <- Repo.computer_history_home(:computer_rows, [], server: repo) do
      marks = Map.new(rows, &{&1.computer_id, &1.delivered_mark})

      Enum.reduce(computers, %{applied: [], away: [], failed: []}, fn computer, acc ->
        outcome = deliver_one(computer, Map.get(marks, computer.device_id, 0), repo, opts)
        Map.update!(acc, outcome, &[computer.name | &1])
      end)
    else
      {:error, reason} ->
        Logger.error(
          "computer_history delivery could not read the home's marks: #{inspect(reason)}"
        )

        %{applied: [], away: [], failed: Enum.map(computers, & &1.name)}
    end
  end

  defp deliver_one(computer, mark, repo, opts) do
    case Repo.computer_history_home(:intervals_after, [computer.device_id, mark, @max_intervals],
           server: repo
         ) do
      {:ok, []} -> :applied
      {:ok, intervals} -> send_to(computer, intervals, repo, opts)
      {:error, reason} -> failed(computer, reason)
    end
  end

  defp send_to(%{connected: false}, _intervals, _repo, _opts), do: :away

  defp send_to(computer, intervals, repo, opts) do
    call = Keyword.get(opts, :call, &Computers.call/6)
    args = %{"intervals" => Enum.map(intervals, &wire/1)}

    case call.(
           computer,
           MachineService,
           "apply",
           args,
           run_context(),
           Keyword.get(opts, :call_opts, [])
         ) do
      {:ok, %Outcome{result: %{"applied" => applied}}} when is_integer(applied) ->
        record(computer, applied, repo)

      {:ok, outcome} ->
        failed(computer, {:answer, outcome.result})

      {:error, %Outcome{} = outcome} ->
        failed(computer, {outcome.status, outcome.refusal})
    end
  end

  defp record(computer, applied, repo) do
    case Repo.computer_history_home(:record_delivered, [computer.device_id, applied],
           server: repo
         ) do
      :ok -> :applied
      {:error, reason} -> failed(computer, reason)
    end
  end

  defp failed(computer, reason) do
    Logger.warning(
      "computer_history: #{computer.name} was not told of a purge or pause: #{inspect(reason)}"
    )

    :failed
  end

  defp wire(interval), do: Map.new(interval, fn {key, value} -> {Atom.to_string(key), value} end)

  # The home's own background work, not a turn: its request carries a session id
  # of its own, which correlates it in each machine's trace.
  defp run_context do
    %{session_id: "computer_history_delivery:#{System.system_time(:millisecond)}"}
  end
end
