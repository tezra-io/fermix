defmodule FermixCore.Tools.React do
  @moduledoc """
  React to the user's current message with a single fitting emoji through the
  active channel reply port — the low-noise way to acknowledge a pure "ok"/
  "thanks"/"got it" without sending a fresh text bubble.

  Channel-blind by construction: the gateway resolves the active channel's
  reaction capability to plain data (`context.reaction_spec`) exactly like it
  resolves `typing_fn`/`stream_spec`. Two turn-scoped hooks read that data:

    * `advertise?/1` — the tool is only offered to the model when a reaction
      capability was resolved. On a no-reaction channel (CLI) the tool is
      absent and the model just sends a short text ack in the same one call
      (docs/design/EMOJI_REACTION_ACKS.md §6/§11 Config B). No runtime
      try-react-then-degrade branch (CLAUDE.md #12).

    * `dynamic_parameters/1` — on a restricted platform (Telegram) the `emoji`
      parameter is an in-schema enum of exactly the channel's allowed set, so
      the model's thoughtful choice is *always valid* — the unsupported-emoji
      failure mode is removed by construction, not handled by a fallback.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Reply
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

  @impl true
  @spec name() :: String.t()
  def name, do: "react"

  @impl true
  @spec description() :: String.t()
  def description do
    "React to the user's current message with a single fitting emoji instead of " <>
      "sending a text reply. For pure acknowledgements that need no answer."
  end

  @impl true
  @spec parameters() :: map()
  def parameters do
    # Registration-time fallback schema. `dynamic_parameters/1` refines the
    # `emoji` property per turn from `context.reaction_spec` (an enum on
    # restricted channels). The tool is only advertised when that spec exists.
    %{
      type: "object",
      required: ["emoji"],
      properties: %{
        emoji: %{
          type: "string",
          description: "A single emoji to react with, chosen to fit the message."
        }
      }
    }
  end

  @doc """
  Per-turn schema: on a restricted channel the `emoji` property becomes an enum
  of exactly the allowed reaction set, so the model can only pick a supported
  glyph. On an `:any`-emoji channel it stays a free-form single-emoji string.
  Discovered via `function_exported?` at `AgentLoop.refresh_dynamic_schemas`.
  """
  @spec dynamic_parameters(map()) :: map()
  def dynamic_parameters(context) when is_map(context) do
    %{
      type: "object",
      required: ["emoji"],
      properties: %{emoji: emoji_schema(reaction_spec(context))}
    }
  end

  @doc """
  Advertise the tool only for a turn whose channel resolved a reaction
  capability. Discovered via `function_exported?` at `AgentLoop.build_state`.
  """
  @spec advertise?(map()) :: boolean()
  def advertise?(context) when is_map(context), do: not is_nil(reaction_spec(context))

  @doc """
  A reaction IS the reply and ends the turn. When it delivers as the sole tool
  call with no accompanying text, the agent loop skips the continuation LLM call
  (there is nothing left to ask the model) — halving ack-turn latency. Discovered
  via `function_exported?`; only honored on a *successful* delivery, so a failed
  reaction still continues and lets the model recover with a text ack.
  """
  @spec terminal?() :: boolean()
  def terminal?, do: true

  @impl true
  def when_to_use do
    ~s|When a message is a pure acknowledgement or closing pleasantry that needs | <>
      ~s|no answer ("ok", "thanks", "got it", "sounds good", 👍): react with a | <>
      ~s|fitting emoji instead of drafting text.|
  end

  @impl true
  def examples do
    [
      %{args: %{"emoji" => "👍"}, note: "acknowledge a plain \"ok\""},
      %{args: %{"emoji" => "🎉"}, note: "celebrate \"we shipped it\""}
    ]
  end

  @impl true
  def failure_modes do
    [
      %{tag: "reply_fn_required", description: "no active channel reply function is available"},
      %{
        tag: "reaction_unsupported",
        description: "the active channel does not support reactions"
      },
      %{tag: "unsupported_emoji", description: "the emoji is not accepted by the channel"}
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :channel

  @impl true
  @spec execute(map(), Tool.context()) :: {:ok, Tool.tool_result()}
  def execute(args, context) when is_map(args) and is_map(context) do
    start = System.monotonic_time(:millisecond)

    result =
      case do_execute(args, context) do
        {:ok, emoji} -> {:ok, Tool.success("Reacted with #{emoji}")}
        {:error, reason} -> {:ok, Tool.error(reason)}
      end

    duration = System.monotonic_time(:millisecond) - start
    success = match?({:ok, %{success: true}}, result)

    ToolTelemetry.exec("react", context, success, duration, input: args, result: result)

    result
  end

  defp do_execute(args, context) do
    with {:ok, reply_fn} <- reply_fn(context),
         {:ok, emoji} <- emoji(args),
         :ok <- deliver(reply_fn, emoji) do
      {:ok, emoji}
    end
  end

  defp reply_fn(%{reply_fn: reply_fn}) when is_function(reply_fn, 1), do: {:ok, reply_fn}
  defp reply_fn(_context), do: {:error, "react requires a channel reply context"}

  defp emoji(%{"emoji" => emoji}) when is_binary(emoji) and emoji != "", do: {:ok, emoji}
  defp emoji(_args), do: {:error, "Missing required parameter: emoji"}

  defp deliver(reply_fn, emoji) do
    case reply_fn.({:react, emoji}) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, "Failed to react: #{Reply.format_delivery_error(reason)}"}

      other ->
        {:error, "Failed to react: invalid reply result #{inspect(other)}"}
    end
  end

  defp reaction_spec(context), do: Map.get(context, :reaction_spec)

  defp emoji_schema(%{emoji_set: set}) when is_list(set) and set != [] do
    %{
      type: "string",
      enum: set,
      description: "The emoji to react with. Pick the one that best fits the message."
    }
  end

  defp emoji_schema(_spec) do
    %{
      type: "string",
      description: "A single emoji to react with, chosen to fit the message."
    }
  end
end
