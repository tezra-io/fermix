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

  alias Compux.Protocol
  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.ComputerUse.Config
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
      "It is the ONLY tool that sees and acts on the user's OWN live screen — a page, app, or " <>
      "session they already have open; a `browser`/`shell` action runs in its own context and " <>
      "won't touch their screen. " <>
      "Anything the human must SEE or act on themselves — a game you play together, a board " <>
      "you both watch — has to be on THEIR screen: the `browser` window (visible on a desktop " <>
      "OS) or an app opened with `shell` `open -a`. Never leave a shared activity somewhere " <>
      "only you can see. " <>
      "AIMING: prefer exact targets where a surface exposes them (`browser` element " <>
      "actions, `elements` click points). `elements` is best-effort accessibility metadata: " <>
      "an empty result means no accessibility-backed points were exposed, not that visible " <>
      "content cannot accept pixel interaction. In the MANAGED browser, use `get field=rect` + " <>
      "`click_coords` for a visible DOM target; THIS tool's pixels are for every other surface. " <>
      "A screen-share frame is a LOW-DETAIL awareness image, never a source of click " <>
      "coordinates: take a fresh `screenshot` to aim. " <>
      "ZOOM TO THE WINDOW, not just to small controls. A full-screen capture is downscaled to " <>
      "fit one size budget, so on a large or ultrawide display most of that budget goes to " <>
      "desktop you do not care about and the app you DO care about arrives too small to aim " <>
      "in. A `region` crop is rescaled to that same budget on its own, so cropping to the " <>
      "window you are working in can multiply your effective resolution several times over. " <>
      "Call `windows` to get the exact bounds — it returns a ready-made `region` per window, " <>
      "so you never estimate them — then pass that region on every look AND every click " <>
      "inside it, reading coordinates in the magnified crop; zoom further for a small " <>
      "control within it. " <>
      "Fermix's own floating voice companion may be visible on that screen — never click it; " <>
      "its controls end the call you are on. If it covers your target, ask the human to move it. " <>
      "`screenshot` to see the screen, then act on it (click, type, key, scroll, drag) using " <>
      "pixel coordinates from the latest screenshot. Every " <>
      "mutating action returns a fresh check screenshot — of the SAME magnified crop when a " <>
      "region rode the action, of the full screen otherwise: CHECK it and retry if the " <>
      "click missed. A DELIVERED click that changes nothing is NOT a miss — do not repeat " <>
      "it; verify the effect through the surface's own structure where it has one (a " <>
      "`browser` snapshot or `get` for a page that browser drives), and change MECHANISM " <>
      "— element click, keyboard, the browser's own click — not aim. " <>
      "`inspect` (read-only) reports the UI element under a point — its role and label — so you " <>
      "can confirm you're about to click the right control (e.g., a button labeled \"Delete\") " <>
      "before a consequential action. `elements` (read-only) lists the clickable UI elements — " <>
      "each with a click point — so you target by element instead of guessing pixels; " <>
      "`wait_for_change` blocks until the screen updates (e.g. a page finishes loading) instead " <>
      "of repeated screenshots. Honor " <>
      "the configured access mode: standard confirms before anything " <>
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
          "description" =>
            "X pixel for click/move/scroll/inspect from the latest coordinate source"
        },
        "y" => %{
          "type" => "integer",
          "description" =>
            "Y pixel for click/move/scroll/inspect from the latest coordinate source"
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
        "text" => %{
          "type" => "string",
          "description" => "Text to type or paste (for action=type/paste)"
        },
        "chord" => %{
          "type" => "string",
          "description" => "Key chord for action=key, e.g. \"ctrl+s\""
        },
        "ms" => %{"type" => "integer", "description" => "Milliseconds to wait (for action=wait)"},
        "timeout_ms" => %{
          "type" => "integer",
          "description" =>
            "Max ms to wait for a change (for action=wait_for_change; default 10000)"
        },
        "poll_ms" => %{
          "type" => "integer",
          "description" => "Check interval in ms (for action=wait_for_change; default 250)"
        },
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
            "Optional zoom rectangle {x,y,w,h} in the latest full-screen screenshot's pixel " <>
              "space. On `screenshot` it returns a magnified crop; on `elements` it returns " <>
              "points in that crop's transformed space. Pass the SAME region with any " <>
              "inspect/click/move/drag/scroll that uses coordinates from the crop or those points."
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
      "It is the ONLY tool that sees and acts on the user's OWN live screen or the session they " <>
      "are watching. Still prefer a purpose-built tool when the target is addressable — a file " <>
      "path (file_read), a URL/query (web_fetch/web_search/browser), a system fact (shell) — even " <>
      "if it is also open on screen; reach for computer_use only for state that exists solely as " <>
      "pixels, or a task that must act on the very session the user is looking at (browser/shell " <>
      "use their own isolated context and desync). " <>
      "In standard access, ask the owner and wait for their go-ahead before any irreversible action."
  end

  defp base_action_description do
    "The GUI action. Read-only: screenshot, inspect, elements (best-effort accessibility " <>
      "click points — prefer usable points over guessing pixels, but an empty result does not " <>
      "block pixel targeting of visible content), " <>
      "windows (list the open windows, each with a ready-made `region` — use it to " <>
      "crop to the app you are working in instead of squinting at a downscaled " <>
      "whole screen), " <>
      "wait_for_change (block until the screen changes, then return the new frame), " <>
      "mouse_move, wait. Mutating: left_click, right_click, double_click, " <>
      "left_click_drag, scroll, type, paste (clipboard — prefer for long text), key."
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
      },
      %{
        tag: "user_active",
        description:
          "the human is using the machine; a disturbing action was held back to avoid " <>
            "fighting for the cursor (coexistence). Wait for them to pause or hand control back"
      },
      %{
        tag: "paused",
        description: "the human paused computer use with /pause; refused until they run /resume"
      }
    ]
  end

  @impl true
  def category, do: :computer

  @impl true
  @spec execute(map(), Tool.context()) :: {:ok, Tool.tool_result()}
  def execute(params, context) when is_map(params) and is_map(context) do
    start = System.monotonic_time(:millisecond)
    {result, courtesy} = dispatch(params, context)
    duration = System.monotonic_time(:millisecond) - start
    success = match?({:ok, %{success: true}}, result)

    # `courtesy` records the coexistence outcome (V3 R0) so a trace shows when the
    # agent proceeded, deferred to, or yielded the seat to a present human — or
    # `:na` when courtesy didn't apply (unavailable session, strict refusal, etc.).
    ToolTelemetry.exec("computer_use", context, success, duration,
      metadata: %{action: Map.get(params, "action"), courtesy: courtesy},
      input: params,
      result: result
    )

    result
  end

  # Resolve the per-conversation session lazily: a caller may pre-place
  # `:computer_use_session` on the context (tests, a future eager path), otherwise
  # the tool starts/reuses it through `SessionManager.ensure/3` keyed by the turn's
  # `conversation_key` — so the OS-driver process opens only when the tool is actually
  # used, and is reused across actions in the same conversation.
  # Returns `{tool_result, courtesy_outcome}`; the caller emits the courtesy dim.
  defp dispatch(params, context) do
    config = Map.get(context, :computer_use_config) || Config.current()

    case resolve_session(context, config) do
      {:ok, session} -> run(session, params)
      {:error, reason} -> {{:ok, Tool.error(unavailable_message(reason))}, :na}
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
        {{:ok,
          Tool.error(
            "computer use is in strict (look-only) access — only screenshot, mouse_move, and wait " <>
              "run; this mutating action was refused. Ask the owner to switch access to standard to act."
          )}, :na}

      # macOS is not delivering synthetic input: the Accessibility grant is missing,
      # so every click/keystroke would be silently dropped while screenshots keep
      # working. One typed refusal beats a run of invisible no-ops.
      {:error, {:refused, :input_control_denied}} ->
        {{:ok,
          Tool.error(
            "macOS is silently dropping synthetic clicks and keystrokes: the Accessibility " <>
              "permission is not granted, so mutating actions are refused (screenshots still " <>
              "work). Ask the owner to grant it under System Settings → Privacy & Security → " <>
              "Accessibility (`fermix doctor` names the entry), then retry."
          )}, :na}

      # The human reclaimed the machine with /pause. Stop; do NOT retry (a retry loop
      # would burn iterations against a hold the model can't clear).
      {:error, {:refused, :paused}} ->
        {{:ok,
          Tool.error(
            "computer use is paused — the user took the machine back with /pause. Do not retry; " <>
              "stop and tell them you'll continue when they run /resume."
          )}, :paused}

      # The coordinate-space guard: the latest usable image or element points used
      # a region, so bare x,y would be read in full-screen space and land elsewhere.
      # Name the exact region to re-send rather than guessing which source was used.
      {:error, {:region_mismatch, region}} ->
        {{:ok,
          Tool.error(
            "your latest coordinate source uses region #{format_region(region)}, so the x,y " <>
              "you just sent would be read in full-screen space and miss. Re-send this action " <>
              "with " <>
              ~s(`"region": #{format_region(region)}`) <>
              " and the coordinates from that source — or take a fresh full `screenshot` " <>
              "first and use full-screen coordinates."
          )}, :na}

      {:error, reason} ->
        {{:ok, Tool.error("invalid action: #{format_reason(reason)}")}, :na}
    end
  end

  defp format_region(%{"x" => x, "y" => y, "w" => w, "h" => h}),
    do: ~s({"x": #{x}, "y": #{y}, "w": #{w}, "h": #{h}})

  defp perform(session, request) do
    case Session.execute(session, request) do
      {:ok, %{image: nil, summary: summary} = result} ->
        {{:ok, Tool.success(summary)}, courtesy_of(result)}

      {:ok, %{image: image, summary: summary} = result} ->
        {{:ok, Tool.success_with_images(summary, [image])}, courtesy_of(result)}

      {:error, :user_active} ->
        {{:ok, Tool.error(action_error_message(:user_active))}, :yielded}

      {:error, reason} ->
        {{:ok, Tool.error(action_error_message(reason))}, :na}
    end
  end

  defp courtesy_of(%{courtesy: courtesy}) when is_atom(courtesy), do: courtesy
  defp courtesy_of(_result), do: :off

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

  # Coexistence (V3 R0): the human is actively using the machine, so a disturbing
  # action was held back rather than fighting them for the cursor.
  defp action_error_message(:user_active) do
    "the user is actively using the machine right now, so this action was held back to " <>
      "avoid taking the cursor from them. Wait for them to pause, or ask them to let you continue."
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
