defmodule FermixCore.Tools.TripEdit do
  @moduledoc """
  Make and change the owner's trips (M89 §04): one call is one trip, its ops
  by row number, and `Trips.Registry` applies the whole call in one
  transaction, at most 100 ops, or none of it. A stop's `place` is its own
  name or a link a place search in this conversation returned; Fermix looks a
  name up itself, at most 40 a call, near the day's or the trip's `near`,
  else around the stop's day (D10, D11), and the answer says what each came
  to: placed, offered by another name or with no place to search near, with
  its link, or not placed and why. The answer is the trip's line, never the
  whole trip.

  After outside content every op runs (D9), and a stop the call adds or gives
  words, a note or a place is stamped (`Trips.Ops`). A stamped stop's words
  come back framed as data in the answer, as a read frames them, and neither
  brings the turn an outside source, as the engine's own lookups bring none
  (C1): their names and addresses are quoted as a provider's words.

  Offered and run only where `Kept.Access.permitted?/2` admits it. Every trip
  the call touched is recorded for the reply's block with the rows it added
  or changed (`ReplyBlocks.put_trips/3`). A turn that was not told how its
  channel shows a trip has the channel's line after the answer
  (`TripRead.channel_line/2`).

  Context seams: `:memory_repo`, `:reply_blocks`, `:now_fn` and
  `:place_lookup` (the place search, `Trips.Lookup.backend/1`).
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Kept.Access
  alias FermixCore.Memory.Repo
  alias FermixCore.ReplyBlocks
  alias FermixCore.Telemetry
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry
  alias FermixCore.Tools.TripRead
  alias FermixCore.Trips.Registry

  @impl true
  @spec name() :: String.t()
  def name, do: "trip_edit"

  @impl true
  @spec description() :: String.t()
  def description do
    "Make and change the owner's trips as the owner asks; a call lands whole or not at " <>
      "all. Every stop at a place gives place: the place's own name, never the activity, or " <>
      "a link a search returned; a stop without one is never looked up. Give near when " <>
      "making a trip: a town or city and its country, like Lisbon, Portugal, never a " <>
      "country, a region, a district or a landmark; a day in a different town from the " <>
      "trip's gets its own near. Places are looked up within it. An unknown country is no " <>
      "reason to wait: make the trip without a near, and ask the owner for the town and its " <>
      "country."
  end

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      type: "object",
      required: ["trip", "ops"],
      properties: %{
        trip: %{type: "string", description: "Title or id; a new trip's title."},
        ops: %{type: "array", maxItems: Registry.max_ops(), items: op_schema()}
      }
    }
  end

  defp op_schema do
    %{
      type: "object",
      required: ["op"],
      properties: %{
        op: %{
          type: "string",
          enum: Registry.ops(),
          description:
            "create (title?, starts_on?, days?, timezone?, near?) first. add (text; day or " <>
              "after; time?, duration?, fixed?, note?, place?). edit (n; any of those; \"\" or " <>
              "0 clears). move (n; day or after; a day's n moves the day). day (day; text?, " <>
              "timezone?, near?). remove (n). rename (text). dates (starts_on or \"\")."
        },
        n: %{type: "integer"},
        day: %{type: "integer"},
        after: %{type: "integer"},
        text: %{type: "string"},
        time: %{type: "string", description: "HH:MM"},
        duration: %{type: "integer", description: "Minutes."},
        fixed: %{type: "boolean"},
        note: %{type: "string"},
        place: %{type: "string"},
        near: %{type: "string"},
        title: %{type: "string"},
        starts_on: %{type: "string", description: "YYYY-MM-DD"},
        days: %{type: "integer"},
        timezone: %{type: "string", description: "IANA"}
      }
    }
  end

  @impl true
  def when_to_use, do: "Make or change the owner's trips: their days, and stops with places."

  @impl true
  def failure_modes do
    [
      %{tag: "no_trip", description: "no live trip has that title or id"},
      %{tag: "no_row", description: "the trip has no row with that number"},
      %{tag: "not_a_day", description: "a day op named a stop"},
      %{tag: "not_a_stop", description: "a stop op named a day"},
      %{tag: "title_taken", description: "another live trip has that title"},
      %{tag: "trip_full", description: "the trip holds 1000 days and stops"},
      %{tag: "too_many_trips", description: "the owner keeps 30 trips"},
      %{tag: "too_many_ops", description: "one call carries at most 100 ops"},
      %{tag: "too_many_lookups", description: "one call looks up at most 40 places"},
      %{
        tag: "unknown_place_link",
        description: "a place's link no place search in this conversation returned"
      },
      %{tag: "last_day", description: "a trip keeps at least one day"},
      %{
        tag: "not_permitted",
        description: "not the owner's private turn, and not a job naming it"
      }
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :scheduling

  @doc "Offered where `Kept.Access.permitted?/2` admits it; `execute/2` asks again."
  @spec advertise?(map()) :: boolean()
  def advertise?(context) when is_map(context), do: Access.permitted?(context, name())

  @impl true
  @spec execute(map(), Tool.context()) :: {:ok, Tool.tool_result()}
  def execute(args, context) when is_map(args) and is_map(context) do
    start = System.monotonic_time(:millisecond)
    {result, error} = edit(args, context)
    duration = System.monotonic_time(:millisecond) - start
    success = match?({:ok, %{success: true}}, result)

    ToolTelemetry.exec(name(), context, success, duration,
      input: args,
      result: result,
      metadata: error
    )

    result
  end

  defp edit(args, context) do
    holder = Map.get(context, :reply_blocks, ReplyBlocks)
    opts = [repo: Map.get(context, :memory_repo, Repo), reply_blocks: holder] ++ clock(context)

    case Registry.edit(Map.take(args, ["trip", "ops"]), context, opts) do
      {:ok, %{text: text, touched: touched}} ->
        :ok = ReplyBlocks.put_trips(holder, Map.fetch!(context, :conversation_key), touched)
        {{:ok, Tool.success(text <> TripRead.channel_line(context, touched))}, %{}}

      {:error, reason} ->
        refused(reason)
    end
  end

  defp refused(reason) do
    sentence = Registry.describe_error(reason)
    error = %{error_code: Registry.error_tag(reason), error_summary: Telemetry.preview(sentence)}
    {{:ok, Tool.error(sentence)}, error}
  end

  defp clock(%{now_fn: now_fn}) when is_function(now_fn, 0), do: [now: now_fn.()]
  defp clock(_context), do: []
end
