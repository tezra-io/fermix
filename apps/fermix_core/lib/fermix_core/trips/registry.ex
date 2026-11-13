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
    * **provenance** — after outside content every op runs, and a stop the
      call adds or gives words, a note or a place is stamped (`Trips.Ops`),
      which a read shows as data without marking the turn (D9);
    * **the places** — a model's `place`, words or a link, resolved before the
      store is asked (`Trips.Placing`, `Trips.Lookup`), the lookups' records
      joining the conversation first, so a link the answer offers resolves
      even when the store refuses the call;
    * **the answers** — a read rendered as text (`Trips.Render`), an edit's
      line with what each place came to and the fixed stops whose date moved,
      the shared form a device's Share hands on, and one sentence for every
      refusal (`describe_error/1`);
    * **what devices hear** — every committed change, whoever made it, with
      what a device's create, add or new day made (`Kept.Notify`).

  Every read and edit emits its event (`Trips.Telemetry`).

  Seams (`opts`): `:repo` (the Repo server; nil when the turn has none),
  `:now`, `:notifier`, `:reply_blocks` (the holder a lookup's records join)
  and, for a device, `:made_via`. The place search is the one in force for
  the turn (`Lookup.backend/1`; a context's `:place_lookup` stands in for it).
  """

  alias FermixCore.Kept.Access, as: KeptAccess
  alias FermixCore.Kept.Ids
  alias FermixCore.Kept.Notify, as: KeptNotify
  alias FermixCore.Memory.Repo
  alias FermixCore.ReplyBlocks
  alias FermixCore.Tools.PlaceSearch
  alias FermixCore.Trips.Lookup
  alias FermixCore.Trips.Ops
  alias FermixCore.Trips.Placing
  alias FermixCore.Trips.Render
  alias FermixCore.Trips.Shape
  alias FermixCore.Trips.Telemetry

  # An edit that gave no place to look up.
  @no_lookups %{
    lookups: 0,
    placed: 0,
    offered: 0,
    not_found: 0,
    not_looked_up: 0,
    backend: nil,
    rate_limited: false
  }
  # A read's `day`: a day's position, or a run of them (C13).
  @run ~r/\A([0-9]{1,4})(?:\s*[-–]\s*([0-9]{1,4}))?\z/u

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

  # --- the model's read ------------------------------------------------------

  @doc """
  A `trip_read` call: with no `"trip"` the index; with one (a title or id)
  the trip whole, or the days `"day"` names (a day's position, `"2"`, or a
  run, `"2-4"`, C13), as text, or with `"as": "share"` in its shared form.
  Any read past 32 KB is its outline (`Trips.Render.read/4`, C26). `touched`
  names the trip read, with no rows: a read changes none.
  """
  @spec read(map(), map(), keyword()) :: {:ok, answer()} | {:error, term()}
  def read(params, context, opts \\ [])
      when is_map(params) and is_map(context) and is_list(opts) do
    start = System.monotonic_time(:microsecond)

    {result, read} =
      with :ok <- gate(context, "trip_read"),
           {:ok, asked} <- read_params(params) do
        do_read(asked, context, opts)
      else
        {:error, reason} -> {{:error, reason}, %{scope: asked_scope(params), trips: 0}}
      end

    emit_read(context, read, result, start)
    result
  end

  defp read_params(params) do
    with {:ok, ref} <- read_ref(Map.get(params, "trip")),
         {:ok, run} <- read_run(Map.get(params, "day")),
         {:ok, form} <- read_form(Map.get(params, "as")) do
      case {ref, run, form} do
        {nil, :all, :text} -> {:ok, :index}
        {nil, _run, _form} -> {:error, :trip_needed}
        asked -> {:ok, asked}
      end
    end
  end

  defp read_ref(nil), do: {:ok, nil}

  defp read_ref(ref) when is_binary(ref) do
    case String.trim(ref) do
      "" ->
        {:ok, nil}

      trimmed ->
        if String.valid?(trimmed), do: {:ok, trimmed}, else: {:error, {:invalid_param, :trip}}
    end
  end

  defp read_ref(_ref), do: {:error, {:invalid_param, :trip}}

  defp read_run(nil), do: {:ok, :all}
  defp read_run(k) when is_integer(k) and k >= 1, do: {:ok, {k, k}}

  defp read_run(text) when is_binary(text) do
    case Regex.run(@run, String.trim(text)) do
      [_whole, from] -> run_of(from, from, text)
      [_whole, from, to] -> run_of(from, to, text)
      nil -> if String.trim(text) == "", do: {:ok, :all}, else: {:error, {:not_a_day_run, text}}
    end
  end

  defp read_run(value), do: {:error, {:not_a_day_run, value}}

  defp run_of(from, to, value) do
    {from, to} = {String.to_integer(from), String.to_integer(to)}
    if from >= 1 and to >= from, do: {:ok, {from, to}}, else: {:error, {:not_a_day_run, value}}
  end

  defp read_form(value) when value in [nil, ""], do: {:ok, :text}
  defp read_form("share"), do: {:ok, :share}
  defp read_form(_value), do: {:error, {:invalid_param, :as}}

  defp do_read(:index, context, opts) do
    case store(context, opts, :index) do
      {:ok, trips} ->
        {{:ok, %{text: Render.index(trips), touched: []}}, %{scope: :index, trips: length(trips)}}

      {:error, reason} ->
        {{:error, reason}, %{scope: :index, trips: 0}}
    end
  end

  defp do_read({ref, run, form}, context, opts) do
    with {:ok, %{trip: trip, rows: rows}} <- store(context, opts, {:read_trip, ref}),
         :ok <- within_days(rows, run) do
      {shape, text} = Render.read(trip, rows, run, form)
      touched = [%{trip_id: trip.id, title: trip.title, rows: []}]
      {{:ok, %{text: text, touched: touched}}, %{scope: read_scope(shape, run, form), trips: 1}}
    else
      {:error, reason} -> {{:error, reason}, %{scope: read_scope(:whole, run, form), trips: 0}}
    end
  end

  defp within_days(_rows, :all), do: :ok

  defp within_days(rows, {from, to}) do
    {days, _stops} = Ops.counts(rows)

    cond do
      from > days -> {:error, {:no_day, from, days}}
      to > days -> {:error, {:no_day, to, days}}
      true -> :ok
    end
  end

  defp read_scope(:outline, _run, _form), do: :outline
  defp read_scope(:whole, _run, :share), do: :share
  defp read_scope(:whole, :all, :text), do: :trip
  defp read_scope(:whole, _run, :text), do: :days

  # The scope a refused read asked for, as far as its params say.
  defp asked_scope(params) do
    cond do
      Map.get(params, "as") == "share" -> :share
      Map.get(params, "trip") in [nil, ""] -> :index
      Map.get(params, "day") != nil -> :days
      true -> :trip
    end
  end

  # --- the model's edit ------------------------------------------------------

  @doc """
  Applies a `trip_edit` call (`"trip"`, `"ops"`) in one transaction. A place
  given by words or a link is resolved first: the trip is read, the call run
  over it to learn each stop's day (`Trips.Placing`), the lookups run
  (`Trips.Lookup`), and their records join the conversation
  (`ReplyBlocks.put_places/3`) before the store is asked. The answer is the
  trip's line and what each place came to (`Trips.Render.answer/2`), and
  `touched` names the trip with the live rows the call added or changed.
  """
  @spec edit(map(), map(), keyword()) :: {:ok, answer()} | {:error, term()}
  def edit(params, context, opts \\ [])
      when is_map(params) and is_map(context) and is_list(opts) do
    start = System.monotonic_time(:microsecond)

    {result, looked} =
      with :ok <- gate(context, "trip_edit"),
           {:ok, call} <- Shape.call(params) do
        edit_call(call, context, opts)
      else
        {:error, reason} -> {{:error, reason}, @no_lookups}
      end

    emit_edit(context, params, {result, looked}, start)
    result
  end

  defp edit_context(context, opts) do
    %{
      now: now(opts),
      outside?: KeptAccess.read_outside?(context),
      made_via: KeptAccess.made_via(context)
    }
  end

  defp edit_call(call, context, opts) do
    edit = edit_context(context, opts)

    if Placing.needed?(call) do
      case look_up(call, edit, context, opts) do
        {:ok, placed, outcomes, looked} -> {commit(placed, edit, context, opts, outcomes), looked}
        {:error, reason, looked} -> {{:error, reason}, looked}
      end
    else
      {commit(call, edit, context, opts, []), @no_lookups}
    end
  end

  # The trip as it stands and the call run over it, which may refuse it before
  # any lookup is spent; then the lookups, whose records join the conversation
  # before the store is asked.
  defp look_up(call, edit, context, opts) do
    with {:ok, loaded} <- load(call, context, opts),
         {:ok, requests, anchors} <- Placing.requests(loaded, call, edit),
         {:ok, found} <- resolve(requests, anchors, context, opts) do
      :ok = join_conversation(found.records, context, opts)
      {placed_call, outcomes} = Placing.placed_call(call, found.outcomes)
      {:ok, placed_call, outcomes, looked(call, outcomes, found.lookups, context)}
    else
      {:error, reason} -> {:error, reason, @no_lookups}
    end
  end

  defp load(%{ops: [%{op: :create} | _rest]}, context, opts) do
    with {:ok, trips} <- store(context, opts, :index), do: {:ok, %{trips: trips, rows: []}}
  end

  defp load(%{trip: ref}, context, opts) do
    with {:ok, %{trip: trip, rows: rows}} <- store(context, opts, {:read_trip, ref}),
         do: {:ok, %{trips: [trip], rows: rows}}
  end

  defp resolve(requests, anchors, context, opts) do
    lookup_opts = [
      backend: Lookup.backend(context),
      conversation_key: Map.fetch!(context, :conversation_key),
      reply_blocks: reply_blocks(opts)
    ]

    case Lookup.resolve(requests, anchors, lookup_opts) do
      {:ok, found} -> {:ok, found}
      {:error, {:unknown_place_link, index}} -> {:error, {:op_failed, index, :unknown_place_link}}
      {:error, :too_many_lookups} -> {:error, :too_many_lookups}
    end
  end

  defp join_conversation([], _context, _opts), do: :ok

  defp join_conversation(records, context, opts),
    do:
      ReplyBlocks.put_places(reply_blocks(opts), Map.fetch!(context, :conversation_key), records)

  defp reply_blocks(opts), do: Keyword.get(opts, :reply_blocks, ReplyBlocks)

  defp commit(call, edit, context, opts, outcomes) do
    with {:ok, applied} <- store(context, opts, {:edit, call, edit}) do
      :ok = announce(context, applied, %{}, opts)
      {:ok, edit_answer(applied, Placing.placements(call, applied, outcomes))}
    end
  end

  defp edit_answer(applied, placements) do
    trip = applied.trip
    touched = [%{trip_id: trip.id, title: trip.title, rows: applied.touched_rows}]
    %{text: Render.answer(applied, placements), touched: touched}
  end

  # What the call's lookups came to, for its event: each place given counted
  # once, by its outcome.
  defp looked(call, outcomes, lookups, context) do
    counts = Enum.frequencies_by(outcomes, fn {_index, outcome} -> bucket(outcome) end)

    %{
      lookups: lookups,
      placed: Map.get(counts, :placed, 0),
      offered: Map.get(counts, :offered, 0),
      not_found: Map.get(counts, :not_found, 0),
      not_looked_up: Map.get(counts, :not_looked_up, 0),
      backend: if(Placing.words?(call), do: backend_name(context)),
      rate_limited: Enum.any?(outcomes, &match?({_index, {:none, :rate_limited}}, &1))
    }
  end

  defp bucket({:placed, _place}), do: :placed
  defp bucket({:offered, _place}), do: :offered
  defp bucket({:offered, _place, _unanchored}), do: :offered
  defp bucket({:none, why}) when why in [:not_found, :no_location, :unstorable], do: :not_found
  defp bucket({:none, _why}), do: :not_looked_up

  # The place search the call's words went to, by name; none for a test's.
  defp backend_name(%{place_lookup: _search}), do: nil

  defp backend_name(context),
    do: context |> PlaceSearch.resolution() |> Map.fetch!(:name) |> Atom.to_string()

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
  The trip in its shared form, for a device's Share (`trip_share`, M89 §13):
  whole and plain (`Trips.Render.share/2`), with the rev it shows. Only a
  connection placed as the owner's asks; a removed trip has none to share.
  """
  @spec device_share(String.t(), atom() | nil, keyword()) ::
          {:ok, %{trip_id: String.t(), rev: non_neg_integer(), text: String.t()}}
          | {:error, term()}
  def device_share(trip_id, caller, opts \\ []) when is_binary(trip_id) and is_list(opts) do
    start = System.monotonic_time(:microsecond)
    made_via = KeptAccess.device_made_via!(Keyword.get(opts, :made_via, "mac"))
    context = KeptAccess.device_context()

    result =
      with :ok <- KeptAccess.device_gate(caller),
           :ok <- trip_id(trip_id),
           {:ok, %{trip: trip, rows: rows}} <- store(context, opts, {:trip_by_id, trip_id, false}),
           :ok <- live_trip(trip) do
        {:ok, %{trip_id: trip.id, rev: trip.rev, text: Render.share(trip, rows)}}
      end

    trips = if match?({:ok, _shared}, result), do: 1, else: 0
    read = %{scope: :share, trips: trips, made_via: made_via}
    Telemetry.emit_read(%{}, Map.merge(read, outcome_fields(result)), elapsed(start))
    result
  end

  defp live_trip(%{removed_at: nil}), do: :ok
  defp live_trip(%{id: id}), do: {:error, {:no_such_trip, id}}

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

  defp request(context, {:read_trip, ref}),
    do: {:read_trip, owner_id(context), agent_id(context), ref}

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

  defp emit_read(context, read, result, start) do
    event =
      read
      |> Map.put(:made_via, KeptAccess.made_via(context))
      |> Map.merge(outcome_fields(result))

    Telemetry.emit_read(context, event, elapsed(start))
  end

  defp emit_edit(context, params, {result, looked}, start) do
    trips =
      case result do
        {:ok, %{touched: touched}} -> length(touched)
        {:error, _reason} -> 0
      end

    ops = params |> Map.get("ops") |> List.wrap() |> length()
    counts = %{trips: trips, ops: ops, made_via: KeptAccess.made_via(context)}
    edit = looked |> Map.merge(counts) |> Map.merge(outcome_fields(result))
    Telemetry.emit_edit(context, edit, elapsed(start))
  end

  # A device's op gives a whole place, so it looks nothing up.
  defp emit_device_edit(result, made_via, start) do
    trips =
      case result do
        {:ok, %{duplicate: true}} -> 0
        {:ok, _changed} -> 1
        {:error, _reason} -> 0
      end

    edit = Map.merge(@no_lookups, %{trips: trips, ops: 1, made_via: made_via})
    Telemetry.emit_edit(%{}, Map.merge(edit, outcome_fields(result)), elapsed(start))
  end

  defp outcome_fields({:ok, _answer}), do: %{outcome: :ok, error_code: nil}

  defp outcome_fields({:error, reason}),
    do: %{outcome: outcome(reason), error_code: error_tag(reason)}

  defp outcome(reason) do
    if error_tag(reason) == "storage_failed", do: :failed, else: :refused
  end

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

  def describe_error(:unknown_place_link) do
    "No place search in this conversation returned that link; search again or give the " <>
      "place's name."
  end

  def describe_error(:too_many_lookups) do
    "One call looks up at most #{Lookup.max_lookups()} places; split the rest into another " <>
      "call."
  end

  def describe_error(:trip_needed),
    do: "Name the trip, by its title or id, to read a day of it or to share it."

  def describe_error({:not_a_day_run, _value}),
    do: ~s(day is a day's number from 1, or a run of days as "2-4".)

  def describe_error({:invalid_param, :as}), do: ~s(as takes only "share".)

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

  def describe_error({:device, :client_msg_id_used}) do
    "That client_msg_id already named another edit, so nothing changed; send each edit with " <>
      "an id of its own."
  end

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
