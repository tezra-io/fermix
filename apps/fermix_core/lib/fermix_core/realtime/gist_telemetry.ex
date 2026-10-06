defmodule FermixCore.Realtime.GistTelemetry do
  @moduledoc """
  Single emitter for `[:fermix, :voice_gist, ...]`: the gist a Live call in the
  chat leaves when it ends (M56 §4.2, §7), in the shape of the meeting
  summariser's run.

  The gist is a run kind of its own. It is made after the call has settled and
  its `call_stop` closed the call's run, by one bounded summarising call on
  the primary route chain, so it carries its own session id,
  `voice_gist:<call_uuid>`, and no `parent_session`: it is a root, tied to the
  call by `call_uuid` alone, the key of the call's record. These bookends
  bracket the run, and its provider call rides
  `Providers.Telemetry.emit_call/3` under the same session id.

  Sizes and status only: what was said on the call, the task results and the
  gist itself reach no field here. The provider call's own input and output
  follow the content switch, as every provider call's do.

  The events also route into `FermixCore.Trace` as `agent_event` rows, so a
  gist is visible in the JSONL trace stream with or without Opik.
  """

  @agent "voice_gist"
  @session_prefix "voice_gist:"
  @max_error_chars 500

  @run_start_event [:fermix, :voice_gist, :run_start]
  @run_complete_event [:fermix, :voice_gist, :run_complete]
  @run_error_event [:fermix, :voice_gist, :run_error]

  @trace_event_definitions [
    %{
      event: @run_start_event,
      trace_event: "voice_gist_run_start",
      trace_type: :agent_event,
      agent_field: :agent
    },
    %{
      event: @run_complete_event,
      trace_event: "voice_gist_run_complete",
      trace_type: :agent_event,
      agent_field: :agent
    },
    %{
      event: @run_error_event,
      trace_event: "voice_gist_run_error",
      trace_type: :agent_event,
      agent_field: :agent
    }
  ]

  @typedoc "The run's identity: its own session id and the call it is the gist of."
  @type run :: %{session_id: String.t(), call_uuid: String.t()}

  @typedoc """
  What the run summarises, by size: the call's tasks, the bytes of speech and
  of the whole input sent, and whether any of it was drawn from Computer
  History.
  """
  @type input_size :: %{
          tasks: non_neg_integer(),
          speech_bytes: non_neg_integer(),
          input_bytes: non_neg_integer(),
          tainted?: boolean()
        }

  @spec trace_event_definitions() :: [map()]
  def trace_event_definitions, do: @trace_event_definitions

  @doc "The gist run's session id for the call `call_uuid`."
  @spec session_id(String.t()) :: String.t()
  def session_id(call_uuid) when is_binary(call_uuid), do: @session_prefix <> call_uuid

  @doc "Opens the run, as its summarising call goes out."
  @spec run_start(run(), input_size()) :: :ok
  def run_start(
        run,
        %{tasks: tasks, speech_bytes: speech, input_bytes: input, tainted?: tainted?}
      )
      when is_integer(tasks) and tasks >= 0 and is_integer(speech) and speech >= 0 and
             is_integer(input) and input >= 0 and is_boolean(tainted?) do
    metadata =
      run
      |> base()
      |> Map.merge(%{tasks: tasks, speech_bytes: speech, input_bytes: input, tainted: tainted?})

    :telemetry.execute(@run_start_event, %{}, metadata)
  end

  @doc "Closes the run with the gist written: how long it took and how large it is."
  @spec run_complete(run(), %{duration_ms: non_neg_integer(), gist_bytes: non_neg_integer()}) ::
          :ok
  def run_complete(run, %{duration_ms: duration_ms, gist_bytes: gist_bytes} = measurements)
      when is_integer(duration_ms) and duration_ms >= 0 and is_integer(gist_bytes) and
             gist_bytes >= 0 do
    :telemetry.execute(@run_complete_event, measurements, Map.put(base(run), :status, "written"))
  end

  @doc """
  Closes the run with the gist failed: the reason, bounded, never the call's
  words (a reason is the run's own or the provider's).
  """
  @spec run_error(run(), term(), non_neg_integer()) :: :ok
  def run_error(run, reason, duration_ms) when is_integer(duration_ms) and duration_ms >= 0 do
    metadata =
      run
      |> base()
      |> Map.merge(%{status: "failed", error: format_error(reason)})

    :telemetry.execute(@run_error_event, %{count: 1, duration_ms: duration_ms}, metadata)
  end

  defp base(%{session_id: session_id, call_uuid: call_uuid})
       when is_binary(session_id) and is_binary(call_uuid),
       do: %{agent: @agent, session_id: session_id, call_uuid: call_uuid}

  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason) when is_binary(reason), do: String.slice(reason, 0, @max_error_chars)
  defp format_error(reason), do: reason |> inspect() |> String.slice(0, @max_error_chars)
end
