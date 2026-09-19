defmodule FermixCore.ComputerUse.Observations do
  @moduledoc """
  The images a conversation may still address, and the three checks over them
  (M42 slice 3 §4.1).

  Every reply that hands the model coordinates — a `screenshot`, an `elements`
  listing, a `windows` listing — is minted by the helper with an `observation_id`,
  and every coordinate the model sends names the image it was read in. This table
  mirrors what the helper retains (three, oldest out) so this side can answer,
  before any driver call, the three questions that used to be asked of a rectangle
  the model had to remember and copy onto each action:

    * is this action addressed to an image at all (`check_addressing/2`),
    * which point does `mark: N` mean in the image it names (`resolve_mark/2`),
    * and is this point plausible on two grids at once (`ambiguity/2`, the M28
      wrong-grid tripwire, thresholds and arithmetic unchanged).

  **Pure: no process, no I/O, no clock.** The recording time is passed in, which
  is what makes age and eviction testable without sleeping, and mirrors the
  helper's own `Clock` seam.

  **The helper owns liveness, this side owns addressing.** An id this table no
  longer holds is still sent: the helper answers `unknown_observation`,
  `expired_observation` or `stale_observation` for it, and the session then drops
  it here too (`drop/2`). Two authorities on whether an image is alive is how a
  healthy click gets refused by the half that knows less.

  The table is a list, newest first. At three entries an ordered list answers
  "oldest out" without a second counter, and `id => entry` is a lookup over it.
  """

  # Three, matching the helper's own cap: an id this side kept past the helper's
  # window would only be refused a round trip later, and an id the helper kept
  # past this side's would lose its marks and its crop.
  @max_observations 3

  # The wrong-grid tripwire's threshold (M28 A1). A crop magnified more than this
  # is one whose full-screen coordinates and whose own pixels can both look
  # plausible for the same point.
  @ambiguity_min_zoom 1.5

  # Actions whose target is read off an image — a point, or a control named by
  # `element_ref` — so each must name the image it was read in. `scroll` carries
  # optional coordinates too; keyboard actions never do.
  @addressed_actions ~w(left_click right_click double_click mouse_move left_click_drag scroll
                        inspect press set_value)

  # The accessibility half of that set: these name a control and never a point, so
  # a mark on one resolves to the badged control rather than to its badge's pixel.
  @element_actions ~w(press set_value)

  # The actions that accept EITHER form, so that naming a target twice is a choice
  # the model has to make rather than a shape the action never had. `Compux.Protocol`
  # is the authority on this split — a drag names two points and `inspect` reports
  # what is under one, so neither has a meaning for a reference and the library
  # refuses one there with a sentence of its own, which is the right sentence for
  # it. Anything outside this list falls through to that.
  @either_form @element_actions ++ ~w(left_click right_click double_click mouse_move scroll)

  @type id :: String.t()

  @type badge :: %{point: {integer(), integer()}, element_ref: String.t() | nil}

  @type entry :: %{
          kind: String.t() | nil,
          region: map() | nil,
          dims: {pos_integer(), pos_integer()} | nil,
          marks: %{integer() => badge()} | nil,
          recorded_at_ms: integer()
        }

  @type t :: [{id(), entry()}]

  @doc """
  An empty table.

      iex> FermixCore.ComputerUse.Observations.new()
      []
  """
  @spec new() :: t()
  def new, do: []

  @doc """
  Record the observation a reply minted, evicting the oldest once past three.

  `request` supplies exactly one fact the reply cannot: whether a crop was ASKED
  for at all, which is what separates a magnified view from the whole display.
  Everything else — the id, the kind, the sent dimensions, the badge table and the
  RECTANGLE — is read from the reply.

  The rectangle has to come from the reply. A `screenshot` may name an
  `observation_id` beside its `region`, and the rectangle is then in THAT image's
  pixels — a crop of a crop, which the schema invites. The helper resolves whatever
  space it was given into the full-display image's pixels and echoes the result,
  and full-display pixels are the one space `ambiguity/2` and the crop check can
  both read: the tripwire asks whether a point sits inside this crop's rectangle
  ON THE FULL IMAGE, and a rectangle left in a parent's pixels answers a different
  question. Recording the request's copy verbatim refused correct clicks on a
  nested crop and told the model to convert to a point in the image it had already
  read — and, when the parent was sent at native scale, silently stopped guarding
  every nested crop instead.

  A reply that mints no observation leaves the table alone.
  """
  @spec record(t(), map(), map(), integer()) :: t()
  def record(table, request, %{"observation_id" => id} = response, now_ms)
      when is_list(table) and is_map(request) and is_binary(id) and is_integer(now_ms) do
    entry = %{
      kind: response["observation_kind"],
      region: recorded_region(request, response),
      dims: dims(response),
      marks: marks(response),
      recorded_at_ms: now_ms
    }

    [{id, entry} | List.keydelete(table, id, 0)] |> Enum.take(@max_observations)
  end

  def record(table, request, response, now_ms)
      when is_list(table) and is_map(request) and is_map(response) and is_integer(now_ms),
      do: table

  @doc "Forget an id — the helper refused it as unknown, expired or stale."
  @spec drop(t(), id()) :: t()
  def drop(table, id) when is_list(table) and is_binary(id), do: List.keydelete(table, id, 0)

  @doc "The observation an id names, or `:error` when this side no longer holds it."
  @spec fetch(t(), id() | nil) :: {:ok, entry()} | :error
  def fetch(table, id) when is_list(table) and is_binary(id) do
    case List.keyfind(table, id, 0) do
      {^id, entry} -> {:ok, entry}
      nil -> :error
    end
  end

  def fetch(table, _id) when is_list(table), do: :error

  @doc """
  Refuse an action whose target is unaddressed or addressed twice, before any
  driver call.

  This replaces the region guard: there is no rectangle to forget any more, so
  two questions are left. Does the action say which image its target was read in —
  a point and an `element_ref` alike mean nothing without one, because a ref is
  scoped to the observation that minted it. And does it name exactly ONE target:
  there are three ways to say where (a point, a numbered mark, a control's
  `element_ref`) and a request carrying two of them has two answers to "where",
  which is the one thing a GUI driver may never guess at.
  """
  @spec check_addressing(t(), map()) ::
          :ok | {:error, :observation_required | :addressing_conflict}
  def check_addressing(table, request) when is_list(table) and is_map(request) do
    cond do
      request["action"] not in @addressed_actions -> :ok
      not is_binary(request["observation_id"]) -> {:error, :observation_required}
      addressed_twice?(request) -> {:error, :addressing_conflict}
      true -> :ok
    end
  end

  defp addressed_twice?(%{"action" => action} = request) when action in @either_form,
    do: length(addressing_forms(request)) > 1

  defp addressed_twice?(_request), do: false

  # Which of the three ways of naming a target this request used. A drag's two
  # endpoints are one form, not two: they say where together.
  defp addressing_forms(request) do
    Enum.filter(
      [
        Map.has_key?(request, "x") or Map.has_key?(request, "from") or
          Map.has_key?(request, "to"),
        Map.has_key?(request, "mark"),
        is_binary(request["element_ref"])
      ],
      & &1
    )
  end

  @doc """
  Resolve `mark: N` to what the action carrying it needs: the badge's point for a
  pointer action, the badged control's `element_ref` for `press`/`set_value`.

  A mark names its observation like any other coordinate, so the badge table is a
  property of the image it was drawn on: an image with no badges answers
  `:no_marks`, and a number that image never badged answers `{:unknown_mark, id,
  count}`. Staleness is gone — a mark from an image the model has left is a mark
  on an image it can still name, and the helper refuses the id if it has aged out.

  A badge IS a control, so a mark is also the shortest way to name one by
  accessibility. A badge the helper minted no reference for answers
  `{:mark_not_pressable, id}` rather than being quietly clicked instead — which
  mechanism to fall back on is the model's call, never this side's.

  The resolved request carries x/y or an `element_ref` and no `mark`: the helper
  stays free of any cross-request badge table.
  """
  @spec resolve_mark(t(), map()) ::
          {:ok, map(), boolean()}
          | {:error,
             :no_marks
             | {:unknown_mark, integer(), non_neg_integer()}
             | {:mark_not_pressable, integer()}}
  def resolve_mark(table, %{"mark" => mark} = request)
      when is_list(table) and is_integer(mark) do
    case fetch(table, request["observation_id"]) do
      {:ok, %{marks: marks}} when is_map(marks) -> substitute_mark(request, mark, marks)
      _absent -> {:error, :no_marks}
    end
  end

  def resolve_mark(table, %{"mark" => _malformed}) when is_list(table), do: {:error, :no_marks}

  def resolve_mark(table, request) when is_list(table) and is_map(request),
    do: {:ok, request, false}

  @doc """
  The wrong-grid tripwire (M28 A1), preserved over observation identity.

  Observed live 2026-07-28: reading a 1355x959 magnified crop, the model answered
  15 clicks whose coordinates all fit inside the 482x341 REGION RECTANGLE — it was
  aiming on the full-screen grid while the contract read crop pixels, and the
  cursor echo confirmed each miss as a hit. A point that is plausible on BOTH live
  grids — inside the POSITIONED region rect while the named image magnifies more
  than #{@ambiguity_min_zoom}x — is refused with the exact conversion rather than
  clicked wrongly on one of them. The rect is positioned (r.x..r.x+r.w): an
  origin-anchored 0..w test goes blind for any window not at the screen's top-left.
  """
  @spec ambiguity(t(), map()) :: :ok | {:error, {:ambiguous_coordinates, map()}}
  def ambiguity(table, request) when is_list(table) and is_map(request) do
    case fetch(table, request["observation_id"]) do
      {:ok, entry} -> judge_grid(request["observation_id"], entry, action_points(request))
      :error -> :ok
    end
  end

  defp judge_grid(id, entry, points) do
    if ambiguous?(entry, points),
      do: {:error, {:ambiguous_coordinates, ambiguity_info(id, entry, points)}},
      else: :ok
  end

  defp ambiguous?(%{region: %{"w" => rw} = region, dims: {vw, _vh}}, [_ | _] = points)
       when is_number(rw) and rw > 0,
       do: vw / rw > @ambiguity_min_zoom and Enum.all?(points, &inside_region_rect?(&1, region))

  defp ambiguous?(_entry, _points), do: false

  # The refusal text IS the recovery recipe, so the conversion in it must be exact:
  # crop_xy = (xy − region origin) × kz.
  defp ambiguity_info(id, %{region: region, dims: {vw, vh}}, points) do
    kz = vw / region["w"]

    %{
      id: id,
      region: region,
      view: %{"w" => vw, "h" => vh},
      kz: kz,
      points: points,
      crop_equivalents:
        Enum.map(points, fn {x, y} ->
          {round((x - region["x"]) * kz), round((y - region["y"]) * kz)}
        end)
    }
  end

  # The coordinates a pointer action aims at. A drag is judged by BOTH endpoints —
  # one endpoint outside the rect already disambiguates the pair.
  defp action_points(%{"x" => x, "y" => y}) when is_number(x) and is_number(y), do: [{x, y}]

  defp action_points(%{"from" => %{"x" => fx, "y" => fy}, "to" => %{"x" => tx, "y" => ty}}),
    do: [{fx, fy}, {tx, ty}]

  defp action_points(_request), do: []

  defp inside_region_rect?({x, y}, %{"x" => rx, "y" => ry, "w" => rw, "h" => rh}),
    do: x >= rx and x <= rx + rw and y >= ry and y <= ry + rh

  defp substitute_mark(request, mark, marks) do
    case Map.fetch(marks, mark) do
      {:ok, badge} -> address_from(request, mark, badge)
      :error -> {:error, {:unknown_mark, mark, map_size(marks)}}
    end
  end

  defp address_from(%{"action" => action} = request, mark, badge)
       when action in @element_actions do
    case badge.element_ref do
      ref when is_binary(ref) -> {:ok, put_target(request, %{"element_ref" => ref}), true}
      nil -> {:error, {:mark_not_pressable, mark}}
    end
  end

  defp address_from(request, _mark, %{point: {x, y}}),
    do: {:ok, put_target(request, %{"x" => x, "y" => y}), true}

  defp put_target(request, fields), do: request |> Map.delete("mark") |> Map.merge(fields)

  # A crop is an image a rectangle was ASKED for (the request), positioned where
  # the helper RESOLVED it to (the reply, in full-display image pixels). A capture
  # that asked for no rectangle is the whole display and holds none, whatever the
  # reply echoes back. A helper that answers a crop with no rectangle has told us
  # nothing to position it by, so it is not treated as one: the tripwire stays
  # quiet and the check falls back to the helper's own full-display capture, both
  # of which are the safe side of that ignorance.
  defp recorded_region(%{"region" => asked}, %{"region" => resolved})
       when is_map(asked) and is_map(resolved),
       do: resolved

  defp recorded_region(_request, _response), do: nil

  defp dims(%{"width" => w, "height" => h}) when is_integer(w) and is_integer(h), do: {w, h}
  defp dims(_response), do: nil

  # A badge is a point AND, since the helper retains the element behind it, a
  # control it can act on by name. Both are recorded: `mark: N` on a click still
  # means the point, and on a `press` it means the control.
  defp marks(%{"marks" => marks}) when is_list(marks) do
    for %{"id" => id, "x" => x, "y" => y} = mark <- marks,
        is_integer(id) and is_integer(x) and is_integer(y),
        into: %{},
        do: {id, %{point: {x, y}, element_ref: element_ref(mark["element_ref"])}}
  end

  defp marks(_response), do: nil

  defp element_ref(ref) when is_binary(ref) and ref != "", do: ref
  defp element_ref(_absent), do: nil
end
