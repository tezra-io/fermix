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
  alias FermixCore.Computers
  alias FermixCore.Memory.Repo

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

  defp offered?(computers) do
    Enum.any?(computers, fn computer ->
      Enum.any?(computer.offers, &(&1.id == "history" and &1.state == :on))
    end)
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
