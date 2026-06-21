defmodule FermixCore.Tools.ComputerUse do
  @moduledoc """
  Control a desktop (`:host`) or browser (`:browser`) GUI by screenshot +
  mouse/keyboard, one action per call (docs/design/COMPUTER_USE.md).

  Off by default and dangerous in `:host` mode (it drives the real logged-in
  desktop). The tool is thin: it resolves the per-conversation `ComputerUse.Session`
  and the owner's confirm surface from the call context (wired by the session
  manager + agent loop), then runs each action through the session's
  classify → (confirm if consequential) → execute flow and returns the post-action
  screenshot as an image the model can see (the Phase-0 `success_with_images` path).
  Consequential actions (clicks/type/key/drag/scroll) are confirmed by a present
  human by default; read-only actions (screenshot/mouse_move/wait) auto-run.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.ComputerUse.Approval
  alias FermixCore.ComputerUse.Config
  alias FermixCore.ComputerUse.Protocol
  alias FermixCore.ComputerUse.Session
  alias FermixCore.ComputerUse.SessionManager
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

  @modifiers ~w(cmd ctrl alt shift)
  @scroll_directions ~w(up down left right)

  @impl true
  def name, do: "computer_use"

  @impl true
  def description do
    "Drive a desktop or browser GUI by screenshot + mouse/keyboard, one action per call. " <>
      "`screenshot` to see the screen, then act on it (click, type, key, scroll, drag) using " <>
      "pixel coordinates from the latest screenshot. Consequential actions need owner confirmation."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "required" => ["action"],
      "additionalProperties" => false,
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => Protocol.actions(),
          "description" =>
            "The GUI action. Read-only: screenshot, mouse_move, wait. Consequential " <>
              "(confirmed): left_click, right_click, double_click, left_click_drag, scroll, type, key."
        },
        "x" => %{
          "type" => "integer",
          "description" => "X pixel for click/move/scroll (screenshot space)"
        },
        "y" => %{
          "type" => "integer",
          "description" => "Y pixel for click/move/scroll (screenshot space)"
        },
        "display" => %{
          "type" => "integer",
          "description" => "Display index; defaults to the configured display"
        },
        "modifiers" => %{
          "type" => "array",
          "items" => %{"type" => "string", "enum" => @modifiers},
          "description" => "Held modifier keys for a click (e.g. [\"cmd\"])"
        },
        "from" => point_schema("Drag start point"),
        "to" => point_schema("Drag end point"),
        "direction" => %{
          "type" => "string",
          "enum" => @scroll_directions,
          "description" => "Scroll direction"
        },
        "amount" => %{"type" => "integer", "description" => "Scroll amount (positive)"},
        "text" => %{"type" => "string", "description" => "Text to type (for action=type)"},
        "chord" => %{
          "type" => "string",
          "description" => "Key chord for action=key, e.g. \"ctrl+s\""
        },
        "ms" => %{"type" => "integer", "description" => "Milliseconds to wait (for action=wait)"}
      }
    }
  end

  @impl true
  def when_to_use do
    "When a task needs eyes-and-hands on a GUI that has no API — clicking, typing, or " <>
      "reading rendered visual state in a desktop app or browser. Screenshot first, then act. " <>
      "Prefer the dedicated browser/file/web tools when they cover the task; this is the last resort."
  end

  @impl true
  def examples do
    [
      %{args: %{"action" => "screenshot"}, note: "look at the screen before acting"},
      %{
        args: %{"action" => "left_click", "x" => 640, "y" => 360},
        note: "click at a screenshot pixel"
      },
      %{args: %{"action" => "type", "text" => "hello"}, note: "type into the focused field"}
    ]
  end

  @impl true
  def failure_modes do
    [
      %{
        tag: "invalid action",
        description: "the action or its arguments were malformed (fail-loud)"
      },
      %{
        tag: "action not confirmed",
        description: "the owner denied, did not respond, or no owner was present (fail-closed)"
      },
      %{
        tag: "action_budget_exhausted",
        description: "the per-session action cap was reached; the session halted"
      },
      %{
        tag: "not active",
        description: "computer-use is not enabled / no attended session in this context"
      }
    ]
  end

  @impl true
  def category, do: :computer

  @impl true
  @spec execute(map(), Tool.context()) :: {:ok, Tool.tool_result()}
  def execute(params, context) when is_map(params) and is_map(context) do
    start = System.monotonic_time(:millisecond)
    result = dispatch(params, context)
    duration = System.monotonic_time(:millisecond) - start
    success = match?({:ok, %{success: true}}, result)

    ToolTelemetry.exec("computer_use", context, success, duration,
      metadata: %{action: Map.get(params, "action")},
      result: result
    )

    result
  end

  # Resolve the per-conversation session lazily: a caller may pre-place
  # `:computer_use_session` on the context (tests, a future eager path), otherwise
  # the tool starts/reuses it through `SessionManager.ensure/3` keyed by the turn's
  # `conversation_key` — so the OS-driver process opens only when the tool is actually
  # used, and is reused across actions in the same conversation. The confirm surface
  # (`:computer_use_surface`) stays optional: read-only actions never need it;
  # consequential ones fail closed without it (no_owner).
  defp dispatch(params, context) do
    config = Map.get(context, :computer_use_config) || Config.current()

    case resolve_session(context, config) do
      {:ok, session} ->
        run(session, Map.get(context, :computer_use_surface), config, params)

      {:error, reason} ->
        {:ok, Tool.error(unavailable_message(reason))}
    end
  end

  defp resolve_session(context, config) do
    case Map.get(context, :computer_use_session) do
      nil -> ensure_session(context, config)
      session -> {:ok, session}
    end
  end

  # Guard before reaching the supervisor: a hot-disabled feature (registered tool not
  # yet dropped by a restart) or a context with no conversation to key on is inert,
  # not an error. SessionManager itself fails closed on an unattended host origin and
  # a missing sidecar.
  defp ensure_session(_context, %Config{enabled?: false}), do: {:error, :not_enabled}

  defp ensure_session(context, config) do
    if Map.has_key?(context, :conversation_key),
      do: SessionManager.ensure(config, context),
      else: {:error, :no_conversation}
  end

  defp unavailable_message(reason) when reason in [:not_enabled, :no_conversation] do
    "computer-use is not active in this context — enable it and start an attended session"
  end

  defp unavailable_message({:host_start_refused, origin}) do
    "computer-use host control needs an attended session (interactive chat or voice); " <>
      "this origin (#{origin}) cannot start one"
  end

  defp unavailable_message({:sidecar_unavailable, _reason}) do
    "the computer-use helper isn't installed — install it from setup, then try again"
  end

  defp unavailable_message(reason) do
    "computer-use session unavailable: #{format_reason(reason)}"
  end

  defp run(session, surface, config, params) do
    case Session.classify(session, params) do
      {:ok, :auto, request} ->
        perform(session, request)

      {:ok, :confirm, request, desc} ->
        confirm_then_perform(session, surface, config, request, desc)

      {:error, reason} ->
        {:ok, Tool.error("invalid action: #{format_reason(reason)}")}
    end
  end

  defp confirm_then_perform(session, surface, config, request, desc) do
    case Approval.request(desc, surface, config) do
      :ok ->
        perform(session, request)

      {:error, reason} ->
        {:ok, Tool.error("action not confirmed (#{reason}); it was not performed")}
    end
  end

  defp perform(session, request) do
    case Session.execute(session, request) do
      {:ok, %{image: nil, summary: summary}} ->
        {:ok, Tool.success(summary)}

      {:ok, %{image: image, summary: summary}} ->
        {:ok, Tool.success_with_images(summary, [image])}

      {:error, reason} ->
        {:ok, Tool.error("action failed: #{format_reason(reason)}")}
    end
  end

  defp point_schema(description) do
    %{
      "type" => "object",
      "properties" => %{"x" => %{"type" => "integer"}, "y" => %{"type" => "integer"}},
      "required" => ["x", "y"],
      "description" => description
    }
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
