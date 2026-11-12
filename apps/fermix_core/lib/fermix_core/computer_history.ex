defmodule FermixCore.ComputerHistory do
  @moduledoc """
  Computer history (MILESTONE_32; M97 §8): an opt-in, off-by-default recorder
  of an interaction-event stream on each machine that has one, whose finished
  sittings become notes on the home, marked with the machine they came from.

  This module is the thin facade over the subsystem's operative state. Every
  flow decision ("may activity reach *this* sink") goes through
  `FermixCore.ComputerHistory.Gate`, never a scattered `enabled?()` check —
  the Gate is the single resolver (§9). This facade answers the coarse
  questions, each where its fact is (M97 §8.3): on a machine, whether it has a
  recorder (`recorder?/0`) and records (`operative?/0`); on the home, whether
  history can surface at all (`surfaces?/1`).

  The capture layer is macOS today (Accessibility TCC, NSWorkspace,
  AXObserver); a Linux recorder comes with a paired compux release (§8.8), and
  until then a Linux machine records nothing, while a Linux server still keeps
  and recalls the notes of the computers that do.
  """

  require Logger

  alias FermixCore.ComputerHistory.Config
  alias FermixCore.ComputerHistory.Controller
  alias FermixCore.ComputerHistory.Spool
  alias FermixCore.Computers
  alias FermixCore.Computers.Switches
  alias FermixCore.Memory.Repo
  alias FermixCore.Setup.ConfigStore

  @doc "Whether the operator has enabled computer history in config."
  @spec enabled?() :: boolean()
  def enabled?, do: Config.enabled?()

  @doc """
  Whether this host is macOS: the fact `recorder?/0` reads. Tests inject the
  facts the gates read (`:recording?`, `:recorder?`, `:surfaces?`) rather than
  mutate this, so the suite stays hermetic on Linux CI (Code Rule 5).
  """
  @spec macos?() :: boolean()
  def macos?, do: :os.type() == {:unix, :darwin}

  @doc """
  Whether this system has a recorder (M97 §8.3, §8.8): a Mac, in this release;
  a Linux recorder comes with a paired compux release. The fact a computer's
  recording is decided by, never whether the home can surface history.
  """
  @spec recorder?() :: boolean()
  def recorder?, do: macos?()

  @doc """
  Whether history records here (M97 §8.3): this system has a recorder *and* it
  is switched on. The master switch of the recorder and of this machine's
  sending; retention and purge run independently of it (§6.3).
  """
  @spec operative?() :: boolean()
  def operative?, do: recorder?() and enabled?()

  @doc """
  Whether computer history can surface in this home (M97 §8.3): what the home's
  gates read in place of this host's platform; the grant rule then decides each
  turn, as before. True when this machine records, or a computer of the home
  offers its history, or, on a home with no recorder of its own (an Always On
  server), the home holds notes. A home that records itself and switches its
  history off hides it, as it always has, unless a computer still offers it.

  `opts` (a test's or a caller's seams): `:recording?`, `:recorder?`,
  `:computers` (the home's computers, `Computers.list/0`), `:repo`.
  """
  @spec surfaces?(keyword()) :: boolean()
  def surfaces?(opts \\ []) when is_list(opts) do
    Keyword.get_lazy(opts, :recording?, &operative?/0) or
      offered?(Keyword.get_lazy(opts, :computers, &Computers.list/0)) or
      (not Keyword.get_lazy(opts, :recorder?, &recorder?/0) and
         holds_notes?(Keyword.get(opts, :repo, Repo)))
  end

  defp offered?(computers), do: Enum.any?(computers, &history_on?/1)

  defp history_on?(computer),
    do: Enum.any?(computer.offers, &(&1.id == "history" and &1.state == :on))

  @doc """
  The machines whose history the home still takes (M97 §8.5): this machine
  (`""`) while it records, and each computer of the home whose `history`
  offer is on, unless the owner asked from chat that its history go off and
  it has not yet said it did. A computer's offer is on exactly while its
  recorder is switched on there, under its master switch and its review
  (`Computers.Switches.history_on?/2`, M97 D27), the rule the computer works
  its offer out by and sends by (`FermixChannels.Desktop.HistoryUplink`), so
  a computer whose recorder is off never counts. Off means no further
  provider call for a machine's history: the home refuses a sitting from any
  other machine (`Submission`), and the roll-up reads only these machines'
  notes and makes no call when there are none (`Summarizer.run_rollup/1`). A
  store that does not answer is returned as its error; the caller takes
  nothing.

  `opts` (seams): `:recording?`, `:computers` (`Computers.list/0`), `:repo`.
  """
  @spec contributors(keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def contributors(opts \\ []) when is_list(opts) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, rows} <- Repo.computer_history_home(:computer_rows, [], server: repo) do
      pending = for %{computer_id: id, off_requested_at: at} <- rows, is_integer(at), do: id
      own = if Keyword.get_lazy(opts, :recording?, &operative?/0), do: [""], else: []

      offered =
        opts
        |> Keyword.get_lazy(:computers, &Computers.list/0)
        |> Enum.filter(&history_on?/1)
        |> Enum.map(& &1.device_id)

      {:ok, own ++ (offered -- pending)}
    end
  end

  @doc """
  The identity of the home's history store (M97 §8.5), which every purge and
  pause interval's id belongs to: the store's own token, made at random by
  `memory.db`'s migration 61 and made again wherever the ids can start
  again: another home and a server rebuilt from nothing make their own store,
  and a store installed from a stored copy (a backup, a snapshot, Restore
  here), however often the same copy is restored, gets a new one
  (`Home.Archive.install/5`, HS-4). A move or a move back carries the live
  store on with its ids, so it keeps the identity, and every machine its
  mark. A machine's mark is a mark under one identity
  (`Spool.apply_intervals/4`); every delivery and every answer to a sitting
  carries it.

  `opts`: `:repo`.
  """
  @spec home_identity(keyword()) :: {:ok, String.t()} | {:error, term()}
  def home_identity(opts \\ []) when is_list(opts),
    do: Repo.computer_history_home(:home_token, [], server: Keyword.get(opts, :repo, Repo))

  @doc """
  Whether this machine's history store opened (M97 §8.1), for readiness: a
  store that did not keeps the recorder off and says why in `/history status`.
  False where this engine keeps no store, or the store does not answer.
  """
  @spec store_open?(GenServer.server()) :: boolean()
  def store_open?(server \\ Spool) do
    case GenServer.whereis(server) do
      nil -> false
      pid -> Spool.status(server: pid) == :open
    end
  catch
    :exit, reason ->
      Logger.warning(
        "computer_history: the store did not say whether it opened: #{inspect(reason)}"
      )

      false
  end

  @machine_table "fermix_core.computer_history"

  @doc """
  Switch this machine's computer history off (`/history off`, M97 §8.5; a
  computer told from chat; a move's or a review's history line left
  unticked), in `home` (`:home`, the running engine's by default): the
  recorder's `enabled` is written false in that home's `machine.toml`, and
  on the running engine's own home it is put into application environment
  at once (the tools leave the next turn), the recorder is stopped
  (`reconcile_runtime/1`, only where this system has a recorder,
  `:recorder?`), and this computer's offers reporter is told: its history
  offer follows the recorder (M97 D27), so its server knows at once and
  nothing more is sent.

  Each step's outcome is answered, whatever the other's: the stop (`:stop`)
  and the saved setting (`:save`). `:controller` is the Controller to
  reconcile.
  """
  @spec switch_off(keyword()) :: %{stop: :ok | {:error, term()}, save: :ok | {:error, term()}}
  def switch_off(opts \\ []) when is_list(opts) do
    %{runtime: stop, save: save} = switch_recorder(false, opts)
    %{stop: stop, save: save}
  end

  @doc """
  Switch this machine's computer history on, from a move's or a review's
  history line ticked at this computer (M97 §7.3, D27), the same steps as
  `switch_off/1` the other way: written, applied at once on the running
  engine's own home, the recorder started where this system has one, and
  the offers reporter told. Only someone at this computer turns it on: the
  server never asks for this. Answers the start (`:start`) and the saved
  setting (`:save`).
  """
  @spec switch_on(keyword()) :: %{start: :ok | {:error, term()}, save: :ok | {:error, term()}}
  def switch_on(opts \\ []) when is_list(opts) do
    %{runtime: start, save: save} = switch_recorder(true, opts)
    %{start: start, save: save}
  end

  defp switch_recorder(on?, opts) do
    home = Keyword.get_lazy(opts, :home, &ConfigStore.fermix_home/0)
    running? = Path.expand(home) == Path.expand(ConfigStore.fermix_home())

    if running? do
      Application.put_env(
        :fermix_core,
        :computer_history,
        Keyword.put(Config.current(), :enabled, on?)
      )
    end

    pair = [{"enabled", to_string(on?)}]

    result = %{
      runtime: reconcile_here(running?, opts),
      save: saved(ConfigStore.put_machine_table(home, @machine_table, pair), on?)
    }

    if running?, do: Switches.offers_changed()
    result
  end

  defp reconcile_here(true, opts) do
    if Keyword.get_lazy(opts, :recorder?, &recorder?/0),
      do: reconcile_runtime(Keyword.get(opts, :controller, Controller)),
      else: :ok
  end

  defp reconcile_here(false, _opts), do: :ok

  defp saved(:ok, _on?), do: :ok

  defp saved({:error, reason} = error, on?) do
    Logger.warning(
      "computer_history: the #{if on?, do: "on", else: "off"} setting was not saved: " <>
        inspect(reason)
    )

    error
  end

  # A store that does not answer denies, loudly: a gate fails closed.
  defp holds_notes?(repo) do
    case Repo.computer_history_count_memories(server: repo, on_timeout: :error) do
      {:ok, count} -> count > 0
      {:error, :disabled} -> false
      {:error, reason} -> notes_unknown(reason)
    end
  catch
    :exit, reason -> notes_unknown(reason)
  end

  defp notes_unknown(reason) do
    Logger.warning(
      "computer_history: whether the home holds notes is unknown: #{inspect(reason)}"
    )

    false
  end

  @doc """
  Raise the macOS Accessibility grant capture needs, via the shared compux driver
  (`ComputerUse.request_permissions/0` — same binary, same TCC identity). Capture
  uses only the Accessibility grant; the shared prompt also raises Screen Recording,
  which capture ignores (an Accessibility-only action is a v1.1 refinement, §22.3).
  A no-op off macOS. Called from the Computer-History setup card at enable time so
  the prompt appears up front rather than on the first observe.
  """
  @spec request_permissions() :: {:ok, map()} | {:error, term()}
  def request_permissions do
    if macos?(), do: FermixCore.ComputerUse.request_permissions(), else: {:ok, %{}}
  end

  @doc """
  Reconcile the runtime capture children to the current config, live (`/history
  off` on a running daemon). Delegates to the `Controller`, which re-reads
  `operative?/0`, starts or stops the `Capturer` + summarizer, and answers `:ok`
  once every stop is done and every start attempted. Any exit of the call (no
  controller, a crash mid-call, a timeout) is returned as `{:error,
  {:reconcile_failed, reason}}`, never as `:ok`: the caller must not report a
  stop nobody confirmed. Off macOS there is no rail, so nothing to reconcile.
  """
  @spec reconcile_runtime(GenServer.server()) :: :ok | {:error, {:reconcile_failed, term()}}
  def reconcile_runtime(server \\ Controller)
      when is_pid(server) or is_atom(server) or is_tuple(server) do
    Controller.reconcile(server)
  catch
    :exit, reason ->
      Logger.error("computer_history reconcile_runtime failed: #{inspect(reason)}")
      {:error, {:reconcile_failed, reason}}
  end
end
