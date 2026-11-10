defmodule FermixCore.Computers.Telemetry do
  @moduledoc """
  The one emitter of `[:fermix, :computer_invocation, ...]`: an invocation
  as the computer that runs it sees it (M97 §6.2), a run kind with its own
  bookends (docs/TELEMETRY_CONTRACT.md, *Computer invocations*).

  The run is `session_id = "inv_<id>"`, always a **root** on the computer's
  own trace: the turn that asked is on the server's, so its session rides as
  `parent_session`, correlation metadata only, as computer use does. Every
  invocation the computer answers opens with `:start` and closes with one
  bookend: `:complete` for `ok`, `cancelled` and `refused`, `:error` for
  `failed`, `timed_out` and `unknown`. A refusal is emitted before the
  answer goes.

  Measurements: `duration_ms`, and on a bookend `result_bytes`. Metadata, a
  fixed allowlist: `session_id`, `parent_session`, `capability`, `op`,
  `origin`, `epoch`, and on a bookend `status` and `refusal`. Never the
  args, the result or the target: those are content, and the journal holds
  the target. `Trace.TelemetryHandler` appends `trace_event_definitions/0`,
  and `FermixOpik` maps the run (`infer_kind("inv_" <> _)`).

  On the server an invocation is one tool exec under the turn's own session
  (`Outcome.exec_metadata/1`), as every tool call is.
  """

  alias FermixCore.Computers.Outcome

  @prefix "inv_"
  @complete [:ok, :cancelled, :refused]
  @allowed [:session_id, :parent_session, :capability, :op, :origin, :epoch]

  @trace_event_definitions [
    %{
      event: [:fermix, :computer_invocation, :start],
      trace_event: "computer_invocation_start",
      trace_type: :agent_event,
      agent_field: :capability
    },
    %{
      event: [:fermix, :computer_invocation, :complete],
      trace_event: "computer_invocation_complete",
      trace_type: :agent_event,
      agent_field: :capability
    },
    %{
      event: [:fermix, :computer_invocation, :error],
      trace_event: "computer_invocation_error",
      trace_type: :agent_event,
      agent_field: :capability
    }
  ]

  @typedoc "What one invocation's events carry (the moduledoc's allowlist)."
  @type meta :: %{
          required(:id) => String.t(),
          required(:capability) => String.t(),
          required(:op) => String.t(),
          required(:origin) => atom(),
          required(:epoch) => pos_integer(),
          optional(:parent_session) => String.t() | nil
        }

  @doc "The JSONL trace rows of this family, for `Trace.TelemetryHandler`."
  @spec trace_event_definitions() :: [map()]
  def trace_event_definitions, do: @trace_event_definitions

  @doc "The session id of the invocation `id`'s run: `inv_<id>`."
  @spec session_id(String.t()) :: String.t()
  def session_id(id) when is_binary(id), do: @prefix <> id

  @doc "The invocation opens."
  @spec started(meta()) :: :ok
  def started(meta) when is_map(meta),
    do: :telemetry.execute([:fermix, :computer_invocation, :start], %{duration_ms: 0}, base(meta))

  @doc "The invocation ended with `outcome`, its result `result_bytes` long."
  @spec finished(meta(), Outcome.t(), non_neg_integer()) :: :ok
  def finished(meta, %Outcome{status: status} = outcome, result_bytes)
      when is_map(meta) and is_integer(result_bytes) and result_bytes >= 0 do
    name = if status in @complete, do: :complete, else: :error

    metadata =
      meta
      |> base()
      |> Map.put(:status, status)
      |> put_some(:refusal, outcome.refusal)

    :telemetry.execute(
      [:fermix, :computer_invocation, name],
      %{duration_ms: outcome.duration_ms, result_bytes: result_bytes},
      metadata
    )
  end

  defp base(meta) do
    meta
    |> Map.put(:session_id, session_id(Map.fetch!(meta, :id)))
    |> Map.take(@allowed)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp put_some(map, _key, nil), do: map
  defp put_some(map, key, value), do: Map.put(map, key, value)
end
