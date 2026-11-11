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
  alias FermixCore.Home.Epoch
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
  it has not yet said it did. Off means no further provider call for a
  machine's history: the home refuses a sitting from any other machine
  (`Submission`), and the roll-up reads only these machines' notes and makes
  no call when there are none (`Summarizer.run_rollup/1`). A store that does
  not answer is returned as its error; the caller takes nothing.

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
  pause interval's id belongs to: the store's own token (made once, at random,
  by `memory.db`'s migration 61), joined with the home's epoch
  (`Home.Epoch`), which a restore and a move raise. It changes wherever the
  ids can start again: another home, a server rebuilt from nothing, a home
  restored from a snapshot. A machine's mark is a mark under one identity
  (`Spool.apply_intervals/4`); every delivery and every answer to a sitting
  carries it.

  A home that has not yet booted as the primary has no epoch: it is counted
  as 0 here, and the first primary boot's epoch changes the identity, which
  costs each machine one apply of every interval again.

  `opts`: `:repo`, `:home` (the home folder, `ConfigStore.fermix_home/0` by
  default).
  """
  @spec home_identity(keyword()) :: {:ok, String.t()} | {:error, term()}
  def home_identity(opts \\ []) when is_list(opts) do
    repo = Keyword.get(opts, :repo, Repo)
    home = Keyword.get_lazy(opts, :home, &ConfigStore.fermix_home/0)

    with {:ok, token} <- Repo.computer_history_home(:home_token, [], server: repo),
         {:ok, epoch} <- epoch(Epoch.read(home)) do
      {:ok, "#{token}.#{epoch}"}
    end
  end

  defp epoch({:ok, epoch}), do: {:ok, epoch}
  defp epoch(:absent), do: {:ok, 0}
  defp epoch({:error, reason}), do: {:error, {:epoch, reason}}

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
  Switch this machine's computer history off (`/history off`, M97 §8.5), in
  `home` (`:home`, the running engine's by default): the recorder's
  `enabled` is written false in that home's `machine.toml`, and on the
  running engine's own home it is put into application environment at once
  (the tools leave the next turn) and the recorder is stopped
  (`reconcile_runtime/1`, only where this system has a recorder,
  `:recorder?`). With `offer: true` (a computer told from chat) the
  server's `history` offer goes off too (`Computers.Switches`), so its
  server knows at once and nothing more is sent.

  Each step's outcome is answered, whatever the others': the stop
  (`:stop`), the saved setting (`:save`) and the offer (`:offer`, `:ok`
  when not asked). `:controller` is the Controller to reconcile.
  """
  @spec switch_off(keyword()) :: %{
          stop: :ok | {:error, term()},
          save: :ok | {:error, term()},
          offer: :ok | {:error, term()}
        }
  def switch_off(opts \\ []) when is_list(opts) do
    home = Keyword.get_lazy(opts, :home, &ConfigStore.fermix_home/0)
    running? = Path.expand(home) == Path.expand(ConfigStore.fermix_home())

    if running? do
      Application.put_env(
        :fermix_core,
        :computer_history,
        Keyword.put(Config.current(), :enabled, false)
      )
    end

    %{
      stop: stop_here(running?, opts),
      save: saved(ConfigStore.put_machine_table(home, @machine_table, [{"enabled", "false"}])),
      offer: if(Keyword.get(opts, :offer, false), do: offer_off(home), else: :ok)
    }
  end

  defp stop_here(true, opts) do
    if Keyword.get_lazy(opts, :recorder?, &recorder?/0),
      do: reconcile_runtime(Keyword.get(opts, :controller, Controller)),
      else: :ok
  end

  defp stop_here(false, _opts), do: :ok

  defp saved(:ok), do: :ok

  defp saved({:error, reason} = error) do
    Logger.warning("computer_history: the off setting was not saved: #{inspect(reason)}")
    error
  end

  defp offer_off(home) do
    case Switches.read(home) do
      {:ok, switches} ->
        if Keyword.get(switches, :history, false),
          do: Switches.write(home, Keyword.put(switches, :history, false)),
          else: :ok

      {:error, _reason} = error ->
        error
    end
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
