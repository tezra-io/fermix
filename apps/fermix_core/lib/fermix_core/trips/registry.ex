defmodule FermixCore.Trips.Registry do
  @moduledoc """
  The one writer of the owner's trips (M89 §04, §06, §14): a module of
  functions over `Memory.Repo`, never a process. The model's tools and the
  owner's devices read and change a trip only through it.

  It owns:

    * **the gate** — `Kept.Access`: the owner's private turn or voice call,
      or a scheduled job whose allowed tools name the tool; a device only over
      a connection placed as the owner's;
    * **the shape of a call** — checked in the caller before the store is
      asked (`Trips.Shape`): one trip, at most 100 ops, each field within its
      bound;
    * **one transaction** — the call goes to the Repo whole, where
      `Trips.Ops` applies it to the rows it loaded and the trip moves its
      `rev` once, or nothing changes; a device's edit is applied once by its
      `client_msg_id`;
    * **provenance** — after outside content a call may only add, the stop it
      adds stamped (`Trips.Ops`);
    * **the answers** — an edit's line, with the fixed stops whose date moved,
      and one sentence for every refusal (`describe_error/1`);
    * **what devices hear** — every committed change, whoever made it, with
      what a device's create, add or new day made (`Kept.Notify`).

  Every edit emits its event (`Trips.Telemetry`). A model's `place` is
  resolved by the place lookup before the store is asked; this module saves a
  place the call did not resolve as no place (C28).

  Seams (`opts`): `:repo` (the Repo server; nil when the turn has none),
  `:now`, `:notifier` and, for a device, `:made_via`.
  """

  alias FermixCore.Kept.Access, as: KeptAccess
  alias FermixCore.Kept.Ids
  alias FermixCore.Kept.Notify, as: KeptNotify
  alias FermixCore.Memory.Repo
  alias FermixCore.Trips.Ops
  alias FermixCore.Trips.Shape
  alias FermixCore.Trips.Telemetry

  @typedoc "A trip a call read or changed, as a reply's block names it."
  @type touch :: %{trip_id: String.t(), title: String.t(), rows: [String.t()]}

  @type answer :: %{text: String.t(), touched: [touch()]}

  @doc "Every op a `trip_edit` call takes, by name."
  @spec ops() :: [String.t()]
  def ops, do: Shape.ops()

  @doc "Every op a device's `trip_edit` takes, by name."
  @spec device_ops() :: [String.t()]
  def device_ops, do: Shape.device_ops()

  @doc "The most ops one `trip_edit` call carries."
  @spec max_ops() :: pos_integer()
  def max_ops, do: Shape.max_ops()

  # --- the model's edit ------------------------------------------------------

  @doc """
  Applies a `trip_edit` call (`"trip"`, `"ops"`) in one transaction. The
  answer is the trip's line, and `touched` names it with the live rows the
  call added or changed.
  """
  @spec edit(map(), map(), keyword()) :: {:ok, answer()} | {:error, term()}
  def edit(params, context, opts \\ [])
      when is_map(params) and is_map(context) and is_list(opts) do
    start = System.monotonic_time(:microsecond)

    result =
      with :ok <- gate(context, "trip_edit"),
           {:ok, call} <- Shape.call(params),
           request = {:edit, unresolved_unplaced(call), edit_context(context, opts)},
           {:ok, applied} <- store(context, opts, request) do
        :ok = announce(context, applied, %{}, opts)
        {:ok, edit_answer(applied)}
      end

    emit_edit(context, params, result, start)
    result
  end

  defp edit_context(context, opts) do
    %{
      now: now(opts),
      outside?: KeptAccess.read_outside?(context),
      made_via: KeptAccess.made_via(context)
    }
  end

  # A place reaches the store as a record or none: a model's words or link
  # that nothing resolved is saved as no place, as with no place search (C28).
  defp unresolved_unplaced(%{ops: ops} = call),
    do: %{call | ops: Enum.map(ops, &unplaced/1)}

  defp unplaced(%{place: {kind, _value}} = op) when kind in [:words, :link],
    do: %{op | place: nil}

  defp unplaced(op), do: op

  defp edit_answer(applied) do
    trip = applied.trip
    touched = [%{trip_id: trip.id, title: trip.title, rows: applied.touched_rows}]
    %{text: answer_text(applied), touched: touched}
  end

  defp answer_text(%{trip: %{removed_at: %DateTime{}, title: title}}),
    do: "#{title} · removed, restorable for 30 days"

  defp answer_text(%{trip: trip, rows: rows, events: events, dates_moved: moved}) do
    {days, stops} = Ops.counts(rows)
    words = if events == [], do: "nothing changed", else: Enum.join(events, "; ")

    line =
      "#{trip.title} · rev #{trip.rev} · #{words} · #{plural(days, "day")}, #{plural(stops, "stop")}"

    case moved do
      [] -> line
      moved -> line <> "\nDates moved: " <> Enum.map_join(moved, "; ", &moved_words/1) <> "."
    end
  end

  defp moved_words(%{row: row, to: to}),
    do: "[#{row.n}] #{quoted(row.text)} (fixed) is now #{stated_date(to)}"

  defp stated_date(nil), do: "undated"
  defp stated_date(%Date{} = date), do: Calendar.strftime(date, "%a %-d %b %Y")

  defp plural(1, noun), do: "1 #{noun}"
  defp plural(count, noun), do: "#{count} #{noun}s"

  # --- the owner's devices ---------------------------------------------------

  @doc """
  The index a device draws (`trips`): every live trip with its day and stop
  counts and rev, in picker order. Only a connection placed as the owner's
  (`caller` `:independent`) reads it.
  """
  @spec device_index(atom() | nil, keyword()) :: {:ok, [map()]} | {:error, term()}
  def device_index(caller, opts \\ []) when is_list(opts) do
    with :ok <- KeptAccess.device_gate(caller),
         do: store(KeptAccess.device_context(), opts, :index)
  end

  @doc """
  One trip a device draws (`trip`), live or removed and not yet swept:
  `%{trip, rows, removed_rows}`, the rows removed in the last 30 days only
  when `removed?`.
  """
  @spec device_trip(String.t(), boolean(), atom() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def device_trip(trip_id, removed?, caller, opts \\ [])
      when is_binary(trip_id) and is_boolean(removed?) and is_list(opts) do
    with :ok <- KeptAccess.device_gate(caller),
         :ok <- trip_id(trip_id),
         do: store(KeptAccess.device_context(), opts, {:trip_by_id, trip_id, removed?})
  end

  defp trip_id(id),
    do: if(Ids.valid?(id, "tr_"), do: :ok, else: {:error, {:invalid_param, :trip_id}})

  @doc """
  One edit a device sent (`trip_edit`): `"client_msg_id"`, `"op"` and, for
  every op but `create`, `"trip_id"`. It goes through the same transaction
  as the model's, its rows made via the device's wire (`opts[:made_via]`,
  `"mac"` or `"phone"`), and once only: an id already applied is answered
  `duplicate: true`, changes nothing and announces nothing. Answers the trip
  it changed and the id a create, an add or a new day made.
  """
  @spec device_edit(map(), atom() | nil, keyword()) ::
          {:ok, %{trip_id: String.t(), made: String.t() | nil, duplicate: boolean()}}
          | {:error, term()}
  def device_edit(%{"client_msg_id" => client_msg_id} = params, caller, opts \\ [])
      when is_binary(client_msg_id) and is_list(opts) do
    start = System.monotonic_time(:microsecond)
    context = KeptAccess.device_context()
    made_via = KeptAccess.device_made_via!(Keyword.get(opts, :made_via, "mac"))
    edit = %{now: now(opts), outside?: false, made_via: made_via}

    result =
      with :ok <- KeptAccess.device_gate(caller),
           {:ok, call} <- Shape.device_change(params),
           {:ok, outcome} <- store(context, opts, {:device_edit, client_msg_id, call, edit}) do
        device_outcome(outcome, context, {client_msg_id, opts})
      end

    result = device_refusal(result)
    emit_device_edit(result, made_via, start)
    result
  end

  defp device_outcome({:applied, applied}, context, {client_msg_id, opts}) do
    made = if applied.made, do: %{client_msg_id => applied.made}, else: %{}
    :ok = announce(context, applied, made, opts)
    {:ok, %{trip_id: applied.trip.id, made: applied.made, duplicate: false}}
  end

  defp device_outcome({:duplicate, record}, _context, _id_and_opts),
    do: {:ok, Map.put(record, :duplicate, true)}

  # A device sends one op, so its refusal is the op's own sentence, without
  # the place in a call the model is told, naming the fields a device sends.
  defp device_refusal({:error, {:op_failed, _op, reason}}), do: {:error, device_reason(reason)}
  defp device_refusal({:error, reason}), do: {:error, device_reason(reason)}
  defp device_refusal(result), do: result

  defp device_reason({:no_trip, id, _titles}), do: {:no_such_trip, id}
  defp device_reason(:add_needs_place), do: {:device, :add_needs_place}
  defp device_reason(:place_conflict), do: {:device, :place_conflict}
  defp device_reason(reason), do: reason

  # Every committed change reaches the owner's devices right after the store
  # committed it, whoever made it (`Kept.Notify`): the trip with its rev, and
  # what a device's create, add or new day made.
  defp announce(context, %{changed?: true, trip: trip}, made, opts) do
    change = %{id: trip.id, rev: trip.rev, made: made}
    KeptNotify.announce(:trips, owner_id(context), [change], opts)
  end

  defp announce(_context, %{changed?: false}, _made, _opts), do: :ok

  @doc """
  The live trips, for the per-turn line naming them: each with its title,
  start and day count, in picker order.
  """
  @spec names(map(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def names(context, opts \\ []) when is_map(context) and is_list(opts),
    do: store(context, opts, :index)

  # --- the store -------------------------------------------------------------

  defp store(context, opts, request) do
    case Keyword.get(opts, :repo, Repo) do
      nil -> {:error, :disabled}
      repo -> Repo.trips_call(request(context, request), repo_opts(repo, opts))
    end
  end

  defp request(context, :index), do: {:index, owner_id(context), agent_id(context)}

  defp request(context, {:trip_by_id, trip_id, removed?}),
    do: {:trip_by_id, owner_id(context), agent_id(context), trip_id, removed?}

  defp request(context, {:edit, call, edit}),
    do: {:edit, owner_id(context), agent_id(context), call, edit}

  defp request(context, {:device_edit, client_msg_id, call, edit}),
    do: {:device_edit, owner_id(context), agent_id(context), client_msg_id, call, edit}

  defp repo_opts(repo, opts), do: [server: repo] ++ Keyword.take(opts, [:on_timeout, :timeout])

  defp owner_id(context), do: Map.get(context, :memory_owner_id, "default")
  defp agent_id(context), do: Map.get(context, :memory_agent_id, "main")

  defp now(opts) do
    opts |> Keyword.get_lazy(:now, &DateTime.utc_now/0) |> DateTime.shift_zone!("Etc/UTC")
  end

  defp gate(context, tool) do
    if KeptAccess.permitted?(context, tool), do: :ok, else: {:error, {:not_permitted, tool}}
  end

  # --- telemetry -------------------------------------------------------------

  defp emit_edit(context, params, result, start) do
    {outcome, trips} =
      case result do
        {:ok, %{touched: touched}} -> {:ok, length(touched)}
        {:error, reason} -> {outcome(reason), 0}
      end

    ops = params |> Map.get("ops") |> List.wrap() |> length()
    edit = edit_event(trips, ops, outcome, KeptAccess.made_via(context), code(result))
    Telemetry.emit_edit(context, edit, elapsed(start))
  end

  defp emit_device_edit(result, made_via, start) do
    {outcome, trips} =
      case result do
        {:ok, %{duplicate: true}} -> {:ok, 0}
        {:ok, _changed} -> {:ok, 1}
        {:error, reason} -> {outcome(reason), 0}
      end

    Telemetry.emit_edit(
      %{},
      edit_event(trips, 1, outcome, made_via, code(result)),
      elapsed(start)
    )
  end

  # No place lookup runs in this module, so it counts none.
  defp edit_event(trips, ops, outcome, made_via, error_code) do
    %{
      trips: trips,
      ops: ops,
      lookups: 0,
      placed: 0,
      offered: 0,
      not_found: 0,
      not_looked_up: 0,
      outcome: outcome,
      made_via: made_via,
      error_code: error_code,
      backend: nil,
      rate_limited: false
    }
  end

  defp outcome(reason) do
    if error_tag(reason) == "storage_failed", do: :failed, else: :refused
  end

  defp code({:ok, _answer}), do: nil
  defp code({:error, reason}), do: error_tag(reason)

  defp elapsed(start), do: max(System.monotonic_time(:microsecond) - start, 0)

  # --- error vocabulary ------------------------------------------------------

  @doc """
  The tag a refused call is traced under: the reason's leading atom, or the
  op failure's own reason's, and `storage_failed` for a term with neither.
  """
  @spec error_tag(term()) :: String.t()
  def error_tag({:op_failed, _op, reason}), do: error_tag(reason)
  def error_tag({:invalid_op, _op, reason}), do: error_tag(reason)
  def error_tag({:device, reason}), do: error_tag(reason)

  def error_tag(reason) when is_atom(reason) and reason not in [nil, true, false],
    do: Atom.to_string(reason)

  def error_tag(reason) when is_tuple(reason) and is_atom(elem(reason, 0)),
    do: Atom.to_string(elem(reason, 0))

  def error_tag(_reason), do: "storage_failed"

  @doc """
  Every refusal as one sentence that tells the model or the device what to
  do. A refused op says which op it was, and that nothing in the call changed.
  """
  @spec describe_error(term()) :: String.t()
  def describe_error({:op_failed, op, reason}), do: describe_error(reason) <> unchanged(op)
  def describe_error({:invalid_op, op, reason}), do: describe_error(reason) <> unchanged(op)

  def describe_error({:not_permitted, tool}) do
    "#{tool} is available only on the owner's own turn in a private chat or a voice call, or " <>
      "in a scheduled job set up there that names it; group chats and guest, delegated and " <>
      "other runs cannot read or change the owner's trips."
  end

  def describe_error(:outside_content),
    do: "That change waits for a turn that read nothing from outside; ask me again."

  def describe_error({:no_trip, ref, titles}) do
    "No trip is named #{quoted(ref)}#{titles_part(titles)}. To make one, start the call with a " <>
      "create op, and only when the owner names a new trip."
  end

  def describe_error({:title_taken, title}),
    do: "A trip named #{quoted(title)} already exists; name another, or change that one."

  def describe_error({:title_in_use, title}) do
    "Another trip is named #{quoted(title)} now, so this one cannot come back under that name; " <>
      "restore it with a new title, or rename the other trip first."
  end

  def describe_error(:too_many_trips) do
    "The owner keeps at most #{Ops.max_trips()} trips. Remove one they no longer need to make " <>
      "room."
  end

  def describe_error({:trip_full, _title}) do
    "A trip holds at most #{Ops.max_rows()} days and stops together; remove some, or make the " <>
      "rest another trip."
  end

  def describe_error({:trip_too_large, title}) do
    "That would make #{quoted(title)} too large to send to the owner's devices; shorten its " <>
      "notes, or make the rest another trip."
  end

  def describe_error({:last_day, _title}),
    do: "A trip keeps at least one day; remove the trip instead."

  def describe_error({:no_row, {:id, _id}}),
    do: "That row is not in this trip any more; pull the trip again."

  def describe_error({:no_row, n}),
    do: "This trip has no row [#{n}]; read it again for its numbers."

  def describe_error({:no_day, k, days}),
    do: "This trip has no Day #{k}; it has #{plural(days, "day")}."

  def describe_error({:not_a_stop, ref}),
    do: "#{subject(ref)} is a day, not a stop; a day op names a day."

  def describe_error({:not_a_day, ref}), do: "#{subject(ref)} is a stop, not a day."
  def describe_error({:after_self, ref}), do: "#{subject(ref)} cannot be moved after itself."
  def describe_error(:not_removed), do: "That is not removed, so there is nothing to restore."
  def describe_error(:create_not_first), do: "create must be the first op of its call."
  def describe_error(:trip_removed), do: "This trip was removed earlier in the call."

  def describe_error({:no_such_trip, _id}),
    do: "No trip has that id; it may have been removed more than 30 days ago."

  def describe_error(:not_owner),
    do: "Only the owner's own Fermix app can read or change the owner's trips."

  def describe_error({:device, :move_needs_place}),
    do: "Moving a stop needs a day_id or an after_id."

  def describe_error({:device, :add_needs_place}), do: "An add needs a day_id or an after_id."
  def describe_error({:device, :place_conflict}), do: "Give day_id or after_id, not both."

  def describe_error({:device, :day_conflict}),
    do: "A day op names a day by its row_id, or makes one after after_id; give one, not both."

  def describe_error({:device, :place_and_unplace}), do: "Give place or unplace, not both."

  def describe_error({:unknown_device_op, name}),
    do: "#{inspect(name)} is not an op here; the ops are #{Enum.join(device_ops(), ", ")}."

  def describe_error(:too_many_ops),
    do: "One call carries at most #{max_ops()} ops; split the rest into another call."

  def describe_error({:unknown_op, name}),
    do: "#{inspect(name)} is not an op; the ops are #{Enum.join(ops(), ", ")}."

  def describe_error(:add_needs_place), do: "An add needs a day or an after."
  def describe_error(:move_needs_place), do: "A move needs a day or an after."
  def describe_error(:place_conflict), do: "Give day or after, not both."

  def describe_error(:nothing_to_edit),
    do: "An edit needs at least one of text, time, duration, fixed, note or place."

  def describe_error({:missing, field}), do: "The op needs #{field}."
  def describe_error({:not_a_number, field}), do: "#{field} must be a number, 1 or more."
  def describe_error({:not_days, field}), do: "#{field} must be a number of days, 1 to 1000."

  def describe_error({:not_time, field}),
    do: "#{field} must be a time of day as HH:MM, 00:00 to 23:59."

  def describe_error({:not_minutes, field}),
    do: "#{field} must be whole minutes, 1 to 1440, or 0 to clear it."

  def describe_error({:not_boolean, field}), do: "#{field} must be true or false."
  def describe_error({:not_date, field}), do: "#{field} must be a date, YYYY-MM-DD."

  def describe_error({:invalid_timezone, zone}),
    do: "#{quoted(zone)} is not a time zone; give an IANA zone such as Europe/Lisbon."

  def describe_error({:not_one_line, field}),
    do: "The #{field} must be words on one line, with no control characters."

  def describe_error({:too_long, field, max}), do: "The #{field} is over #{max} characters."

  def describe_error({:invalid_place, field}),
    do: "The place's #{field} is missing or out of its bounds."

  def describe_error({:invalid_param, :ops}), do: "ops must be a list of 1 to #{max_ops()} ops."
  def describe_error({:invalid_param, field}), do: "#{field} must be text."

  def describe_error(:disabled),
    do: "The owner's trips are unavailable because memory is off on this install."

  def describe_error(reason) do
    "The trips could not be read or saved (#{inspect(reason)}), so nothing changed; tell the " <>
      "owner and do not retry in this turn."
  end

  defp unchanged(op), do: " Nothing in this call was changed (op #{op})."

  # A row the model names by its number; a device's, by its id.
  defp subject({:id, _id}), do: "That row"
  defp subject(n), do: "[#{n}]"

  defp titles_part([]), do: "; the owner keeps no trips yet"
  defp titles_part(titles), do: "; the trips are " <> Enum.map_join(titles, ", ", &quoted/1)

  # Words the owner or the model wrote, JSON-quoted, as anything else the
  # model sent where words belong: every such value came as JSON.
  defp quoted(value), do: Jason.encode!(value)
end
