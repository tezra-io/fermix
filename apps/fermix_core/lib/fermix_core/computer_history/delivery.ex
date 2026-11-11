defmodule FermixCore.ComputerHistory.Delivery do
  @moduledoc """
  How the owner's narrowing from chat reaches each machine (M97 §7.2, §8.5).

  - **A purge or a pause.** The home sends every connected computer the purge
    and pause intervals it has not yet applied (`history.apply`,
    `ComputerHistory.MachineService`), oldest first, and records the mark
    each answers. A computer that keeps no store answers that it applied
    nothing, and is sent them again later, from the first. This machine, on a
    home that records itself, applies its own (`apply_here/1`): every
    interval above its mark, in order, before its mark moves, so the mark
    never steps over one it has not applied (history_submit's HS-2), whether
    the interval came from this command, from a second command running beside
    it, or from one whose own apply failed.
  - **Off for a named computer** (`switch_off/2`). The home records the
    request, and the computer switches its history off when told
    (`history.off`); once it says it did, the request is done. Until then the
    home takes nothing from it (`ComputerHistory.contributors/1`).

  `deliver/1` runs right after a purge or pause from chat and on the home
  scheduler's tick, which is how a computer that was away is told once it is
  back. Until a computer has applied an interval, the home refuses any sitting
  of its that touches it (`ComputerHistory.Submission`), so a purged window
  never gains a note in the meantime; delivery is what makes the computer
  delete its own raw events, never what keeps the home clean.

  **A mark belongs to one home store.** Interval ids start again wherever the
  home's store does (a restore, a server rebuilt from nothing, another home),
  so each mark is kept with that store's identity
  (`ComputerHistory.home_identity/1`): every request names it, and a machine
  whose mark names another store applies from the first interval again.

  Options: `:repo`, `:home` (the home folder, for its identity), `:spool`
  (this machine's store), `:now`, `:computers` (the
  home's computers, `Computers.list/0`), `:call` (how a computer is asked,
  `Computers.call/6`'s shape, a test's seam) and `:call_opts`
  (`Computers.call/6`'s options).
  """

  require Logger

  alias FermixCore.ComputerHistory
  alias FermixCore.ComputerHistory.MachineService
  alias FermixCore.ComputerHistory.Spool
  alias FermixCore.Computers
  alias FermixCore.Computers.Computer
  alias FermixCore.Computers.Outcome
  alias FermixCore.Memory.Repo

  @max_intervals 256

  @typedoc """
  What one delivery did, by computer name: applied every interval sent,
  away, failed, or keeps no store and so applied nothing.
  """
  @type result :: %{
          applied: [String.t()],
          away: [String.t()],
          failed: [String.t()],
          no_store: [String.t()]
        }

  @doc """
  This machine's own intervals (a home that records itself): every one of the
  home's purge and pause intervals above this machine's mark, for every
  machine or for this one, at most #{@max_intervals} oldest first, applied in
  order and the mark moved last (`Spool.apply_intervals/4`); from the first
  where its mark names another home store. Any past the
  bound wait for the next call, the scheduler's tick at the latest, and the
  home refuses this machine's sittings inside them meanwhile. Answers how
  many raw events the intervals deleted here.
  """
  @spec apply_here(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def apply_here(opts) when is_list(opts) do
    repo = Keyword.get(opts, :repo, Repo)
    spool = [server: Keyword.fetch!(opts, :spool)]
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    with {:ok, home} <- ComputerHistory.home_identity(Keyword.take(opts, [:repo, :home])),
         {:ok, link} <- Spool.link(spool),
         {:ok, intervals} <-
           Repo.computer_history_home(:intervals_after, ["", mark(link, home), @max_intervals],
             server: repo
           ),
         {:ok, before} <- Spool.count_events(spool),
         :ok <- Spool.apply_intervals(intervals, home, now, spool),
         {:ok, left} <- Spool.count_events(spool) do
      {:ok, max(before - left, 0)}
    end
  end

  # A mark under another home store is no mark under this one.
  defp mark(%{home: home, home_mark: mark}, home), do: mark
  defp mark(_link, _home), do: 0

  @doc """
  Send each connected computer what it has not applied, and any off it owes;
  names by outcome. Every request names the home store its intervals belong
  to (`ComputerHistory.home_identity/1`), so the mark each answers is one
  under this store; one that cannot be named sends nothing and is `failed`.
  """
  @spec deliver(keyword()) :: result()
  def deliver(opts \\ []) when is_list(opts) do
    repo = Keyword.get(opts, :repo, Repo)
    computers = Keyword.get_lazy(opts, :computers, &Computers.list/0)
    empty = %{applied: [], away: [], failed: [], no_store: []}

    with {:ok, home} <- ComputerHistory.home_identity(Keyword.take(opts, [:repo, :home])),
         {:ok, rows} <- Repo.computer_history_home(:computer_rows, [], server: repo) do
      rows = Map.new(rows, &{&1.computer_id, &1})

      Enum.reduce(computers, empty, fn computer, acc ->
        row = Map.get(rows, computer.device_id, %{delivered_mark: 0, off_requested_at: nil})
        _off = owed_off(computer, row.off_requested_at, repo, opts)
        outcome = deliver_one(computer, {home, row.delivered_mark}, repo, opts)
        Map.update!(acc, outcome, &[computer.name | &1])
      end)
    else
      {:error, reason} ->
        Logger.error(
          "computer_history delivery could not read the home's marks: #{inspect(reason)}"
        )

        %{empty | failed: Enum.map(computers, & &1.name)}
    end
  end

  defp deliver_one(computer, {home, mark}, repo, opts) do
    case Repo.computer_history_home(:intervals_after, [computer.device_id, mark, @max_intervals],
           server: repo
         ) do
      {:ok, []} -> :applied
      {:ok, intervals} -> send_to(computer, {home, intervals}, repo, opts)
      {:error, reason} -> failed(computer, reason)
    end
  end

  defp send_to(%{connected: false}, _intervals, _repo, _opts), do: :away

  defp send_to(computer, {home, intervals}, repo, opts) do
    args = %{"home" => home, "intervals" => Enum.map(intervals, &wire/1)}

    case ask(computer, "apply", args, opts) do
      {:ok, %Outcome{result: %{"applied" => applied}}}
      when is_integer(applied) and applied >= 0 ->
        record(computer, applied, intervals, repo)

      {:ok, outcome} ->
        failed(computer, {:answer, outcome.result})

      {:error, %Outcome{} = outcome} ->
        failed(computer, {outcome.status, outcome.refusal})
    end
  end

  # The mark it answered is recorded (it never goes back). Below the highest
  # interval sent, it applied none of them: it keeps no store.
  defp record(computer, applied, intervals, repo) do
    case Repo.computer_history_home(:record_delivered, [computer.device_id, applied],
           server: repo
         ) do
      :ok -> if applied >= Enum.max_by(intervals, & &1.id).id, do: :applied, else: :no_store
      {:error, reason} -> failed(computer, reason)
    end
  end

  defp failed(computer, reason) do
    Logger.warning(
      "computer_history: #{computer.name} was not told of a purge or pause: #{inspect(reason)}"
    )

    :failed
  end

  # -- off for a named computer --------------------------------------------------------

  @doc """
  `/history off` naming `computer` (M97 §8.5): record the request on the home,
  then, if it is connected, tell it (`history.off`). `:done` once it switched
  its history off, `:away` when it is told once it is back, `{:failed,
  reason}` when the request is recorded but the computer could not be told
  now (it is told again on the scheduler's tick); `{:error, reason}` when the
  home could not record it, so nothing changed.
  """
  @spec switch_off(Computer.t(), keyword()) ::
          :done | :away | {:failed, term()} | {:error, term()}
  def switch_off(%Computer{} = computer, opts \\ []) when is_list(opts) do
    repo = Keyword.get(opts, :repo, Repo)
    at = Keyword.get_lazy(opts, :now_ms, fn -> System.system_time(:millisecond) end)

    case Repo.computer_history_home(:request_off, [computer.device_id, at], server: repo) do
      :ok -> owed_off(computer, at, repo, opts)
      {:error, _reason} = error -> error
    end
  end

  defp owed_off(_computer, nil, _repo, _opts), do: :none
  defp owed_off(%{connected: false}, _at, _repo, _opts), do: :away

  defp owed_off(computer, at, repo, opts) do
    with {:ok, %Outcome{result: %{"off" => true}}} <- ask(computer, "off", %{}, opts),
         :ok <- Repo.computer_history_home(:clear_off, [computer.device_id, at], server: repo) do
      :done
    else
      {:ok, outcome} -> off_failed(computer, {:answer, outcome.result})
      {:error, %Outcome{} = outcome} -> off_failed(computer, {outcome.status, outcome.refusal})
      {:error, reason} -> off_failed(computer, reason)
    end
  end

  defp off_failed(computer, reason) do
    Logger.warning(
      "computer_history: #{computer.name} was not told to switch its history off: " <>
        inspect(reason)
    )

    {:failed, reason}
  end

  # -- the request ---------------------------------------------------------------------

  defp ask(computer, op, args, opts) do
    call = Keyword.get(opts, :call, &Computers.call/6)
    call.(computer, MachineService, op, args, run_context(), Keyword.get(opts, :call_opts, []))
  end

  defp wire(interval), do: Map.new(interval, fn {key, value} -> {Atom.to_string(key), value} end)

  # The home's own background work, not a turn: its request carries a session id
  # of its own, which correlates it in each machine's trace.
  defp run_context do
    %{session_id: "computer_history_delivery:#{System.system_time(:millisecond)}"}
  end
end
