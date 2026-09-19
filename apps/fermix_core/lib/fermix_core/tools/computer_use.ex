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
      "Anything the human must SEE or act on themselves — a form they are filling, a document " <>
      "you review together, a game you play together — has to be on THEIR screen: the `browser` " <>
      "window (visible on a desktop " <>
      "OS) or an app opened with `shell` `open -a`. Never leave a shared activity somewhere " <>
      "only you can see. " <>
      "Even on their screen, never CLICK for an intent the OS can name: `shell` `open -a` " <>
      "launches apps, and AppleScript (`osascript`) drives named menus/settings/Finder " <>
      "directly — spend pixels only on state that exists solely as pixels. A live page whose " <>
      "state is SERVER-synced under the same account (a live game, a shared doc) can be driven " <>
      "through the managed `browser`'s exact element rails while the human watches their own " <>
      "window — prefer that over pixel-aiming at their screen. For precision clicks, bring the " <>
      "target window to the FRONT and unobstructed; do not maximize it for aiming's sake — a " <>
      "window that fits the capture budget arrives at native detail, a maximized one gets " <>
      "downscaled. " <>
      "AIMING: prefer exact targets where a surface exposes them (`browser` element " <>
      "actions, numbered `marks`, `elements` click points). Take a `screenshot` with " <>
      "`\"marks\": true` and act with `mark: <id>` — the exact point is resolved for you, " <>
      "which beats any pixel estimate. `elements`/`marks` are best-effort accessibility " <>
      "metadata: an empty result means no accessibility-backed points were exposed, not that " <>
      "visible content cannot accept pixel interaction. In the MANAGED browser, use `get " <>
      "field=rect` + `click_coords` for a visible DOM target; THIS tool's pixels are for " <>
      "every other surface. " <>
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
      "region rode the action, of the full screen otherwise: READ it before you repeat " <>
      "anything. It shows what the screen looks like now, not whether your input arrived, so " <>
      "repeat an action only when the image shows its effect is missing. A DELIVERED click " <>
      "that changes nothing is NOT a miss — do not repeat " <>
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
        },
        "confirm_grid" => %{
          "type" => "boolean",
          "description" =>
            "Set true ONLY to re-send an action that was refused as ambiguous coordinates, " <>
              "after re-reading the magnified image and confirming your x,y are pixels of THAT " <>
              "image — not of the full screen"
        },
        "marks" => %{
          "type" => "boolean",
          "description" =>
            "On `screenshot`: badge the accessibility click targets with numbered marks and " <>
              "list them, so you can act by mark number instead of estimating pixels"
        },
        "mark" => %{
          "type" => "integer",
          "description" =>
            "Act on a numbered mark from the LATEST marks screenshot (instead of x/y) — the " <>
              "exact click point is resolved for you. Marks expire when the view changes"
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
      "Even then, an intent shell or AppleScript can NAME — launching an app, a menu item, a " <>
      "settings toggle — is a `shell` one-liner, not a pixel hunt. " <>
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
      },
      %{
        tag: "input_busy",
        description:
          "another conversation is driving the cursor and keyboard; nothing was sent. " <>
            "Read-only actions still work — wait rather than re-sending"
      },
      %{
        tag: "busy",
        description:
          "the previous computer-use action in this conversation has not answered yet; " <>
            "nothing was sent. Wait for it instead of re-sending"
      },
      %{
        tag: "outcome unknown",
        description:
          "the helper stopped responding or exited during the action, so whether the input " <>
            "reached the screen is not knowable; the session was reset — read a fresh " <>
            "screenshot before repeating anything"
      },
      %{
        tag: "performed, not verified",
        description:
          "the action was sent but its check screenshot could not be captured; take a " <>
            "screenshot to see the result instead of re-sending the action"
      }
    ]
  end

  @impl true
  def category, do: :computer

  @impl true
  @spec execute(map(), Tool.context()) :: {:ok, Tool.tool_result()}
  def execute(params, context) when is_map(params) and is_map(context) do
    start = System.monotonic_time(:millisecond)
    {result, telemetry} = dispatch(params, context)
    duration = System.monotonic_time(:millisecond) - start
    success = match?({:ok, %{success: true}}, result)

    # `courtesy` records the coexistence outcome (V3 R0) so a trace shows when the
    # agent proceeded, deferred to, or yielded the seat to a present human — or
    # `:na` when courtesy didn't apply (unavailable session, strict refusal, etc.).
    # `outcome` is the five-value verdict on the INPUT (M42 slice 1 §4.1) and
    # `cu_session` the `cua_…` lifecycle session it ran in, so a row says what
    # happened and where. Both are an enum and an opaque id — nothing from the
    # screen ever enters always-on metadata.
    ToolTelemetry.exec("computer_use", context, success, duration,
      metadata: Map.put(telemetry, :action, Map.get(params, "action")),
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
  # Returns `{tool_result, telemetry_metadata}`; the caller emits the one exec event.
  defp dispatch(params, context) do
    config = Map.get(context, :computer_use_config) || Config.current()

    case resolve_session(context, config) do
      {:ok, session} -> with_cu_session(run(session, params), session)
      {:error, reason} -> {{:ok, Tool.error(unavailable_message(reason))}, refused(:na)}
    end
  end

  # The lifecycle id is READ from the session's registry entry, never asked of the
  # session itself: it may be blocked inside a driver call for the whole sidecar
  # budget, and recording what a tool call did must never wait on that. A session
  # started outside the registry has none, and the key is then simply absent.
  defp with_cu_session({result, telemetry}, session) do
    case SessionManager.session_id(session) do
      nil -> {result, telemetry}
      id -> {result, Map.put(telemetry, :cu_session, id)}
    end
  end

  defp refused(courtesy), do: %{courtesy: courtesy, outcome: :refused}

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

  # The handshake refused the installed helper: this build and that binary do not
  # speak the same wire, which is what a partly completed upgrade leaves behind.
  # Both shapes are the same operator fact and the same next move, and neither is
  # anything a model can retry its way out of.
  defp unavailable_message({mismatch, %{library: _ours, sidecar: _theirs}})
       when mismatch in [:protocol_mismatch, :session_generation_mismatch] do
    "the computer-use helper speaks a different version of the wire than this build of " <>
      "Fermix, so it was refused rather than run. Do not retry. Tell the user to reinstall " <>
      "the computer-use helper, or update Fermix, so the two match."
  end

  defp unavailable_message(reason) do
    "computer-use session unavailable: #{format_reason(reason)}"
  end

  defp run(session, params) do
    case Session.classify(session, params) do
      {:ok, :auto, request} ->
        perform(session, request)

      {:error, reason} ->
        {{:ok, Tool.error(refusal_message(reason))}, refused(refusal_courtesy(reason))}
    end
  end

  # The human reclaimed the machine with /pause — the one refusal with its own
  # courtesy dimension, so a trace shows the hold rather than a generic denial.
  defp refusal_courtesy({:refused, :paused}), do: :paused
  defp refusal_courtesy(_reason), do: :na

  defp refusal_message({:refused, :strict_mode}) do
    "computer use is in strict (look-only) access — only screenshot, mouse_move, and wait " <>
      "run; this mutating action was refused. Ask the owner to switch access to standard to act."
  end

  # macOS is not delivering synthetic input: the Accessibility grant is missing,
  # so every click/keystroke would be silently dropped while screenshots keep
  # working. One typed refusal beats a run of invisible no-ops.
  defp refusal_message({:refused, :input_control_denied}) do
    "macOS is silently dropping synthetic clicks and keystrokes: the Accessibility " <>
      "permission is not granted, so mutating actions are refused (screenshots still " <>
      "work). Ask the owner to grant it under System Settings → Privacy & Security → " <>
      "Accessibility (`fermix doctor` names the entry), then retry."
  end

  # There is one cursor, one keyboard and one focused window on the machine, and
  # another conversation is driving them. Nothing was sent, and there is no queue:
  # a click that lands minutes later, on a screen that has moved on, is worse than
  # a refusal — so the next move is to wait or to ask, never to re-send.
  defp refusal_message({:refused, :input_busy}) do
    "another conversation is driving this machine's cursor and keyboard right now, so this " <>
      "action was not sent. Read-only actions (screenshot, elements, inspect) still work. " <>
      "Wait for that work to finish, or tell the user you need the machine, before sending " <>
      "this again."
  end

  # WHICH conversation holds the cursor could not be established. A different fact
  # from `input_busy`, and it needs a different next move: telling the model to
  # wait for other work to finish would point it at work that may not exist.
  defp refusal_message({:refused, :input_unavailable}) do
    "this action was not sent: which conversation holds this machine's cursor and keyboard " <>
      "could not be established, and driving it without knowing risks two agents fighting " <>
      "for one pointer. Read-only actions (screenshot, elements, inspect) still work. Tell " <>
      "the user computer use needs a restart rather than retrying this."
  end

  # Stop; do NOT retry (a retry loop would burn iterations against a hold the
  # model can't clear).
  defp refusal_message({:refused, :paused}) do
    "computer use is paused — the user took the machine back with /pause. Do not retry; " <>
      "stop and tell them you'll continue when they run /resume."
  end

  # The coordinate-space guard: the latest usable image or element points used
  # a region, so bare x,y would be read in full-screen space and land elsewhere.
  # Name the exact region to re-send rather than guessing which source was used.
  defp refusal_message({:region_mismatch, region}) do
    "your latest coordinate source uses region #{format_region(region)}, so the x,y " <>
      "you just sent would be read in full-screen space and miss. Re-send this action " <>
      "with " <>
      ~s(`"region": #{format_region(region)}`) <>
      " and the coordinates from that source — or take a fresh full `screenshot` " <>
      "first and use full-screen coordinates."
  end

  # The wrong-grid tripwire (M28): the coordinates are plausible on BOTH live
  # grids — inside the on-screen region box while the view is a magnified crop —
  # so one of the two readings is a guaranteed miss. Refuse with the complete
  # conversion instead of executing a click that is wrong on either grid.
  defp refusal_message({:ambiguous_coordinates, info}), do: ambiguous_grid_message(info)

  # Mark-addressed actions (M28): a mark is only as live as the screenshot it
  # was badged on — a stale or unknown id is refused, never guessed, because
  # clicking a stale badge point is a wrong-element click.
  defp refusal_message(:no_marks) do
    "no live marks — take a fresh `screenshot` with `\"marks\": true` and use the " <>
      "mark numbers it returns."
  end

  defp refusal_message({:stale_marks, _region}) do
    "the marks were taken on a view you have since left, so their numbers no longer " <>
      "point where the badges showed. Take a fresh `screenshot` with `\"marks\": true` " <>
      "and use ITS mark numbers."
  end

  defp refusal_message({:unknown_mark, id, count}) do
    "mark #{id} does not exist — the latest marks screenshot has #{count} mark(s). " <>
      "Use one of its numbers, or take a fresh `screenshot` with `\"marks\": true`."
  end

  defp refusal_message(reason), do: "invalid action: #{format_reason(reason)}"

  defp format_region(%{"x" => x, "y" => y, "w" => w, "h" => h}),
    do: ~s({"x": #{x}, "y": #{y}, "w": #{w}, "h": #{h}})

  # The refusal text IS the recovery recipe, so the conversion in it must be exact:
  # crop_xy = (xy − region origin) × kz. A wrong recipe here would teach the model
  # the very grid error the tripwire exists to catch.
  defp ambiguous_grid_message(%{region: region, view: view, kz: kz, points: points} = info) do
    kz_text = :erlang.float_to_binary(kz, decimals: 2)

    "ambiguous coordinates: #{format_points(points)} fits both this " <>
      "#{view["w"]}x#{view["h"]} magnified crop and the on-screen region box " <>
      "#{format_region(region)}. Your latest view is the CROP. If you meant pixels of that " <>
      "magnified image, re-send the SAME action with " <>
      ~s(`"confirm_grid": true`) <>
      ". If you read the full screen instead, convert — subtract the region origin, then " <>
      "multiply by #{kz_text}: that lands at #{format_points(info.crop_equivalents)} in this crop."
  end

  defp format_points([{x, y}]), do: "(#{x},#{y})"
  defp format_points([{fx, fy}, {tx, ty}]), do: "(#{fx},#{fy})→(#{tx},#{ty})"

  defp perform(session, request) do
    case Session.execute(session, request) do
      {:ok, %{image: nil, summary: summary} = result} ->
        {{:ok, Tool.success(summary)}, action_telemetry(result)}

      {:ok, %{image: image, summary: summary} = result} ->
        {{:ok, Tool.success_with_images(summary, [image])}, action_telemetry(result)}

      {:error, :user_active} ->
        {{:ok, Tool.error(action_error_message(:user_active))}, refused(:yielded)}

      # The helper answered "no", and said on the same frame what it did with the
      # input. Its error code picks the sentence; its receipt — which the session
      # has already read — is the outcome. Nothing here infers either.
      {:error, {:action_failed, failure}} ->
        {{:ok, Tool.error(failure_message(failure))}, %{courtesy: :na, outcome: failure.outcome}}

      # A `/pause` cast can land between classify and execute, so the SAME refusal
      # can arrive here. It gets the same sentence and the same courtesy dimension
      # as at classify — never "action failed" with a raw term for an action that
      # was never attempted.
      {:error, {:refused, _reason} = refusal} ->
        {{:ok, Tool.error(refusal_message(refusal))}, refused(refusal_courtesy(refusal))}

      {:error, reason} ->
        {{:ok, Tool.error(action_error_message(reason))},
         %{courtesy: :na, outcome: error_outcome(reason, request)}}
    end
  end

  # The session decided the outcome of a reply it produced (it knows whether the
  # check came back); the tool only classifies the error tuples.
  defp action_telemetry(%{outcome: outcome} = result),
    do: %{courtesy: courtesy_of(result), outcome: outcome}

  # A refusal is a refusal whatever the action: nothing ran and nothing was looked
  # at, so a refused `screenshot` must never trace as a read that happened (it would
  # also disagree with the same refusal recorded at classify). Otherwise a read-only
  # action dispatches no input at all, so it stays `read` however it failed; and for
  # a mutating one, only a helper that stopped answering or died leaves dispatch
  # genuinely unknown — every other error is a live helper answering "no".
  defp error_outcome(reason, request) do
    cond do
      refusal?(reason) -> :refused
      Protocol.read_only?(request["action"]) -> :read
      unknown_dispatch?(reason) -> :unknown
      true -> :refused
    end
  end

  defp refusal?(:action_budget_exhausted), do: true
  defp refusal?(:sidecar_unavailable), do: true
  defp refusal?(:busy), do: true
  defp refusal?({:not_dispatched, _reason}), do: true
  defp refusal?(_reason), do: false

  # The action deadline is the helper going quiet mid-action; the SESSION deadline is
  # the outer `GenServer.call` giving up while the session is still working (an
  # execute makes up to four driver calls, and the cushion invariant covers one). In
  # both the input was already on its way, so dispatch is unknown — which is the one
  # verdict that must never be reported as "it did not happen".
  defp unknown_dispatch?({:timeout, :cu_sidecar_action, _ms}), do: true
  defp unknown_dispatch?({:timeout, :cu_session_call, _ms}), do: true
  defp unknown_dispatch?({:sidecar_exited, _status}), do: true
  defp unknown_dispatch?({:helper_fault, _reason}), do: true
  defp unknown_dispatch?({:protocol_error, _detail}), do: true
  defp unknown_dispatch?(reason), do: wire_fault?(reason)

  # The frame families the transport poisons itself over. After one, the wire is
  # unusable and the session takes a fresh helper — and the frame that would have
  # said what happened to the input is precisely the one that could not be read,
  # so the dispatch is unknown rather than refused.
  defp wire_fault?({:unknown_request_id, _id}), do: true
  defp wire_fault?({:stale_generation, _id}), do: true
  defp wire_fault?({:malformed_frame, _detail}), do: true
  defp wire_fault?({:unexpected_frame, _family}), do: true
  defp wire_fault?(:sidecar_response_too_large), do: true
  defp wire_fault?(:request_too_large), do: true
  defp wire_fault?(_reason), do: false

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

  # The helper never answered the action itself. A request and its reply pair by
  # ORDER over this protocol, so a late frame would be read as the NEXT action's
  # reply — the session is reset rather than carried on. Whether the input reached
  # the screen is not knowable from here, and claiming it did nothing would invite
  # a double submit on something that may already have happened.
  defp action_error_message({:timeout, :cu_sidecar_action, ms}) do
    "outcome unknown: the computer-use helper stopped responding #{ms} ms into this " <>
      "action, so whether it reached the screen cannot be told from here. The session was " <>
      "reset. Take a `screenshot` and read the current state before doing anything else; " <>
      "repeat this action only if the screen shows it did not take effect."
  end

  defp action_error_message({:sidecar_exited, status}) do
    "outcome unknown: the computer-use helper exited (status #{status}) during this action, " <>
      "so whether it reached the screen cannot be told from here. The session was reset and " <>
      "the next action starts a fresh helper. Take a `screenshot` and read the current state " <>
      "before doing anything else; repeat this action only if the screen shows it did not " <>
      "take effect."
  end

  # The OUTER call deadline, not the helper's. The session is still working — it was
  # NOT reset and it did not die — so telling the model to start over would be
  # false, and repeating the action blindly is a double submit on something already
  # dispatched. The next call is refused as busy rather than queued behind it,
  # which is the one thing the model needs to plan around.
  defp action_error_message({:timeout, :cu_session_call, ms}) do
    "outcome unknown: the computer-use session was still working #{ms} ms after this action " <>
      "was sent, so whether it finished cannot be told from here. The session was NOT reset " <>
      "— it is still busy, and computer-use calls are refused as busy until it finishes. " <>
      "Wait, then take a `screenshot` and read the current state before doing anything else; " <>
      "repeat this action only if the screen shows it did not take effect."
  end

  # One action at a time per conversation: the previous one is still inside the
  # helper. Nothing was sent, so this is a wait, never a re-send.
  defp action_error_message(:busy) do
    "this action was not sent: the previous computer-use action in this conversation is " <>
      "still running. Wait for it to answer before sending another one; do not re-send it."
  end

  # The helper stopped a sequence part way through (a `/pause` during a drag, a
  # cancelled wait). Some input was already posted and some was not, which is why
  # this is an unknown outcome and not a refusal.
  defp action_error_message("cancelled") do
    "outcome unknown: this action was stopped part way through, so some of its input reached " <>
      "the screen and some did not. Take a `screenshot` and read the current state before " <>
      "doing anything else; repeat this action only if the screen shows it did not take effect."
  end

  # The HELPER refused because its own barrier is installed. The same fact as
  # Fermix's pause refusal, from the other side of the wire, so it reads the same:
  # one hold, one sentence, whichever half of it the action met first.
  defp action_error_message("paused"), do: refusal_message({:refused, :paused})

  # The helper is already running something for someone else. Same shape as this
  # session's own busy refusal: nothing was sent, so wait rather than re-send.
  defp action_error_message("busy") do
    "this action was not sent: the computer-use helper is already running another action. " <>
      "Wait for it to finish before sending this again; do not re-send it now."
  end

  # The request belonged to a conversation, or to a sequence, the helper has moved
  # past — a session that was reset under it. Nothing was sent, and the next action
  # starts on a fresh helper, so it is safe to send again after a look.
  defp action_error_message(code) when code in ["stale_generation", "stale_mutation"] do
    "this action was not sent: it reached the computer-use helper out of step with the " <>
      "session it belongs to, which happens when the helper was restarted under this " <>
      "conversation. Take a `screenshot` to see the current screen, then send the action again."
  end

  # The build and the installed helper disagree about what a request may contain.
  # No retry can fix that, and it is an operator fact, not a model one.
  defp action_error_message("unknown_field") do
    "this action was not sent: the computer-use helper does not understand part of the " <>
      "request this build sends, which means the helper and Fermix are different versions. " <>
      "Do not retry. Tell the user the computer-use helper needs reinstalling to match."
  end

  # The process running this session's actions died under it. The action was
  # already on its way when that happened, so dispatch is unknowable — the same
  # verdict, and the same recovery, as a helper that stopped answering.
  defp action_error_message({:helper_fault, _reason}) do
    "outcome unknown: the computer-use helper stopped during this action, so whether it " <>
      "reached the screen cannot be told from here. The session was reset and the next " <>
      "action starts a fresh helper. Take a `screenshot` and read the current state before " <>
      "doing anything else; repeat this action only if the screen shows it did not take effect."
  end

  # The helper answered without saying what it did with the input, which the wire
  # requires of it. There is nothing here to infer from, and inferring is what the
  # receipt exists to replace, so it is reported as the fault it is.
  defp action_error_message({:protocol_error, :missing_receipt}) do
    "outcome unknown: the computer-use helper did not report whether it sent this input, so " <>
      "whether it reached the screen cannot be told from here. The session was reset and the " <>
      "next action starts a fresh helper. Take a `screenshot` and read the current state " <>
      "before doing anything else; repeat this action only if the screen shows it did not " <>
      "take effect."
  end

  # The helper failed while the coexistence arbiter was checking whether the human
  # was at the machine — BEFORE any input was dispatched. Nothing happened on the
  # screen, so this one is safe to send again.
  defp action_error_message({:not_dispatched, reason}) do
    "this action was not sent: the computer-use helper failed before any input was " <>
      "dispatched (#{helper_fault(reason)}). The session was reset — take a `screenshot` to " <>
      "see the screen, then send the action again."
  end

  # The Port was already closed, so the action was never written to the helper.
  defp action_error_message(:sidecar_unavailable) do
    "this action was not sent: the computer-use helper was not running. The session was " <>
      "reset — send the action again and a fresh helper starts."
  end

  # The wire itself broke. The frame that would have said what happened to the
  # input is the one that could not be read, so this is an unknown outcome and not
  # a failed action — and the raw frame error is a diagnostic, never a sentence.
  defp action_error_message(reason) do
    if wire_fault?(reason),
      do:
        "outcome unknown: the computer-use helper sent something this build cannot read, so " <>
          "whether this action reached the screen cannot be told from here. The session was " <>
          "reset and the next action starts a fresh helper. Take a `screenshot` and read the " <>
          "current state before doing anything else; repeat this action only if the screen " <>
          "shows it did not take effect.",
      else: "action failed: #{format_reason(reason)}"
  end

  # A refusal the helper named. Its code selects the sentence above; a `detail`
  # only ever reaches the model on a code with no sentence of its own, where the
  # alternative is a bare token the operator cannot act on.
  defp failure_message(%{code: code, detail: detail}) do
    message = action_error_message(code)

    if is_binary(detail) and message =~ "action failed:",
      do: message <> " (#{detail})",
      else: message
  end

  defp helper_fault({:timeout, :cu_sidecar_action, ms}),
    do: "it stopped responding after #{ms} ms"

  defp helper_fault({:sidecar_exited, status}), do: "it exited with status #{status}"
  defp helper_fault(:sidecar_unavailable), do: "it was not running"

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
