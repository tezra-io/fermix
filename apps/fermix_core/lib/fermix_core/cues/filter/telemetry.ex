defmodule FermixCore.Cues.Filter.Telemetry do
  @moduledoc """
  Single emitter for `[:fermix, :cue_filter, ...]`: the bookends of one filter
  call (M60 §14), a run kind of its own.

  A filter call is one bounded model call for one cue, in the shape of a Live
  call's gist: it mints its own session id,
  `cue_filter_<watcher_id>_<YYYYMMDD_HHMMSS>_<6 hex>`, and has no
  `parent_session`, because no turn asked for it. `run_start` opens it as the
  call goes out; the provider call rides `Providers.Telemetry.emit_call/3`
  under the same session id; the filter-scoped `[:fermix, :cue, :lifecycle]`
  phases (`passed`, `dropped`, `filter_retry`, `filter_held`, `filter_failed`)
  carry it too; and one closer ends it, after the decision is written:
  `run_complete` with the decision, or `run_error` with what went wrong.

  Ids, labels and sizes only: the cue's text, the decision's reason and the
  hint never reach a field here (the provider call's own input and output follow
  the content switch, as every provider call's do).

  The events also route into `FermixCore.Trace` as `agent_event` rows.
  """

  @agent "cue_filter"
  @session_prefix "cue_filter_"

  @run_start_event [:fermix, :cue_filter, :run_start]
  @run_complete_event [:fermix, :cue_filter, :run_complete]
  @run_error_event [:fermix, :cue_filter, :run_error]

  @error_statuses [:provider_failure, :content_failure, :aborted, :stale, :settle_failed]

  @trace_event_definitions [
    %{
      event: @run_start_event,
      trace_event: "cue_filter_run_start",
      trace_type: :agent_event,
      agent_field: :agent
    },
    %{
      event: @run_complete_event,
      trace_event: "cue_filter_run_complete",
      trace_type: :agent_event,
      agent_field: :agent
    },
    %{
      event: @run_error_event,
      trace_event: "cue_filter_run_error",
      trace_type: :agent_event,
      agent_field: :agent
    }
  ]

  @typedoc "What every bookend names: the call, its session and the delivery it decides."
  @type run :: %{
          required(:session_id) => String.t(),
          required(:call_id) => String.t(),
          required(:watcher_id) => String.t(),
          required(:delivery_id) => pos_integer(),
          required(:cue_id) => pos_integer(),
          required(:source_ref) => String.t(),
          optional(:attempt) => non_neg_integer(),
          optional(:provider) => String.t() | nil,
          optional(:model) => String.t() | nil
        }

  @spec trace_event_definitions() :: [map()]
  def trace_event_definitions, do: @trace_event_definitions

  @doc "The agent name every filter call's events and provider call carry."
  @spec agent() :: String.t()
  def agent, do: @agent

  @doc "The prefix of every filter call's session id."
  @spec session_prefix() :: String.t()
  def session_prefix, do: @session_prefix

  @doc "A new session id for a filter call of `watcher_id` started at `now`."
  @spec session_id(String.t(), DateTime.t()) :: String.t()
  def session_id(watcher_id, %DateTime{} = now) when is_binary(watcher_id) and watcher_id != "" do
    suffix = Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)
    "#{@session_prefix}#{watcher_id}_#{Calendar.strftime(now, "%Y%m%d_%H%M%S")}_#{suffix}"
  end

  @doc "Opens the run as its model call goes out."
  @spec run_start(run()) :: :ok
  def run_start(run) when is_map(run) do
    :telemetry.execute(@run_start_event, %{count: 1}, base(run))
  end

  @doc "Closes the run with the decision written: `:pass` or `:drop`."
  @spec run_complete(run(), :pass | :drop, non_neg_integer()) :: :ok
  def run_complete(run, decision, duration_ms)
      when decision in [:pass, :drop] and is_integer(duration_ms) and duration_ms >= 0 do
    metadata = Map.merge(base(run), %{status: "ok", decision: Atom.to_string(decision)})
    :telemetry.execute(@run_complete_event, %{count: 1, duration_ms: duration_ms}, metadata)
  end

  @doc """
  Closes the run without a decision: `status` says which wall it hit
  (`:provider_failure`, `:content_failure`, `:aborted`, `:stale` when the row
  had moved on, `:settle_failed` when the write itself failed) and `kind` is the
  failure's typed kind, never a message.
  """
  @spec run_error(run(), atom(), atom(), non_neg_integer()) :: :ok
  def run_error(run, status, kind, duration_ms)
      when status in @error_statuses and is_atom(kind) and is_integer(duration_ms) and
             duration_ms >= 0 do
    metadata =
      Map.merge(base(run), %{status: Atom.to_string(status), error_kind: Atom.to_string(kind)})

    :telemetry.execute(@run_error_event, %{count: 1, duration_ms: duration_ms}, metadata)
  end

  defp base(%{session_id: session_id, call_id: call_id, watcher_id: watcher_id} = run)
       when is_binary(session_id) and is_binary(call_id) and is_binary(watcher_id) do
    %{
      agent: @agent,
      session_id: session_id,
      filter_call_id: call_id,
      watcher_id: watcher_id,
      delivery_id: Map.fetch!(run, :delivery_id),
      cue_id: Map.fetch!(run, :cue_id),
      source_ref: Map.fetch!(run, :source_ref),
      attempt: Map.get(run, :attempt),
      provider: Map.get(run, :provider),
      model: Map.get(run, :model)
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end
end
