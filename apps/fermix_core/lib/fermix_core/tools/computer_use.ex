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
  alias FermixCore.ComputerUse.Background
  alias FermixCore.ComputerUse.Config
  alias FermixCore.ComputerUse.Session
  alias FermixCore.ComputerUse.SessionManager
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

  @modifiers ~w(cmd ctrl alt shift)

  # Read at COMPILE time from the module that owns what the bound-window flag
  # reveals, so a guard can use it and there is no second copy to drift.
  @background_codes Background.codes()
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
      "AIMING — ONE RULE: coordinates are pixels in the image you name. Every reply that " <>
      "gives you coordinates names its image: `screenshot`, `elements` and `windows` each " <>
      "return an `observation_id`, and every click, move, drag, scroll and inspect must " <>
      "carry the id of the image its x,y were read in. There is no region to copy onto an " <>
      "action, and coordinates read in one image NEVER apply to another — read and aim in " <>
      "the same image, in the same breath. Only the last few images stay addressable and " <>
      "only for about half a minute; if an id is refused as unknown, expired or stale, take " <>
      "a fresh `screenshot` and read the coordinates again in IT, never re-send the old ones. " <>
      "Prefer exact targets where a surface exposes them (`browser` element " <>
      "actions, numbered `marks`, `elements` click points). Take a `screenshot` with " <>
      "`\"marks\": true` and act with `mark: <id>` plus that image's `observation_id` — the " <>
      "exact point is resolved for you, " <>
      "which beats any pixel estimate. `elements`/`marks` are best-effort accessibility " <>
      "metadata: an empty result means no accessibility-backed points were exposed, not that " <>
      "visible content cannot accept pixel interaction. In the MANAGED browser, use `get " <>
      "field=rect` + `click_coords` for a visible DOM target; THIS tool's pixels are for " <>
      "every other surface. " <>
      "A screen-share frame is a LOW-DETAIL awareness image with no observation_id, so it is " <>
      "never a source of click coordinates: take a fresh `screenshot` to aim. " <>
      "ZOOM TO THE WINDOW, not just to small controls. A full-screen capture is downscaled to " <>
      "fit one size budget, so on a large or ultrawide display most of that budget goes to " <>
      "desktop you do not care about and the app you DO care about arrives too small to aim " <>
      "in. A `region` crop is rescaled to that same budget on its own, so cropping to the " <>
      "window you are working in can multiply your effective resolution several times over. " <>
      "Call `windows` to get the exact bounds — it returns a ready-made `region` per window, " <>
      "so you never estimate them — then pass that region to `screenshot` and aim in the " <>
      "magnified image it returns, naming that image's id on every action inside it; zoom " <>
      "further for a small control within it. " <>
      "Fermix's own floating voice companion may be visible on that screen — never click it; " <>
      "its controls end the call you are on. If it covers your target, ask the human to move it. " <>
      "`screenshot` to see the screen, then act on it (click, type, key, scroll, drag) using " <>
      "pixel coordinates read in the image that screenshot names. Every " <>
      "mutating action comes back with its own check, and you never ask for one: a click, " <>
      "drag, scroll, keystroke or paste returns the VIEW it acted in — the same crop when the " <>
      "action was aimed in a zoomed image, the full screen otherwise — captured once that " <>
      "view stopped changing, and naming a NEW image: READ it, and aim your next action in " <>
      "it. A `press` or `set_value` returns the CONTROL instead, read again after the action: " <>
      "that is its state, never a picture and never proof the action had its effect. " <>
      "A check shows what the screen looks like now, not whether your input arrived, so " <>
      "repeat an action only when it shows the effect is missing. When the check says nothing " <>
      "visible changed, that is a fact about the VIEW and not a miss: do not repeat the " <>
      "action for it. " <>
      "Verify the effect through the surface's own structure where it has one (a " <>
      "`browser` snapshot or `get` for a page that browser drives), and change MECHANISM " <>
      "— element click, keyboard, the browser's own click — not aim. " <>
      background_description() <>
      "`inspect` (read-only) reports the UI element under a point — its role and label — so you " <>
      "can confirm you're about to click the right control (e.g., a button labeled \"Delete\") " <>
      "before a consequential action. `elements` (read-only) lists the UI controls — each " <>
      "with a reference, whether it is enabled, what it supports and a click point — so you " <>
      "target by control instead of guessing pixels, and press the ones that can be pressed; " <>
      "`wait_for_change` blocks until the screen updates (e.g. a page finishes loading) instead " <>
      "of repeated screenshots. Honor " <>
      "the configured access mode: standard confirms before anything " <>
      "irreversible; open acts autonomously but still confirms a truly dangerous/catastrophic " <>
      "action; strict is look-only."
  end

  # The bound-window surface, advertised only where the operator turned it on
  # (M42 slice 5 §1). It is the same switch everywhere: the actions in the enum,
  # the parameter beside them, this paragraph, the runtime steering. `Background`
  # owns the list; nothing here repeats it.
  defp background_description do
    if Config.background?() do
      "WORK INSIDE ONE WINDOW. `windows` lists what is open; `select_target` with that " <>
        "window's `window_id` BINDS it, and from then on every look and every action is " <>
        "answered from that window's own picture — even when something covers it — and its " <>
        "coordinates are that window's, not the screen's. Where the window exposes named " <>
        "controls, `press` and `set_value` act on them without moving the pointer, so the " <>
        "person can keep working in front of you. While a window is bound, a mutating action " <>
        "that names no window is refused: " <>
        ~s(`select_target` with `"window_id": "desktop"` is ) <>
        "how you say you mean the WHOLE screen, which is the visible, pointer-moving mode. " <>
        "`release_target` ends the binding. `wait_for_change` watches the whole screen, so it " <>
        "is refused while a window is bound: every action already waits for the window to " <>
        "settle before its check, and `wait` then a fresh `screenshot` covers the rest. " <>
        "This is experimental. "
    else
      ""
    end
  end

  # The action enum and the parameters the flag reveals. Read through `Background`
  # on both, so a schema and a refusal can never disagree about what is offered.
  defp background_properties do
    if Config.background?() do
      %{
        "window_id" => %{
          "type" => ["integer", "string"],
          "description" =>
            "On `select_target`: the window to bind, by the `window_id` a `windows` listing " <>
              "gave it — or the string \"desktop\" to work on the whole screen instead, which " <>
              "is the visible, pointer-moving mode"
        }
      }
    else
      %{}
    end
  end

  defp actions do
    if Config.background?(),
      do: Protocol.actions(),
      else: Enum.reject(Protocol.actions(), &(&1 in Background.actions()))
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "required" => ["action"],
      "additionalProperties" => false,
      "properties" =>
        Map.merge(background_properties(), %{
          "action" => %{
            "type" => "string",
            "enum" => actions(),
            "description" => base_action_description()
          },
          "observation_id" => %{
            "type" => "string",
            "description" =>
              "The image these coordinates were read in — the id a `screenshot`, `elements` " <>
                "or `windows` reply named. REQUIRED on click/move/drag/scroll/inspect; an id " <>
                "from one image never applies to another"
          },
          "x" => %{
            "type" => "integer",
            "description" => "X pixel in the image named by observation_id"
          },
          "y" => %{
            "type" => "integer",
            "description" => "Y pixel in the image named by observation_id"
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
          "from" =>
            point_schema("Drag start point, in pixels of the image named by observation_id"),
          "to" => point_schema("Drag end point, in pixels of the image named by observation_id"),
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
          "ms" => %{
            "type" => "integer",
            "description" => "Milliseconds to wait (for action=wait)"
          },
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
              "Optional zoom rectangle {x,y,w,h}, for `screenshot`, `elements` and " <>
                "`wait_for_change` only. With `observation_id` it is in that image's pixels; " <>
                "without one it is in a full-screen screenshot's pixels (the space `windows` " <>
                "answers in). The reply names a NEW image — aim in that one. A click, move, " <>
                "drag, scroll or inspect never carries a region: it names its image with " <>
                "`observation_id` instead."
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
              "Act on a numbered mark instead of x/y — the exact click point is resolved for " <>
                "you. A mark belongs to the image it was badged on, so send it with that " <>
                "image's `observation_id`. On `press`/`set_value` it names the badged CONTROL"
          },
          "element_ref" => %{
            "type" => "string",
            "description" =>
              "A control, by the reference an `elements` listing (or a mark) gave it — `e1`, " <>
                "`e2`, … A reference belongs to the listing that minted it, so send it with " <>
                "that reply's `observation_id`. REQUIRED by `press`/`set_value`; a click, " <>
                "right-click, double-click, move or scroll may take it INSTEAD of x,y and the " <>
                "control's bounds are re-read at that moment, so a control that has shifted is " <>
                "still hit. Never send both a reference and coordinates on one action"
          },
          "value" => %{
            "type" => "string",
            "description" => "The text to set (for action=set_value)"
          }
        })
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
      "left_click_drag, scroll, type, paste (clipboard — prefer for long text), key, " <>
      "press, set_value. " <>
      background_actions_description() <>
      "PREFER A NAMED CONTROL: `elements` says, per control, whether it " <>
      "can be pressed and whether its value can be set, and a control that lists `press` is " <>
      "pressed by name with `press` + its `element_ref` — that moves no pointer, takes no aim " <>
      "and cannot miss. `set_value` fills a field the same way where `elements` says it is " <>
      "settable; `type` and `paste` remain for a field that is not, and for text that must go " <>
      "through real keystrokes. A control that lists neither is clicked — by `element_ref` " <>
      "(its bounds are re-read as it is clicked) or by point. Nothing is switched for you: a " <>
      "refused `press` is a refusal, never a quiet click."
  end

  defp background_actions_description do
    if Config.background?(),
      do:
        "Binding: select_target (bind one window from `windows`, or \"desktop\" for the whole " <>
          "screen), release_target (give it back) — both read-only, neither touches anything. ",
      else: ""
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
      %{
        args: %{"action" => "screenshot"},
        note: "look at the screen — the reply names the image to aim in"
      },
      %{
        args: %{"action" => "left_click", "observation_id" => "7c1e-12", "x" => 640, "y" => 360},
        note: "click a pixel of the image that screenshot named"
      },
      %{
        args: %{"action" => "inspect", "observation_id" => "7c1e-12", "x" => 640, "y" => 360},
        note: "check what UI element is under a point before clicking it"
      },
      %{
        args: %{"action" => "elements"},
        note: "list the controls, each with a reference, what it supports, and a click point"
      },
      %{
        args: %{"action" => "press", "observation_id" => "7c1e-13", "element_ref" => "e4"},
        note: "press a control that listed `press` — no pointer, no aim, no miss"
      },
      %{
        args: %{
          "action" => "set_value",
          "observation_id" => "7c1e-13",
          "element_ref" => "e7",
          "value" => "chess.com"
        },
        note: "fill a field that listed `settable`, instead of clicking it and typing"
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
          "the action was sent but its check could not be obtained; take a " <>
            "screenshot to see the result instead of re-sending the action"
      },
      %{
        tag: "observation_required",
        description:
          "a click/move/drag/scroll/inspect that named no observation_id; nothing was " <>
            "sent. Take a screenshot and send the action with the id it names"
      },
      %{
        tag: "unknown/expired/stale observation",
        description:
          "the image the action named is no longer addressable — replaced, aged out, or " <>
            "its display changed; nothing was sent. Take a fresh screenshot and re-read " <>
            "the coordinates in it"
      },
      %{
        tag: "point_outside_observation",
        description:
          "the point is off the edge of the image it named, so it was probably read in a " <>
            "different one; nothing was sent and nothing was clamped onto an edge"
      },
      %{
        tag: "capture_geometry_mismatch",
        description:
          "the helper's measurements of the display disagree with the picture it " <>
            "captured, so nothing was sent; an operator fault, not a retryable one"
      },
      %{
        tag: "addressing_conflict",
        description:
          "the action named its target twice — an element_ref together with " <>
            "coordinates or a mark; nothing was sent. Send one or the other"
      },
      %{
        tag: "stale_element",
        description:
          "the control the element_ref names is gone with the listing that minted " <>
            "it; nothing was sent. Take `elements` again and use the new reference"
      },
      %{
        tag: "element_disabled",
        description:
          "the control is disabled, so nothing would reach it by any mechanism; " <>
            "nothing was sent and retrying cannot help"
      },
      %{
        tag: "ax_action_unsupported",
        description:
          "the control does not offer that accessibility action; nothing was sent " <>
            "and nothing was switched to a click for you — choose the mechanism yourself"
      },
      %{
        tag: "ax_timed_out / ax_action_failed",
        description:
          "an accessibility call failed. Whether the control was touched follows the " <>
            "helper's receipt: a message that went out and never answered is an " <>
            "unknown outcome and must NOT be repeated; one refused before it went " <>
            "anywhere was not sent, and usually means a missing Accessibility grant"
      },
      %{
        tag: "value_must_be_text",
        description:
          "set_value was given a non-string value; nothing was sent and nothing was " <>
            "converted — send the characters you want in the field, in quotes"
      }
    ] ++ background_failure_modes()
  end

  # Listed only where the surface is offered: a failure mode for an action the
  # schema does not carry is a capability advertised through the back door.
  defp background_failure_modes do
    if Config.background?() do
      [
        %{
          tag: "target_required",
          description:
            "a mutating action while no window is bound; nothing was sent. select_target " <>
              "the window, or \"desktop\" to mean the whole screen"
        },
        %{
          tag: "target_unavailable / target_minimized",
          description:
            "the bound window closed, its application quit, or it was minimized; " <>
              "nothing was sent and nothing was un-minimized. Take windows and bind again"
        },
        %{
          tag: "target_obstructed",
          description:
            "something covers the bound window at that point, so a click would land on " <>
              "it; nothing was sent and nothing was raised. Press the control by name instead"
        },
        %{
          tag: "ax_binding_unavailable",
          description:
            "the bound window exposes no accessibility window, so its controls cannot be " <>
              "listed or named; work by pixels in it instead"
        },
        %{
          tag: "control_surface_unavailable",
          description:
            "the on-screen indicator could not start, and work inside a window is never " <>
              "done without one; an operator fault, not a retryable one"
        },
        %{
          tag: "capture_unavailable / capture_budget_exceeded",
          description:
            "the bound window's own picture stalled, or the window is too large to hold " <>
              "pictures of within the helper's memory budget; nothing was sent"
        },
        %{
          tag: "screen_recording_not_granted",
          description:
            "the Screen Recording permission is not granted, so the window's picture " <>
              "cannot be taken at all; an operator fault, not a retryable one"
        }
      ]
    else
      []
    end
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

  # The person pressed Stop on the on-screen controls DURING this turn. Ending
  # the session is not ending the work — the model is still running — so every
  # later call in that turn meets this instead of a fresh, unbarred helper.
  defp unavailable_message(:operator_stopped) do
    "this action was not sent: " <> operator_stopped_lead()
  end

  defp unavailable_message(reason) do
    "computer-use session unavailable: #{format_reason(reason)}"
  end

  # One wording for one fact, on both routes to it: the call that was interrupted
  # and every call after it. It says to STOP, because a person who reaches for a
  # button on screen is not asking to be worked around.
  defp operator_stopped_lead do
    "the person pressed Stop on the on-screen computer-use controls, so they have the cursor " <>
      "and keyboard back and computer use is over for now. Do NOT take another computer-use " <>
      "action of any kind, a `screenshot` included. Tell them where you got to and what is " <>
      "left, and ask before going any further."
  end

  defp run(session, params) do
    case Session.classify(session, params) do
      {:ok, :auto, request} ->
        perform(session, request)

      {:error, reason} ->
        {{:ok, Tool.error(refusal_message(reason))}, refusal_telemetry(reason)}
    end
  end

  defp refusal_telemetry(reason) do
    reason
    |> refusal_courtesy()
    |> refused()
    |> geometry_refusal(refusal_code(reason))
  end

  # The two gates on this side that belong to the addressing family, so a trace
  # counts them beside the helper's own.
  defp refusal_code(:observation_required), do: "observation_required"
  defp refusal_code(:addressing_conflict), do: "addressing_conflict"
  defp refusal_code(_reason), do: nil

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

  # Addressing (M42 slice 3): coordinates mean nothing without the image they were
  # read in, and this side refuses before any input is dispatched rather than
  # guessing which of the last few images the model meant — a wrong guess is a
  # click on the wrong thing, the one outcome a GUI driver must never produce.
  defp refusal_message(:observation_required) do
    "this action was not sent: it names no `observation_id`, so there is no reply its target " <>
      "belongs to — a coordinate and an `element_ref` alike mean something only in the image " <>
      "or listing they were read from. Take a `screenshot` (or `elements`, or `windows`), " <>
      "then send this action again with the `observation_id` that reply names and the target " <>
      "you read in it."
  end

  # Two answers to "where" on one request. Guessing which the model meant is a
  # click on the wrong thing, so it is refused here, before anything is dispatched.
  defp refusal_message(:addressing_conflict) do
    "this action was not sent: it names its target twice — an `element_ref` together with " <>
      "coordinates or a `mark`. Send ONE: the reference, to act on that control wherever it " <>
      "now is, or the point, to act at those pixels of the image you named."
  end

  # The schema says `value` is a string; a model that sends a number gets a
  # sentence rather than a helper code. Nothing coerces it: `42` and `"42"` are
  # different acts in a field that formats what it is given.
  defp refusal_message(:value_must_be_text) do
    "this action was not sent: `value` must be TEXT — send the characters you want in the " <>
      "field, in quotes (`\"42\"`, not `42`). Nothing was converted for you, because a field " <>
      "that formats what it is given would store a different thing."
  end

  # The model named an action this build does not offer. Deliberately generic:
  # naming what the action WOULD have done would teach a capability this daemon
  # has switched off, through the one path that is reachable without it.
  defp refusal_message(:background_disabled), do: unavailable_action_message()

  # The operator DID switch it on and the installed helper cannot carry it. An
  # operator fact with an operator fix, so the sentence says who to tell rather
  # than what to try.
  defp refusal_message({:background_unavailable, reason}) do
    "this action was not sent: the computer-use helper on this machine cannot work inside a " <>
      "bound window — #{background_cause(reason)}. Do not retry. Tell the user `fermix doctor` " <>
      "explains it, and work on the whole screen meanwhile."
  end

  # Nothing is bound, and something was about to act. Running it on the whole
  # screen instead would be this side choosing a mode the model did not ask for,
  # on whatever window happens to be in front of the person.
  defp refusal_message(:target_required) do
    "this action was not sent: no window is bound, so there is nothing for it to act inside. " <>
      "Take `windows`, then `select_target` with the `window_id` of the window you mean — or, " <>
      "if you really mean the whole screen and the pointer moving in front of the user, " <>
      "`select_target` with `\"window_id\": \"desktop\"`. Nothing was chosen for you."
  end

  # `select_target` names a window by the id a `windows` listing gave it, which is
  # an integer, or says the word for the whole screen. Anything else is refused
  # with both spellings rather than guessed at: guessing which window was meant is
  # binding the wrong one.
  defp refusal_message(:window_id_required) do
    "this action was not sent: `select_target` needs a `window_id` — the integer id a " <>
      "`windows` listing gave the window you mean. Take `windows`, read the id of the window " <>
      "you want, and send that. To work on the whole screen instead, send the literal " <>
      ~s(`"desktop"`.)
  end

  # A display-level wait inside a bound window would watch the whole screen and
  # answer in a picture that is not the one the model is reading. The alternative
  # is named, because "not here" with no next move sends the model to guess.
  defp refusal_message(:wait_for_change_unbound) do
    "this action was not sent: `wait_for_change` watches the WHOLE SCREEN, so it cannot be " <>
      "used while you are bound to one window — what it returned would be a different picture " <>
      "from the one your coordinates belong to. Every action you send already waits for this " <>
      "window to stop changing before its check is taken; if you need to wait longer, send " <>
      "`wait`, then `screenshot` the window and compare. Or `release_target` first, if the " <>
      "thing you are waiting for is elsewhere on screen."
  end

  # A badge that carries no control reference. Clicking it instead would be this
  # side choosing a mechanism the model did not ask for, on a control that may
  # behave differently under the pointer.
  defp refusal_message({:mark_not_pressable, id}) do
    "mark #{id} carries no `element_ref`, so it cannot be pressed by name. Take `elements` " <>
      "and use the reference of the control you want, or click this mark with " <>
      "`\"mark\": #{id}` instead — your choice, not one made for you."
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
    "the image you named carries no marks — take a `screenshot` with `\"marks\": true` and " <>
      "send the mark numbers it returns with THAT image's `observation_id`."
  end

  defp refusal_message({:unknown_mark, id, count}) do
    "mark #{id} does not exist — the image you named has #{count} mark(s). " <>
      "Use one of its numbers, or take a fresh `screenshot` with `\"marks\": true`."
  end

  defp refusal_message(reason), do: "invalid action: #{format_reason(reason)}"

  defp unavailable_action_message do
    "this action was not sent: it names an action this build of computer use does not offer. " <>
      "The `action` list in this tool's schema is the whole of what is available here. Do not " <>
      "retry it; use one of those instead."
  end

  defp background_cause(:no_targets), do: "this build cannot bind a window at all"

  defp background_cause(:indicator_missing),
    do:
      "its on-screen indicator is not in the installed bundle, and work inside a window is " <>
        "never done without one on screen"

  defp background_cause(_unknown),
    do:
      "it did not say whether it has the on-screen indicator, and work inside a window is " <>
        "never done without one on screen"

  defp format_region(%{"x" => x, "y" => y, "w" => w, "h" => h}),
    do: ~s({"x": #{x}, "y": #{y}, "w": #{w}, "h": #{h}})

  # The refusal text IS the recovery recipe, so the conversion in it must be exact:
  # crop_xy = (xy − region origin) × kz. A wrong recipe here would teach the model
  # the very grid error the tripwire exists to catch.
  defp ambiguous_grid_message(
         %{id: id, region: region, view: view, kz: kz, points: points} = info
       ) do
    kz_text = :erlang.float_to_binary(kz, decimals: 2)

    "ambiguous coordinates: #{format_points(points)} fits both image #{id}, which is a " <>
      "#{view["w"]}x#{view["h"]} magnified crop, and the on-screen region box " <>
      "#{format_region(region)} that crop was taken from. If you meant pixels of image " <>
      "#{id}, re-send the SAME action with " <>
      ~s(`"confirm_grid": true`) <>
      ". If you read the full screen instead, convert — subtract the region origin, then " <>
      "multiply by #{kz_text}: that lands at #{format_points(info.crop_equivalents)} in " <>
      "image #{id}."
  end

  defp format_points([{x, y}]), do: "(#{x},#{y})"
  defp format_points([{fx, fy}, {tx, ty}]), do: "(#{fx},#{fy})→(#{tx},#{ty})"

  defp perform(session, request) do
    case Session.execute(session, request) do
      {:ok, %{image: nil} = result} ->
        {{:ok, Tool.success(action_summary(result))}, action_telemetry(result)}

      {:ok, %{image: image} = result} ->
        {{:ok, Tool.success_with_images(action_summary(result), [image])},
         action_telemetry(result)}

      {:error, :user_active} ->
        {{:ok, Tool.error(action_error_message(:user_active))}, refused(:yielded)}

      # The helper answered "no", and said on the same frame what it did with the
      # input. Its error code picks the sentence; its receipt — which the session
      # has already read — is the outcome. Nothing here infers either.
      {:error, {:action_failed, failure}} ->
        telemetry =
          %{courtesy: :na, outcome: failure.outcome}
          |> geometry_refusal(failure.code)
          |> put_receipt_facts(failure)

        {{:ok, Tool.error(failure_message(failure))}, telemetry}

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

  # The two codes whose sentence ends by promising the helper's own numbers: the
  # image's size for a point off its edge, and both measurements for a geometry
  # mismatch. Quoting the helper beats re-deriving them here — one authority for a
  # fact, and the operator reads the words the helper actually used.
  # The platform's own words belong beside these, because an AXError number is
  # what a bug report needs — appended, never rendered AS the message.
  # `target_obstructed` is here too: its sentence ends by promising the helper's
  # own words for what is in front, which is the one fact that decides whether the
  # model aims elsewhere or asks the person to move something.
  @detailed_codes ~w(point_outside_observation capture_geometry_mismatch
                     ax_timed_out ax_action_failed target_obstructed)

  # A check the helper refused after the input had already gone out is a SUCCESS
  # here — the action happened — so the code it refused with would otherwise reach
  # neither the model's sentence nor the row. Both matter: `capture_geometry_mismatch`
  # is an operator fault whose own sentence says "do not retry, tell the user", and
  # the generic unverified lead ends in "take a fresh `screenshot`" — the exact
  # retry that code forbids. One authority per code, so the sentence comes from the
  # same `action_error_message/1` a refusal would have used, with the helper's
  # numbers after it exactly as `failure_message/1` places them.
  defp action_summary(%{summary: summary, check_code: code} = result)
       when code in @detailed_codes do
    summary <> " " <> action_error_message(code) <> check_detail(result)
  end

  defp action_summary(%{summary: summary}), do: summary

  defp check_detail(%{check_detail: detail}) when is_binary(detail), do: " (#{detail})"
  defp check_detail(_result), do: ""

  # The session decided the outcome of a reply it produced (it knows whether the
  # check came back); the tool only classifies the error tuples. A check the helper
  # refused carries its code here too, so an operator fault stays countable on the
  # row whichever side of dispatch it landed on.
  defp action_telemetry(%{outcome: outcome} = result) do
    %{courtesy: courtesy_of(result), outcome: outcome}
    |> put_age(Map.get(result, :observation_age_ms))
    |> geometry_refusal(Map.get(result, :check_code))
    |> put_receipt_facts(result)
  end

  # What the session read off the receipt: by which mechanism the input went out
  # (`ax` or `foreground_hid`), what the helper observed of it, which evidence the
  # action came back with, and what each phase of it cost (M42 slice 6). Closed
  # enums, a boolean and four millisecond counts — the value a `set_value` carried
  # is NOT among them and never reaches a row, because it is content, and content
  # rides the capture gate rather than always-on metadata.
  # `target_kind` and `mode` (M42 slice 5 §4) join them: what this action was
  # pointed at (a window or the desktop) and how it reached the screen (through
  # accessibility inside a bound window, or in front of the person). Two more
  # closed words — never the window's title and never the application's name,
  # which are content and belong to the model's side of the wire.
  @receipt_facts [
    :input_method,
    :effect,
    :check_kind,
    :check_changed,
    :cu_input_ms,
    :cu_settle_ms,
    :cu_capture_ms,
    :cu_encode_ms,
    :target_kind,
    :cu_mode
  ]

  defp put_receipt_facts(telemetry, source) do
    Enum.reduce(@receipt_facts, telemetry, fn key, acc ->
      put_enum(acc, key, Map.get(source, key))
    end)
  end

  defp put_enum(telemetry, _key, nil), do: telemetry
  defp put_enum(telemetry, key, value), do: Map.put(telemetry, key, value)

  # How stale the image an action aimed at was, in milliseconds. A bounded number
  # and nothing else: no id (it does not outlive the session), no size, no pixels.
  # It is the measurement that says whether expiry refusals are the model reading
  # slowly or the window being too short.
  defp put_age(telemetry, nil), do: telemetry

  defp put_age(telemetry, age) when is_integer(age),
    do: Map.put(telemetry, :observation_age_ms, age)

  # The addressing and geometry refusals as their own countable field: a closed set
  # of wire codes, so a trace can be counted by them without parsing a sentence.
  # `capture_geometry_mismatch` is the one that is never the model's doing, which
  # is exactly why it has to be countable.
  @geometry_refusals ~w(observation_required addressing_conflict unknown_observation
                        expired_observation stale_observation point_outside_observation
                        capture_geometry_mismatch)

  defp geometry_refusal(telemetry, code) when code in @geometry_refusals,
    do: Map.put(telemetry, :geometry_refusal, code)

  defp geometry_refusal(telemetry, _code), do: telemetry

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

  defp refusal?(:operator_stopped), do: true
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
  defp unknown_dispatch?({:operator_stopped, _dispatch}), do: true
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

  # The coexistence verdict, as a CLOSED set: the four the session's arbiter
  # answers plus the three this side mints for a refusal. Anything else is not a
  # verdict and is dropped to `:off` rather than carried, for the same reason
  # `effect/1` and `input_method/1` drop what they do not recognise — a trace
  # field is only countable while its values are the ones the contract names.
  @courtesy_outcomes [:off, :na, :unavailable, :proceeded, :deferred, :yielded, :paused]

  defp courtesy_of(%{courtesy: courtesy}) when courtesy in @courtesy_outcomes, do: courtesy
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

  # The image the action named is not one the helper can still map a point through:
  # it has been replaced, it timed out, or the display's geometry moved under it.
  # One sentence for all three, because the recovery is one move and the difference
  # between them tells the model nothing it can act on differently.
  defp action_error_message(code)
       when code in ["unknown_observation", "expired_observation", "stale_observation"] do
    "this action was not sent: the image its `observation_id` names is no longer one the " <>
      "computer-use helper holds — it has been replaced by newer ones, it aged out, or the " <>
      "display it was taken from moved or changed size. Take a fresh `screenshot`, read the " <>
      "coordinates again in the image IT names, and send the action with that id. Do not " <>
      "re-send the old coordinates."
  end

  # The point is off the edge of the image it named. Nothing is clamped onto an
  # edge: a point that does not exist on the image it claims to come from was
  # almost certainly read on a different one, and clicking the nearest edge pixel
  # is a wrong click that looks like a right one.
  defp action_error_message("point_outside_observation") do
    "this action was not sent: the point lies outside the image its `observation_id` names, " <>
      "so there is nowhere on that image to put it — it was most likely read in a different " <>
      "image. Take a `screenshot`, read the point again in the image it names, and send the " <>
      "action with that id."
  end

  # Not a model error at all: the helper's picture of the display disagrees with
  # the display it captured, so every coordinate it mapped would land somewhere
  # else. There is nothing to retry and nothing to re-aim — it is an operator fact
  # and it carries both sizes so the operator can act on it.
  #
  # It says NOTHING about dispatch, because it arrives on both sides of it: on the
  # action, where nothing was sent, and on the CHECK capture that follows a click
  # the helper already dispatched (receipt `sent`, outcome `performed_unverified`).
  # The receipt is what knows which, and the outcome wording is what carries it; a
  # sentence opening "this action was not sent" told the model a dispatched click
  # had not happened, which is the one claim that buys a second real click.
  defp action_error_message("capture_geometry_mismatch") do
    "the computer-use helper's measurements of this display do not match the picture it " <>
      "captured, so any point it mapped would land somewhere else on screen. This is not " <>
      "something you did wrong and not something a different image fixes. Do not retry. " <>
      "Tell the user the computer-use helper is reading this display's geometry wrongly, " <>
      "and give them both sizes below."
  end

  # The control a reference names is gone: the listing that minted it has been
  # replaced or aged out, the window was rebuilt under it, or its application
  # restarted. A reference is only as live as the listing it came from, and there
  # is no re-finding it from here — the same control in a fresh listing has a fresh
  # reference.
  defp action_error_message("stale_element") do
    "this action was not sent: the control its `element_ref` names is no longer one the " <>
      "computer-use helper holds — the listing that minted it has been replaced or aged out, " <>
      "or the window was rebuilt under it. Take `elements` again and use the reference from " <>
      "THAT reply; do not re-send this one."
  end

  # The control is there and it is off. Retrying presses the same dead button, so
  # the next move is to find what turns it on — not a second attempt, and not a
  # click at its pixels either, which a disabled control ignores just as firmly.
  defp action_error_message("element_disabled") do
    "this action was not sent: that control is DISABLED right now, so it would do nothing " <>
      "however it were reached — clicking its pixels included. Do not retry it. Work out what " <>
      "enables it (a field left empty, a selection not made, a mode not switched), do that " <>
      "first, then take `elements` again."
  end

  # The control exists and is enabled but does not offer the accessibility action.
  # What to do instead is the model's call: the helper never switches mechanism on
  # its own, because a click is a different act with different consequences.
  defp action_error_message("ax_action_unsupported") do
    "this action was not sent: that control cannot be operated by name — its own list of " <>
      "accessibility actions does not include the one you asked for. Reach it another way if " <>
      "you still want to: click it by `element_ref`, or by its point from `elements` or a " <>
      "marked `screenshot`. Nothing was switched for you."
  end

  # The same fact as Fermix's own conflict refusal, from the other side of the
  # wire, so it reads the same whichever half the request met first.
  defp action_error_message("addressing_conflict"), do: refusal_message(:addressing_conflict)

  # The helper wants a control and got none. Fermix never sends this shape (the
  # library refuses it first), so it means the two halves disagree about what the
  # action takes.
  defp action_error_message("element_required") do
    "this action was not sent: it names no control. `press` and `set_value` act on the " <>
      "`element_ref` of a control an `elements` listing named — take `elements`, then send " <>
      "the reference of the control you want with that reply's `observation_id`."
  end

  # The bound-window family, routed through the flag: with it off nothing can
  # produce one of these codes (this build never sends a `target_id`), and a
  # sentence explaining window binding would be the surface reaching the model
  # through the error path. The raw code is the right diagnostic for a state that
  # cannot happen.
  defp action_error_message(code) when code in @background_codes do
    if Config.background?(),
      do: background_code_message(code),
      else: "action failed: #{code}"
  end

  # The build and the installed helper disagree about what a request may contain.
  # No retry can fix that, and it is an operator fact, not a model one.
  defp action_error_message("unknown_field") do
    "this action was not sent: the computer-use helper does not understand part of the " <>
      "request this build sends, which means the helper and Fermix are different versions. " <>
      "Do not retry. Tell the user the computer-use helper needs reinstalling to match."
  end

  # The action was already inside the helper when the person pressed Stop. The
  # helper bars its gate at once, but some of this action's input may already
  # have gone out, so the outcome is genuinely unknown — and unlike every other
  # unknown outcome, the recovery is NOT to look: looking is a computer-use
  # action too, and the person has the machine.
  defp action_error_message({:operator_stopped, _dispatch}) do
    "outcome unknown: computer use was STOPPED from the on-screen controls while this action " <>
      "was inside the helper, so whether its input reached the screen cannot be told from " <>
      "here — and it must not be checked, because " <> operator_stopped_lead()
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

  # The window is gone: closed, or its application quit. A reused window number
  # or a relaunched application never revives a binding, so there is nothing to
  # re-point at — the window has to be found again from scratch.
  defp background_code_message("target_unavailable") do
    "this action was not sent: the window you bound is gone — it was closed, or its " <>
      "application quit. Nothing was done to whatever is there now. Take `windows` to see " <>
      "what is open and `select_target` the window you want; do not re-send this one against " <>
      "the old binding."
  end

  # Minimized is recoverable by the PERSON, not by the agent: nothing here
  # un-minimizes a window, because that is a visible change to their desktop
  # nobody asked for.
  defp background_code_message("target_minimized") do
    "this action was not sent: the window you bound is minimized, so there is nothing of it " <>
      "to see or act on. Nothing was un-minimized for you. Ask the user to bring it back, or " <>
      "`select_target` a different window; `windows` shows what is open."
  end

  # A pixel action needs the target to be the topmost window at that point.
  # Deliberately does NOT offer to raise it: raising a window is exactly the
  # visible interruption a bound window exists to avoid.
  defp background_code_message("target_obstructed") do
    "this action was not sent: something is in front of the window you bound at that point, " <>
      "so a click there would land on whatever is covering it. Nothing was raised or brought " <>
      "forward. The detail below names what is in front; if it is Fermix's own on-screen " <>
      "indicator, that is the panel with pause and stop on it and clicking through it would " <>
      "press one of those. Reach the control by name instead — take `elements` and `press` or " <>
      "`set_value` it, which does not go through the pointer at all — or aim somewhere the " <>
      "window is not covered, or ask the user to move what is on top."
  end

  # The window was bound but its accessibility window was not, so there is no
  # root to walk and no control to name. The pointer still works, which is the
  # honest alternative rather than a silent one.
  defp background_code_message("ax_binding_unavailable") do
    "this action was not sent: the window you bound exposes no accessibility window, so its " <>
      "controls cannot be listed or named. Work by pixels here instead: take a `screenshot` " <>
      "and click in the image it names, knowing the pointer moves where the user can see it."
  end

  # The on-screen indicator never started, or died. An operator fact: work inside
  # a window is not done invisibly, so the answer is to tell the user, never to
  # retry into the same wall.
  defp background_code_message("control_surface_unavailable") do
    "this action was not sent: the computer-use helper could not put its on-screen indicator " <>
      "up, and it will not work inside a window with nothing on screen to show the user that " <>
      "it is doing so or to stop it. Do not retry. Tell the user the on-screen computer-use " <>
      "indicator could not start; the whole screen still works as usual."
  end

  # The window's own capture stream is not delivering. Distinct from the display
  # being asleep: the display may be perfectly awake.
  defp background_code_message("capture_unavailable") do
    "this action was not sent: the picture of the window you bound could not be obtained — " <>
      "its stream stalled, or the window stopped being drawable. Take `windows` to see whether " <>
      "it is still open, and `select_target` it again to start a fresh picture of it."
  end

  # A window whose frames do not fit the worker's memory budget. Not retryable as
  # it stands, and the fix is the window's size, which the user owns.
  # The person declined Screen Recording, or never granted it, so the window's
  # own capture stream cannot start. An operator fact with an operator fix, and
  # the fix is worded exactly as `fermix doctor` words it — one spelling for one
  # grant, so the two surfaces never send the user to different places.
  defp background_code_message("screen_recording_not_granted") do
    "this action was not sent: the computer-use helper cannot capture this window because " <>
      "screen capture is NOT granted. Do not retry. Tell the user to grant Screen Recording: " <>
      "System Settings → Privacy & Security → Screen Recording, and to restart computer use " <>
      "afterwards."
  end

  defp background_code_message("capture_budget_exceeded") do
    "this action was not sent: the window you bound is too large to hold pictures of within " <>
      "the memory this helper allows itself, so nothing was captured. Retrying will not help. " <>
      "Ask the user to make the window smaller, or `select_target` a smaller one."
  end

  # The two codes whose sentence cannot be read off the code alone.
  @ax_failures ~w(ax_timed_out ax_action_failed)

  # A refusal the helper named. Its code selects the sentence above; a `detail`
  # reaches the model on a code whose sentence asked for it, and on a code with no
  # sentence of its own, where the alternative is a bare token the operator cannot
  # act on.
  defp failure_message(%{code: code, detail: detail} = failure) do
    message = named_failure_message(failure)

    if is_binary(detail) and (code in @detailed_codes or message =~ "action failed:"),
      do: message <> " (#{detail})",
      else: message
  end

  defp named_failure_message(%{code: code, dispatch: dispatch}) when code in @ax_failures,
    do: ax_dispatch_message(ax_cause(code, dispatch), dispatch)

  defp named_failure_message(%{code: code}), do: action_error_message(code)

  # The two accessibility failures, whose sentence follows the RECEIPT and not the
  # code: the same failure name covers a message the platform refused before it
  # went anywhere and one that failed after it had already gone out, and those
  # are opposite facts about whether the control was touched. The code picks the
  # CAUSE clause; `ax_dispatch_message/2` picks which claim may be made about it.
  defp ax_cause("ax_timed_out", :sent), do: "was made and never came back"
  defp ax_cause("ax_timed_out", _not_sent), do: "timed out before its message went anywhere"
  defp ax_cause("ax_action_failed", :sent), do: "failed after its message had already gone out"

  defp ax_cause("ax_action_failed", _not_sent),
    do: "was refused by the accessibility system before it went anywhere"

  # The call was made and its result was never read. Repeating it is a second
  # press on a control that may already have acted, which is the one thing the
  # receipt family exists to prevent.
  defp ax_dispatch_message(cause, :sent) do
    "outcome unknown: the accessibility call #{cause}, so whether this control acted cannot " <>
      "be told from here. Do NOT repeat it; look first — take a `screenshot`, or `elements` " <>
      "again — and act only if it shows nothing happened."
  end

  # Nothing left this process, so the control was definitively not touched, and the
  # causes are all things the user or a fresh listing resolves rather than a retry.
  defp ax_dispatch_message(cause, _not_sent) do
    "this action was not sent: the accessibility call #{cause}, so this control was not " <>
      "touched. The usual causes are the Accessibility permission not being granted, the " <>
      "control going away between the listing and now, or a platform that does not offer this " <>
      "at all. Take `elements` again to see whether the control is still there; if it is, tell " <>
      "the user computer use may be missing its Accessibility permission."
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
