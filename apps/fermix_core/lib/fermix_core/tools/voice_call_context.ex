defmodule FermixCore.Tools.VoiceCallContext do
  @moduledoc """
  Read the GPT-Live call in progress in the chat (M56 §4.4, D7).

  A message typed during a call may refer to it ("what did I ask you to do on
  the call?"). This is how the turn reads it: when the call started and how
  long it has run, the tasks handed off on it with their states and summaries
  (the call's record), and the newest speech, about 4 KB of what the session
  heard for the whole call (`CallSpeech`), framed as untrusted, possibly
  misheard speech.

  Offered only while a call in the chat is up (`VoiceBridge.call_active?/0`),
  and re-checked at execution: the call is found in Core's `CallRegistry`, a
  private call is no call in the chat, and the session is asked with a one
  second bound, so a call still settling is an error result rather than a
  turn left waiting. Never named in the capability catalog: the catalog is
  cached per profile and cannot follow a call, so the line a typed turn is
  told during a call names it instead (`LiveCallTurn`).

  Its telemetry carries sizes only: what was said reaches no telemetry field.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Capabilities.UntrustedContent
  alias FermixCore.Realtime.CallRegistry
  alias FermixCore.Realtime.CallSpeech
  alias FermixCore.Realtime.LiveSessionServer
  alias FermixCore.Realtime.VoiceBridge
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

  @answer_timeout_ms 1_000
  @speech_max_bytes 4_096

  @no_call "No voice call is in progress in this chat."
  @no_answer "The voice call did not answer within a second; it may be ending. Try again " <>
               "once it has ended or settled."

  @impl true
  @spec name() :: String.t()
  def name, do: "voice_call_context"

  @impl true
  @spec description() :: String.t()
  def description do
    "Read the voice call in progress in this chat: when it started, how long it has run, " <>
      "the tasks handed off on it with their states and summaries, and the newest speech " <>
      "as speech recognition heard it, possibly misheard. Read-only."
  end

  @impl true
  @spec parameters() :: map()
  def parameters, do: %{type: "object", properties: %{}}

  @impl true
  def when_to_use do
    "During a voice call in this chat, when a typed message refers to what was said, " <>
      "asked or done on the call."
  end

  @impl true
  def failure_modes do
    [
      %{tag: "no_call", description: "no voice call in this chat is in progress"},
      %{tag: "no_answer", description: "the call did not answer within a second"}
    ]
  end

  @impl true
  def category, do: :memory

  @doc "Offered only while a call in the chat is up."
  @spec advertise?(map()) :: boolean()
  def advertise?(context) when is_map(context) do
    case voice_bridge(context) do
      {:ok, bridge} -> bridge.call_active?()
      {:error, :voice_bridge_unavailable} -> false
    end
  end

  @impl true
  @spec execute(map(), Tool.context()) :: {:ok, Tool.tool_result()}
  def execute(args, context) when is_map(args) and is_map(context) do
    start = System.monotonic_time(:millisecond)
    {result, metadata} = read(Map.get(context, :call_registry, CallRegistry))
    duration = System.monotonic_time(:millisecond) - start
    success = match?({:ok, %{success: true}}, result)

    ToolTelemetry.exec(name(), context, success, duration, input: args, metadata: metadata)
    result
  end

  defp read(registry) do
    with {:ok, session} <- chat_session(registry),
         {:ok, call} <- ask(session) do
      {{:ok, Tool.success(render(call))}, sizes(call)}
    else
      {:error, tag, message} -> {{:ok, Tool.error(message)}, %{error: tag}}
    end
  end

  defp chat_session(registry) do
    case CallRegistry.active(registry) do
      {:ok, %{conversation: "chat", session: session}} -> {:ok, session}
      _no_call_or_private -> {:error, "no_call", @no_call}
    end
  end

  # The session gone between the lookup and the call is no call; one busy
  # past the bound (settling, closing its provider session) did not answer.
  defp ask(session) do
    LiveSessionServer.call_context(session, @answer_timeout_ms)
  catch
    :exit, {:timeout, _call} -> {:error, "no_answer", @no_answer}
    :exit, _gone -> {:error, "no_call", @no_call}
  end

  defp render(call) do
    Enum.join([heading(call), tasks(call.tasks), speech(call.speech)], "\n\n")
  end

  defp heading(call) do
    "A voice call in this chat started at " <>
      (call.started_at |> DateTime.shift_zone!("Etc/UTC") |> Calendar.strftime("%Y-%m-%d %H:%M")) <>
      " UTC and has run #{elapsed(call.elapsed_ms)}."
  end

  defp elapsed(ms) do
    seconds = div(ms, 1_000)
    "#{div(seconds, 60)} min #{rem(seconds, 60)} s"
  end

  defp tasks([]), do: "No task has been handed off on this call."

  defp tasks(tasks) do
    "Tasks handed off on the call, oldest first:\n" <> Enum.map_join(tasks, "\n", &task_line/1)
  end

  defp task_line(%{"task_id" => id, "revision" => revision, "state" => state} = task) do
    "- #{id} (revision #{revision}): #{state}." <> summary(Map.get(task, "summary"))
  end

  defp summary(nil), do: ""
  defp summary(text), do: " " <> text

  defp speech(speech) do
    case CallSpeech.text(speech, @speech_max_bytes) do
      "" ->
        "Nothing has been said on the call yet."

      said ->
        "What has been said, newest last, as speech recognition heard it, possibly " <>
          "misheard (the newest #{@speech_max_bytes} bytes at most):\n" <>
          UntrustedContent.frame(name(), said)
    end
  end

  defp sizes(call) do
    %{tasks: length(call.tasks), speech_bytes: byte_size(CallSpeech.text(call.speech))}
  end

  defp voice_bridge(%{voice_bridge: bridge}) when is_atom(bridge) and not is_nil(bridge),
    do: {:ok, bridge}

  defp voice_bridge(_context), do: VoiceBridge.resolve()
end
