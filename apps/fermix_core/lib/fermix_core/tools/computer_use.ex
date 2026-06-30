defmodule FermixCore.Tools.ComputerUse do
  @moduledoc """
  Control the host desktop GUI by screenshot + mouse/keyboard, one action per call
  (docs/design/COMPUTER_USE_V2.md).

  Off by default and dangerous: it drives the real logged-in desktop. The tool is
  thin: it resolves the per-conversation `ComputerUse.Session`
  from the call context (started lazily by the session manager), then runs each
  action through the session's classify → execute flow and returns the post-action
  screenshot as an image the model can see (the Phase-0 `success_with_images` path).

  Safety is the `access` posture (COMPUTER_USE.md §14): `:strict` refuses mutating
  actions (look only — the one deterministic floor); `:standard`/`:open` run them.
  `:standard`'s "confirm before something irreversible" is a PROMPT principle the
  agent applies itself (it sees the screen) — surfaced in the live action schema via
  `dynamic_parameters/1` — not a per-action gate. There is no blocking confirmation.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
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
    "Drive the host desktop GUI by screenshot + mouse/keyboard, one action per call. " <>
      "`screenshot` to see the screen, then act on it (click, type, key, scroll, drag) using " <>
      "pixel coordinates from the latest screenshot. For a SMALL or dense target, zoom first: " <>
      "`screenshot` with a `region` around it, then click/drag with the SAME region using the " <>
      "coordinates you read in the magnified crop — clicks land far more accurately. Every " <>
      "mutating action returns a fresh screenshot: CHECK it and retry if the click missed. " <>
      "`inspect` (read-only) reports the UI element under a point — its role and label — so you " <>
      "can confirm you're about to click the right control (e.g., a button labeled \"Delete\") " <>
      "before a consequential action. Honor " <>
      "the access mode shown on the `action` parameter: standard confirms before anything " <>
      "irreversible; open acts autonomously but still confirms a truly dangerous/catastrophic " <>
      "action; strict is look-only."
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
          "description" => base_action_description()
        },
        "x" => %{
          "type" => "integer",
          "description" => "X pixel for click/move/scroll/inspect (screenshot space)"
        },
        "y" => %{
          "type" => "integer",
          "description" => "Y pixel for click/move/scroll/inspect (screenshot space)"
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
        "ms" => %{"type" => "integer", "description" => "Milliseconds to wait (for action=wait)"},
        "region" => %{
          "type" => "object",
          "properties" => %{
            "x" => %{"type" => "integer"},
            "y" => %{"type" => "integer"},
            "w" => %{"type" => "integer"},
            "h" => %{"type" => "integer"}
          },
          "required" => ["x", "y", "w", "h"],
          "description" =>
            "Optional zoom: a rectangle {x,y,w,h} in the CURRENT full screenshot's pixel space. " <>
              "On `screenshot` it returns a magnified crop of that rectangle; on a " <>
              "click/move/drag/scroll, pass the SAME region and give x,y in the magnified image " <>
              "to act precisely on a small target."
        }
      }
    }
  end

  # Per-turn schema refresh (called by the agent loop when present): fold the LIVE
  # access mode + its guidance into the `action` description so the model knows the
  # current posture — strict (look only), standard (confirm destructive), or open
  # (autonomous). This is how the prompt-driven §14 confirm principle reaches the
  # model without a cached prompt section that would freeze on config change.
  @spec dynamic_parameters(map()) :: map()
  def dynamic_parameters(_context) do
    put_in(
      parameters(),
      ["properties", "action", "description"],
      action_description(Config.current().access)
    )
  end

  @impl true
  def when_to_use do
    "When a task needs eyes-and-hands on a GUI that has no API — clicking, typing, or " <>
      "reading rendered visual state in a desktop app or browser. Screenshot first, then act. " <>
      "Prefer the dedicated browser/file/web tools when they cover the task; this is the last resort. " <>
      "In standard access, ask the owner and wait for their go-ahead before any irreversible action."
  end

  defp base_action_description do
    "The GUI action. Read-only: screenshot, inspect, mouse_move, wait. Mutating: left_click, " <>
      "right_click, double_click, left_click_drag, scroll, type, key."
  end

  defp action_description(:strict) do
    base_action_description() <>
      " ACCESS=strict (look only): screenshot/mouse_move/wait run; every mutating action is refused."
  end

  defp action_description(:standard) do
    base_action_description() <>
      " ACCESS=standard: act directly for routine navigation and typing, but FIRST ask the owner" <>
      " and wait for their reply before any irreversible action — delete, send, purchase, sign out," <>
      " overwrite, move to trash."
  end

  defp action_description(:open) do
    base_action_description() <>
      " ACCESS=open (autonomous): act directly, including ordinary destructive steps, WITHOUT" <>
      " asking — but STILL pause to confirm with the owner before a TRULY dangerous, catastrophic" <>
      " action: bulk/mass deletion, wiping or formatting data, sending money or irreversible" <>
      " external messages, or destructive system changes. A higher bar than standard, not zero."
  end

  @impl true
  def examples do
    [
      %{args: %{"action" => "screenshot"}, note: "look at the screen before acting"},
      %{
        args: %{"action" => "left_click", "x" => 640, "y" => 360},
        note: "click at a screenshot pixel"
      },
      %{
        args: %{"action" => "inspect", "x" => 640, "y" => 360},
        note: "check what UI element is under a point before clicking it"
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
        tag: "refused (strict access)",
        description: "a mutating action while access is strict (look-only); not performed"
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
  # used, and is reused across actions in the same conversation.
  defp dispatch(params, context) do
    config = Map.get(context, :computer_use_config) || Config.current()

    case resolve_session(context, config) do
      {:ok, session} -> run(session, params)
      {:error, reason} -> {:ok, Tool.error(unavailable_message(reason))}
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

  defp run(session, params) do
    case Session.classify(session, params) do
      {:ok, :auto, request} ->
        perform(session, request)

      {:error, {:refused, :strict_mode}} ->
        {:ok,
         Tool.error(
           "computer use is in strict (look-only) access — only screenshot, mouse_move, and wait " <>
             "run; this mutating action was refused. Ask the owner to switch access to standard to act."
         )}

      {:error, reason} ->
        {:ok, Tool.error("invalid action: #{format_reason(reason)}")}
    end
  end

  defp perform(session, request) do
    case Session.execute(session, request) do
      {:ok, %{image: nil, summary: summary}} ->
        {:ok, Tool.success(summary)}

      {:ok, %{image: image, summary: summary}} ->
        {:ok, Tool.success_with_images(summary, [image])}

      {:error, reason} ->
        {:ok, Tool.error(action_error_message(reason))}
    end
  end

  # A sidecar action error that maps to a known, non-transient host condition gets
  # an honest, general diagnosis (no app-specific examples — the model decides what
  # to do with the fact). Every other reason surfaces verbatim so a real backend
  # error is never masked (Rule #7).
  defp action_error_message("no_active_display") do
    "no capturable display — the screen is locked, the display is asleep, or this " <>
      "process has no active GUI session. Computer use cannot see or control the " <>
      "desktop until there is an unlocked, awake display; retrying will not help " <>
      "until that changes."
  end

  defp action_error_message(reason), do: "action failed: #{format_reason(reason)}"

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
