defmodule FermixCore.Tools.OpenLoopRespond do
  @moduledoc """
  The check-in run's only exit (MILESTONE_78 §04 stage 3, §07, §18 "How the
  outcome tool works").

  The run's loop context carries `open_loop_checkin: %{id, reply_to, ref}`, and
  that key is the whole gate: this tool is offered and runs only when it is
  present (and `[fermix_core.open_loops] enabled`), while the main-agent tools
  refuse when it is, so neither surface reaches the other.

  `execute/2` validates the decision against its bounds, then sends

      {:open_loop_respond, ref, %{decision: :speak | :silent | :close,
                                  message: String.t() | nil,
                                  reason: String.t() | nil}}

  to `reply_to` and tells the model the run ends here. A spoken message is at
  most `OpenLoops.Defaults.message_max_bytes/0` bytes, measured in bytes, and a
  longer one is refused, never cut; a close reason is at most
  `OpenLoops.Defaults.reason_max/0` characters. Every accepted call is sent:
  keeping the first decision and ignoring a later one is the check-in
  process's, which owns the run.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.OpenLoops.Access
  alias FermixCore.OpenLoops.Config
  alias FermixCore.OpenLoops.Defaults
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

  @decisions %{"speak" => :speak, "silent" => :silent, "close" => :close}

  @type decision :: %{
          decision: :speak | :silent | :close,
          message: String.t() | nil,
          reason: String.t() | nil
        }

  @impl true
  @spec name() :: String.t()
  def name, do: "open_loop_respond"

  @impl true
  @spec description() :: String.t()
  def description do
    "Report this check-in's decision. speak, with the message text, when one short message " <>
      "would help the owner now; silent when it would not; close, with a reason, when the " <>
      "owner has already reported this loop settled elsewhere. Exactly one call ends the run."
  end

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      type: "object",
      required: ["decision"],
      properties: %{
        decision: %{
          type: "string",
          enum: ["speak", "silent", "close"],
          description:
            "speak: send the message. silent: send nothing now. close: the owner already " <>
              "reported this settled, as memory shows."
        },
        message: %{
          type: "string",
          description:
            "With speak: the message to the owner, one or two sentences. At most 1,800 bytes; " <>
              "a longer message is refused, not cut."
        },
        reason: %{
          type: "string",
          description:
            "With close: in a few words, what memory holds that settles it. At most 240 " <>
              "characters."
        }
      }
    }
  end

  @impl true
  def when_to_use, do: "End an open-loop check-in run with its one decision."

  @impl true
  def examples do
    [
      %{args: %{"decision" => "silent"}, note: "nothing would help the owner now"},
      %{
        args: %{"decision" => "close", "reason" => "owner said on Tuesday it was sent"},
        note: "memory shows the owner already settled it"
      }
    ]
  end

  @impl true
  def failure_modes do
    [
      %{tag: "invalid_decision", description: "decision is not speak, silent or close"},
      %{tag: "missing_message", description: "speak needs the message text"},
      %{tag: "message_too_long", description: "the message is over 1,800 bytes; never cut"},
      %{tag: "missing_reason", description: "close needs the reason memory holds"},
      %{tag: "reason_too_long", description: "the reason is over 240 characters"},
      %{tag: "not_checkin", description: "the turn is not an open-loop check-in run"},
      %{tag: "disabled", description: "open loops are turned off on this install"}
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :scheduling

  @doc """
  Offered only while open loops are enabled, inside a check-in run; the same
  gate re-runs inside `execute/2`.
  """
  @spec advertise?(map()) :: boolean()
  def advertise?(context) when is_map(context), do: gate(context) == :ok

  @impl true
  @spec execute(map(), Tool.context()) :: {:ok, Tool.tool_result()}
  def execute(args, context) when is_map(args) and is_map(context) do
    start = System.monotonic_time(:millisecond)
    result = gated(args, context)
    duration = System.monotonic_time(:millisecond) - start
    success = match?({:ok, %{success: true}}, result)

    ToolTelemetry.exec(name(), context, success, duration, input: args, result: result)
    result
  end

  defp gate(context) do
    cond do
      not Config.enabled?() -> {:error, :disabled}
      not Access.checkin?(context) -> {:error, :not_checkin}
      true -> :ok
    end
  end

  defp gated(args, context) do
    case gate(context) do
      :ok -> respond(args, context)
      {:error, reason} -> {:ok, Tool.error(Access.refusal(name(), reason))}
    end
  end

  defp respond(args, context) do
    case decision(args) do
      {:ok, decision} ->
        :ok = report(context, decision)
        {:ok, Tool.success(ended(decision))}

      {:error, reason} ->
        {:ok, Tool.error(describe_error(reason))}
    end
  end

  # The one side effect: the decision goes to the check-in process that owns
  # the run. A check-in context without a live reply address is a broken run,
  # so it fails loud here rather than reporting a decision nobody receives.
  defp report(%{open_loop_checkin: %{reply_to: reply_to, ref: ref}}, decision)
       when is_pid(reply_to) and is_reference(ref) do
    send(reply_to, {:open_loop_respond, ref, decision})
    :ok
  end

  defp decision(args) do
    case Map.fetch(@decisions, Map.get(args, "decision")) do
      {:ok, :speak} -> speak(Map.get(args, "message"))
      {:ok, :silent} -> {:ok, %{decision: :silent, message: nil, reason: nil}}
      {:ok, :close} -> close(Map.get(args, "reason"))
      :error -> {:error, {:invalid_decision, Map.get(args, "decision")}}
    end
  end

  defp speak(message) when is_binary(message) do
    text = String.trim(message)
    bytes = byte_size(text)

    cond do
      text == "" -> {:error, :missing_message}
      bytes > Defaults.message_max_bytes() -> {:error, {:message_too_long, bytes}}
      true -> {:ok, %{decision: :speak, message: text, reason: nil}}
    end
  end

  defp speak(_absent), do: {:error, :missing_message}

  defp close(reason) when is_binary(reason) do
    text = String.trim(reason)

    cond do
      text == "" -> {:error, :missing_reason}
      String.length(text) > Defaults.reason_max() -> {:error, :reason_too_long}
      true -> {:ok, %{decision: :close, message: nil, reason: text}}
    end
  end

  defp close(_absent), do: {:error, :missing_reason}

  defp ended(%{decision: decision}) do
    "Decision #{decision} recorded. This check-in run ends here: make no further tool calls " <>
      "and write no reply."
  end

  defp describe_error({:invalid_decision, decision}) do
    "#{inspect(decision)} is not a decision; call again with decision speak, silent or close."
  end

  defp describe_error(:missing_message) do
    "speak needs message, the text to send the owner; call again with it, or decide silent."
  end

  defp describe_error({:message_too_long, bytes}) do
    "The message is #{bytes} bytes and must be at most #{Defaults.message_max_bytes()} " <>
      "bytes; it is never cut, so call again with a shorter one."
  end

  defp describe_error(:missing_reason) do
    "close needs reason, what memory holds that settles the loop; call again with it."
  end

  defp describe_error(:reason_too_long) do
    "The reason must be at most #{Defaults.reason_max()} characters; call again with a " <>
      "few words."
  end
end
