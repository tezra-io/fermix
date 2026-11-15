defmodule FermixCore.Kept.Notify do
  @moduledoc """
  How a committed change to a kept thing reaches the owner's devices (M89
  §07; the lists' M85 §07): right after the store committed it, whoever made
  it, the kind's Registry hands over what changed, each thing's id and new
  rev and what a device's add or create made, and this calls the notifier the
  channels app registers in core's app env (`:checklists_notifier`,
  `Companion.ChecklistNotifier`) with `%{owner_id:, <kind>: changes}`. With
  none registered nobody listens; `opts[:notifier]` is a test's own.

  The trips' index also moves with the date alone (M89 D14, `Trips.DayTurn`):
  `index_moved/3` hands the notifier the kind with no change, which sends the
  index again to every connection that pulled it and nothing it holds.
  """

  # The kinds a notifier hears of, by the key their changes ride under.
  @kinds [:lists, :trips]

  @typedoc "One thing a commit changed: its id, its new rev, and what each device edit made."
  @type change :: %{id: String.t(), rev: non_neg_integer(), made: %{String.t() => String.t()}}

  @doc "Tells the notifier that `changes` of `kind` committed for `owner_id`; none is no call."
  @spec announce(atom(), String.t(), [change()], keyword()) :: :ok
  def announce(kind, owner_id, changes, opts)
      when kind in @kinds and is_list(changes) and is_list(opts) do
    case {changes, notifier(opts)} do
      {[], _notifier} -> :ok
      {_changes, nil} -> :ok
      {changes, notifier} -> notifier.(%{:owner_id => owner_id, kind => changes})
    end
  end

  @doc """
  Tells the notifier that the trips' index moved while no trip changed: a
  day's turn started or ended one (`%{owner_id:, trips: []}`).
  """
  @spec index_moved(:trips, String.t(), keyword()) :: :ok
  def index_moved(:trips, owner_id, opts) when is_binary(owner_id) and is_list(opts) do
    case notifier(opts) do
      nil -> :ok
      notifier -> notifier.(%{owner_id: owner_id, trips: []})
    end
  end

  defp notifier(opts) do
    Keyword.get_lazy(opts, :notifier, fn ->
      case Application.get_env(:fermix_core, :checklists_notifier) do
        nil -> nil
        module -> &module.changed/1
      end
    end)
  end
end
