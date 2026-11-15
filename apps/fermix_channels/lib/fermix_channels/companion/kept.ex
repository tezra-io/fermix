defmodule FermixChannels.Companion.Kept do
  @moduledoc """
  What one companion connection holds of one kind of thing Fermix keeps, and
  what it owes (M89 §07; the lists' M85 §07): pure, kept in the connection's
  own state, so a kept kind adds no process. What the kind is on the wire is
  its `Companion.KeptKind` module's; this is the same for every kind.

  A connection that pulled the index (`index_pulled/1`) hears every change as
  the whole index again; one that pulled a thing holds it (`hold/3`), at most
  16, the oldest let go, and hears every committed change to it as the whole
  thing. A change is marked pending (`changed/2`) and every pending push goes
  out when the connection's window ends (`take_due/1`), so a burst of edits is
  one push per thing carrying its final rev, and `made` carries what each of a
  device's adds or creates made, at most 100 a thing. A device drops a push
  whose rev is below the one it shows: every push is whole state, never a
  delta.

  The state also carries the kind's store options (`opts`), how long its
  window is (`window_ms`) and the window's timer, which the connection arms.
  """

  @max_held 16
  @max_made 100

  @type t :: %{
          index?: boolean(),
          held: [String.t()],
          with_removed: MapSet.t(String.t()),
          pending: %{String.t() => %{String.t() => String.t()}},
          index_pending?: boolean(),
          timer: reference() | nil,
          opts: keyword(),
          window_ms: pos_integer()
        }

  @typedoc "One thing a commit changed: its id, and what each device edit made."
  @type change :: %{
          required(:id) => String.t(),
          optional(:made) => %{String.t() => String.t()},
          optional(atom()) => term()
        }

  @doc "The most things of one kind one connection holds."
  @spec max_held() :: pos_integer()
  def max_held, do: @max_held

  @doc "Nothing pulled yet, with the kind's store options and its window."
  @spec new(keyword(), pos_integer()) :: t()
  def new(opts, window_ms) when is_list(opts) and is_integer(window_ms) and window_ms > 0,
    do: %{
      index?: false,
      held: [],
      with_removed: MapSet.new(),
      pending: %{},
      index_pending?: false,
      timer: nil,
      opts: opts,
      window_ms: window_ms
    }

  @doc "Whether the connection pulled the index: its client draws the kind."
  @spec draws?(t()) :: boolean()
  def draws?(%{index?: index?}), do: index?

  @spec index_pulled(t()) :: t()
  def index_pulled(kept), do: %{kept | index?: true}

  @doc """
  Holds `id` as the newest, with its removed rows when `removed?`; past
  #{@max_held} the oldest is let go, with anything pending for it.
  """
  @spec hold(t(), String.t(), boolean()) :: t()
  def hold(kept, id, removed?) when is_binary(id) and is_boolean(removed?) do
    held = List.delete(kept.held, id) ++ [id]
    {gone, still} = Enum.split(held, max(length(held) - @max_held, 0))

    with_removed =
      if removed?,
        do: MapSet.put(kept.with_removed, id),
        else: MapSet.delete(kept.with_removed, id)

    %{
      kept
      | held: still,
        with_removed: Enum.reduce(gone, with_removed, &MapSet.delete(&2, &1)),
        pending: Map.drop(kept.pending, gone)
    }
  end

  @spec let_go(t(), String.t()) :: t()
  def let_go(kept, id) do
    %{
      kept
      | held: List.delete(kept.held, id),
        with_removed: MapSet.delete(kept.with_removed, id),
        pending: Map.delete(kept.pending, id)
    }
  end

  @doc "Whether `id` is held."
  @spec held?(t(), String.t()) :: boolean()
  def held?(kept, id), do: id in kept.held

  @doc "Whether `id` is held, with its removed rows."
  @spec with_removed?(t(), String.t()) :: boolean()
  def with_removed?(kept, id), do: MapSet.member?(kept.with_removed, id)

  @doc """
  Marks what `changes` move: each held thing, with what it made, and the index
  when it was pulled. Answers whether anything is now pending.
  """
  @spec changed(t(), [change()]) :: {t(), boolean()}
  def changed(kept, changes) when is_list(changes) do
    pending =
      Enum.reduce(changes, kept.pending, fn %{id: id} = change, pending ->
        if id in kept.held,
          do: Map.update(pending, id, made(%{}, change), &made(&1, change)),
          else: pending
      end)

    kept = %{kept | pending: pending, index_pending?: kept.index_pending? or kept.index?}
    {kept, pending?(kept)}
  end

  @doc "Marks one held thing pending with what a duplicate edit had made."
  @spec redeliver(t(), String.t(), String.t(), String.t() | nil) :: {t(), boolean()}
  def redeliver(kept, id, client_msg_id, made_id) do
    made = if made_id, do: %{client_msg_id => made_id}, else: %{}
    changed(kept, [%{id: id, made: made}])
  end

  defp made(sent, %{made: made}) when map_size(sent) >= @max_made or map_size(made) == 0,
    do: sent

  defp made(sent, %{made: made}), do: Map.merge(sent, made)
  defp made(sent, _change), do: sent

  defp pending?(kept), do: kept.pending != %{} or kept.index_pending?

  @doc "The window's timer, armed by the connection for what is now pending."
  @spec armed(t(), reference()) :: t()
  def armed(%{timer: nil} = kept, timer) when is_reference(timer), do: %{kept | timer: timer}

  @doc """
  What the ended window sends: each pending thing, oldest held first, with
  whether to send its removed rows and what it made, and whether to send the
  index. The state comes back with nothing pending and no timer.
  """
  @spec take_due(t()) :: {[{String.t(), boolean(), map()}], boolean(), t()}
  def take_due(kept) do
    due =
      for id <- kept.held,
          Map.has_key?(kept.pending, id),
          do: {id, MapSet.member?(kept.with_removed, id), Map.fetch!(kept.pending, id)}

    {due, kept.index_pending?, %{kept | pending: %{}, index_pending?: false, timer: nil}}
  end
end
