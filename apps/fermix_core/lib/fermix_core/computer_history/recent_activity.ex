defmodule FermixCore.ComputerHistory.RecentActivity do
  @moduledoc """
  The per-turn Recent Activity prompt section (MILESTONE_32 §11.1). Injected on
  the same seam as `Prompt.CurrentDate` — fresh every turn, not baked into the
  epoch-cached runtime sections. It renders **iff** the Gate permits the section
  this turn (`{:prompt_section}` — attended operator, permitted chain), which is
  the same predicate `recall_activity`'s advertisement uses, so the prompt and
  the wire cannot drift ("the prompt must follow the wire").

  The content is a bounded, char-capped digest of derived activity memories
  (never raw spool text), framed as untrusted data (§13.3). `nil` means "skip"
  — either the Gate denied it or there is no activity yet — and the injector
  treats `nil` as a no-op.
  """

  alias FermixCore.ComputerHistory.Gate
  alias FermixCore.ComputerHistory.Recall
  alias FermixCore.Memory.Repo

  @doc """
  The Recent Activity system note for this turn, or `nil` to skip. Reads the
  turn's frozen Gate snapshot from `context.computer_history_gate` when present
  ("snapshotted once per turn" — the same decision the taint stamp reads);
  builds one from the context only for callers without a frozen turn snapshot.
  """
  @spec note(map()) :: String.t() | nil
  def note(context) when is_map(context) do
    snapshot = Map.get(context, :computer_history_gate) || Gate.snapshot(context)

    if Gate.allow?(snapshot, {:prompt_section, context}) do
      Recall.recent_digest(repo: Map.get(context, :memory_repo, Repo))
    end
  end
end
