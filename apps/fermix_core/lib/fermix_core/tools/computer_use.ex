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
  alias FermixCore.ComputerUse.Controls
  alias FermixCore.ComputerUse.HelperActions
  alias FermixCore.ComputerUse.Session
  alias FermixCore.ComputerUse.SessionManager
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

  @modifiers ~w(cmd ctrl alt shift)

  # Read at COMPILE time from the module that owns what the bound-window flag
  # reveals, so a guard can use it and there is no second copy to drift.
  @background_codes Background.codes()
  @scroll_directions ~w(up down left right)
  # The most notches one `scroll` turns. The helper refuses anything outside
  # 1..50 (its library first), and never turns a larger amount down to the cap.
  @max_scroll_notches 50

  # The verbs a control lists (M86 P2), `type` aside: it is a verb only when it
  # names a control.
  @verbs Controls.verbs() -- ["type"]

  @impl true
  def name, do: "computer_use"

  # Built from the helper's latest reading (`HelperActions`), like the schema: a
  # sentence about an accessibility action the enum lacks is that action
  # advertised anyway (M86 F1). The copy registered here is read once, at boot,
  # before any helper has answered, so it is the pixel wording;
  # `dynamic_description/1` is what a turn reads.
  @impl true
  def description, do: description(HelperActions.offered())

  @doc """
  The description for this turn (`Capabilities.Advertisement`): the same words
  for the helper's latest reading. A function of that reading and the
  bound-window flag alone, so it changes only when they do and the provider's
  cached prompt prefix holds from one turn to the next.
  """
  @spec dynamic_description(map()) :: String.t()
  def dynamic_description(context) when is_map(context), do: description()

  defp description(offered) do
    screen_description(offered) <>
      controls_first_description(offered) <>
      aiming_description(offered) <>
      zoom_description(offered) <>
      check_description(offered) <>
      background_description(offered) <>
      controls_description(offered)
  end

  # Work by control where the screen exposes controls, and by pixels where it does
  # not (M86 P2). Only where the helper lists controls at all: on a pixel
  # helper this paragraph would teach verbs it does not have.
  # A session whose pixel route was refused (Linux) lists the controls and nothing
  # else, so there the paragraph says they are the only way in.
  defp controls_first_description(offered) do
    naming(
      offered,
      ["elements"],
      naming(
        offered,
        ["screenshot"],
        "CONTROLS FIRST. Where the screen exposes controls, work by control, not by pixels: ",
        "CONTROLS ONLY. This desktop is reached by its controls alone: "
      ) <>
        "`elements` lists them one per line — reference, role, label, state and the verbs " <>
        "each takes (after a plain first listing, narrow a dense window with `scope`, a " <>
        "`query`, or `skeleton` then `root`). Send a verb its line lists (" <>
        verb_names(offered) <>
        ") with that control's `element_ref` and the " <>
        "list's `observation_id`" <>
        naming(
          offered,
          ["screenshot"],
          ": no pointer, no aim, no miss, and the reply reads the " <>
            "control back instead of a picture. Pixels are for canvases, games, remote desktops " <>
            "and anything `elements` does not list. ",
          ", and the reply reads the control back; `type` with an `element_ref` puts text " <>
            "into that control. What `elements` does not list cannot be reached here: tell " <>
            "the user. "
        )
    ) <>
      naming(
        offered,
        ["wait_for"],
        "To wait, name what you are waiting for: `until` on an action waits for its effect " <>
          "in the same call, and `wait_for` waits without acting; both end the moment it " <>
          "holds, so never poll" <> naming(offered, ["screenshot"], " with screenshots") <> ". "
      )
  end

  # Whose screen this is, and what to reach for before pixels, or before acting at
  # all where only the controls are served.
  defp screen_description(offered) do
    if "screenshot" in offered,
      do: pixel_screen_description(),
      else: controls_screen_description()
  end

  defp pixel_screen_description do
    "Drive the host desktop GUI by screenshot + mouse/keyboard, one action per call. " <>
      own_screen_description("`shell` `open -a`") <>
      "Even on their screen, never CLICK for an intent the OS can name: `shell` `open -a` " <>
      "launches apps, and AppleScript (`osascript`) drives named menus/settings/Finder " <>
      "directly — spend pixels only on state that exists solely as pixels. " <>
      live_page_description("pixel-aiming at") <>
      "For precision clicks, bring the " <>
      "target window to the FRONT and unobstructed; do not maximize it for aiming's sake — a " <>
      "window that fits the capture budget arrives at native detail, a maximized one gets " <>
      "downscaled. "
  end

  # Only a Linux session is served by its controls alone, so nothing here names
  # the macOS launcher or its scripting.
  defp controls_screen_description do
    "Drive the host desktop GUI by its controls, one action per call. " <>
      own_screen_description("`shell`") <>
      "Even on their screen, never act for an intent the OS can name: `shell` launches apps " <>
      "and changes settings directly. " <>
      live_page_description("acting on")
  end

  defp own_screen_description(launcher) do
    "It is the ONLY tool that sees and acts on the user's OWN live screen — a page, app, or " <>
      "session they already have open; a `browser`/`shell` action runs in its own context and " <>
      "won't touch their screen. " <>
      "Anything the human must SEE or act on themselves — a form they are filling, a document " <>
      "you review together, a game you play together — has to be on THEIR screen: the `browser` " <>
      "window (visible on a desktop OS) or an app opened with #{launcher}. Never leave a shared " <>
      "activity somewhere only you can see. "
  end

  defp live_page_description(instead) do
    "A live page whose state is SERVER-synced under the same account (a live game, a shared " <>
      "doc) can be driven through the managed `browser`'s exact element rails while the human " <>
      "watches their own window — prefer that over #{instead} their screen. "
  end

  # One rule for coordinates, and the exact targets that beat them. Where only the
  # controls are served there are no coordinates, and the rule is the listing's.
  defp aiming_description(offered) do
    if "screenshot" in offered,
      do: coordinates_description(offered),
      else: references_description()
  end

  defp references_description do
    "A reference belongs to the listing that minted it: send it with that listing's " <>
      "`observation_id`. Only the last few listings stay addressable and only for about half " <>
      "a minute; if an id is refused as unknown, expired or stale, take `elements` again and " <>
      "use the references in THAT reply, never re-send the old ones. `elements` is " <>
      "best-effort accessibility metadata: an empty result means no controls were exposed " <>
      "there. "
  end

  defp coordinates_description(offered) do
    replies = image_replies(offered)

    "AIMING — ONE RULE: coordinates are pixels in the image you name. Every reply that " <>
      "gives you coordinates names its image: " <>
      spoken_list(replies, "and") <>
      returns(replies) <>
      " an `observation_id`, and every click, move, drag" <>
      naming(offered, ["inspect"], ", scroll and inspect", " and scroll") <>
      " must carry the id of the image its x,y were read in. There is no region to copy onto an " <>
      "action, and coordinates read in one image NEVER apply to another — read and aim in " <>
      "the same image, in the same breath. Only the last few images stay addressable and " <>
      "only for about half a minute; if an id is refused as unknown, expired or stale, take " <>
      "a fresh `screenshot` and read the coordinates again in IT, never re-send the old ones. " <>
      "Prefer exact targets where a surface exposes them (`browser` element " <>
      "actions, numbered `marks`). Take a `screenshot` with " <>
      "`\"marks\": true` and act with `mark: <id>` plus that image's `observation_id` — the " <>
      "exact point is resolved for you, " <>
      "which beats any pixel estimate. " <>
      naming(offered, ["elements"], "`elements`/`marks` are", "`marks` are") <>
      " best-effort accessibility " <>
      "metadata: an empty result means no accessibility-backed points were exposed, not that " <>
      "visible content cannot accept pixel interaction. In the MANAGED browser, use `get " <>
      "field=rect` + `click_coords` for a visible DOM target; THIS tool's pixels are for " <>
      "every other surface. "
  end

  # The replies that name an image on this reading: `screenshot`, then `elements`
  # and `windows` only where the helper lists them.
  defp image_replies(offered),
    do: Enum.map(["screenshot" | Enum.filter(~w(elements windows), &(&1 in offered))], &"`#{&1}`")

  defp spoken_list([one], _conjunction), do: one

  defp spoken_list([_ | _] = names, conjunction),
    do: Enum.join(Enum.drop(names, -1), ", ") <> " #{conjunction} " <> List.last(names)

  defp returns([_one]), do: " returns"
  defp returns(_many), do: " each return"

  # Screen-share frames, zooming to the window, and Fermix's own companion. Where
  # the helper lists no `windows` (GNOME Wayland), the window's bounds are read in
  # a full screenshot instead.
  defp zoom_description(offered) do
    if "screenshot" in offered,
      do: window_zoom_description(offered),
      else:
        "Fermix's own floating voice companion may be on that screen — never act on its " <>
          "controls: they end the call you are on. "
  end

  defp window_zoom_description(offered) do
    "A screen-share frame is a LOW-DETAIL awareness image with no observation_id, so it is " <>
      "never a source of click coordinates: take a fresh `screenshot` to aim. " <>
      "ZOOM TO THE WINDOW, not just to small controls. A full-screen capture is downscaled to " <>
      "fit one size budget, so on a large or ultrawide display most of that budget goes to " <>
      "desktop you do not care about and the app you DO care about arrives too small to aim " <>
      "in. A `region` crop is rescaled to that same budget on its own, so cropping to the " <>
      "window you are working in can multiply your effective resolution several times over. " <>
      naming(
        offered,
        ["windows"],
        "Call `windows` to get the exact bounds — it returns a ready-made `region` per " <>
          "window, so you never estimate them — then pass that region",
        "Read the window's bounds in a full `screenshot`, then pass them as a `region`"
      ) <>
      " to `screenshot` and aim in the " <>
      "magnified image it returns, naming that image's id on every action inside it; zoom " <>
      "further for a small control within it. " <>
      "Fermix's own floating voice companion may be visible on that screen — never click it; " <>
      "its controls end the call you are on. If it covers your target, ask the human to move it. "
  end

  # What every mutating action comes back with, and what it does and does not prove.
  defp check_description(offered) do
    if "screenshot" in offered,
      do: view_check_description(offered),
      else:
        "A verb on a control returns the CONTROL, read again after the action: that is its " <>
          "state, never proof the action had its effect, so repeat a verb only when that " <>
          "state shows the effect is missing. Verify the effect through the surface's own " <>
          "structure where it has one (a `browser` snapshot or `get` for a page that browser " <>
          "drives). "
  end

  defp view_check_description(offered) do
    "`screenshot` to see the screen, then act on it (click, type, key, scroll, drag) using " <>
      "pixel coordinates read in the image that screenshot names. Every " <>
      "mutating action comes back with its own check, and you never ask for one: a click, " <>
      naming(offered, ["paste"], "drag, scroll, keystroke or paste", "drag, scroll or keystroke") <>
      " returns the VIEW it acted in — the same crop when the " <>
      "action was aimed in a zoomed image, the full screen otherwise — captured once that " <>
      "view stopped changing, and naming a NEW image: READ it, and aim your next action in " <>
      "it. " <>
      naming(
        offered,
        ["elements"],
        "A verb on a control returns the CONTROL instead, read again after the action: " <>
          "that is its state, never a picture and never proof the action had its effect. "
      ) <>
      "A check shows what the screen looks like now, not whether your input arrived, so " <>
      "repeat an action only when it shows the effect is missing. When the check says nothing " <>
      "visible changed, that is a fact about the VIEW and not a miss: do not repeat the " <>
      "action for it. " <>
      "Verify the effect through the surface's own structure where it has one (a " <>
      "`browser` snapshot or `get` for a page that browser drives), and change MECHANISM " <>
      "— element click, keyboard, the browser's own click — not aim. "
  end

  # The read-only look at one point, the screen wait, and the access mode.
  defp controls_description(offered) do
    naming(
      offered,
      ["inspect"],
      "`inspect` (read-only) reports the UI element under a point — its role and label — so " <>
        "you can confirm you're about to click the right control (e.g., a button labeled " <>
        "\"Delete\") before a consequential action. "
    ) <>
      naming(
        offered,
        ["wait_for_change"],
        "`wait_for_change` blocks until the screen updates (e.g. a page finishes loading) " <>
          "instead of repeated screenshots. "
      ) <>
      "Honor " <>
      "the configured access mode: standard confirms before anything " <>
      "irreversible; open acts autonomously but still confirms a truly dangerous/catastrophic " <>
      "action; strict is look-only."
  end

  # The bound-window surface, advertised only where the operator turned it on
  # (M42 slice 5 §1) and the helper's reading offers it (M86 F1). It is the same
  # switch everywhere: the actions in the enum, the parameter beside them, this
  # paragraph, the runtime steering. `Background` owns the list; nothing here
  # repeats it.
  defp background_description(offered) do
    if bound?(offered) do
      "WORK INSIDE ONE WINDOW. `windows` lists what is open; `select_target` with that " <>
        "window's `window_id` BINDS it, and from then on every look and every action is " <>
        "answered from that window's own picture — even when something covers it — and its " <>
        "coordinates are that window's, not the screen's. " <>
        naming(
          offered,
          ["press", "set_value"],
          "Where the window exposes named controls, `press` and `set_value` act on them " <>
            "without moving the pointer, so the person can keep working in front of you. "
        ) <>
        "While a window is bound, a mutating action " <>
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
  defp background_properties(offered) do
    if bound?(offered) do
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

  # `offered` is what the installed helper says it has (M86 F1), never the
  # library's whole list: a verb the helper lacks is one that always refuses.
  defp actions(offered) do
    if Config.background?(),
      do: offered,
      else: Enum.reject(offered, &(&1 in Background.actions()))
  end

  # Whether the bound-window surface is offered at all: the flag is on AND the
  # helper lists the verb that binds. Everything that names the surface asks
  # this, so the words never teach a binding the enum cannot carry.
  defp bound?(offered), do: "select_target" in actions(offered)

  # The schema for the helper's latest reading (`HelperActions`): what it offers
  # and how it sends input, read in one call so both halves are one helper's
  # answer. Read at the call, so the static copy registered at boot and the
  # per-turn refresh are the same function of the same facts.
  @impl true
  def parameters, do: schema(HelperActions.reading())

  defp schema(%{actions: offered, input_methods: input_methods}) do
    %{
      "type" => "object",
      "required" => ["action"],
      "additionalProperties" => false,
      "properties" =>
        background_properties(offered)
        |> Map.merge(control_properties(offered, input_methods))
        |> Map.merge(listing_properties(offered))
        |> Map.merge(until_property(offered))
        |> Map.merge(pixel_properties(offered))
        |> Map.merge(%{
          "action" => %{
            "type" => "string",
            "enum" => actions(offered),
            "description" => base_action_description(offered)
          },
          "observation_id" => %{
            "type" => "string",
            "description" => observation_id_description(offered)
          },
          "display" => %{
            "type" => "integer",
            "description" => "Display index; defaults to the configured display"
          },
          "text" => %{
            "type" => "string",
            "description" =>
              naming(
                offered,
                ["paste"],
                "Text to type or paste (for action=type/paste)",
                "Text to type (for action=type)"
              ) <>
                typing_into(
                  offered,
                  input_methods,
                  "; `type` with an `element_ref` puts it into that control, no keyboard"
                )
          },
          "ms" => %{
            "type" => "integer",
            "description" => "Milliseconds to wait (for action=wait)"
          }
        })
    }
  end

  # Where only the controls are served, an id names a listing and nothing else.
  defp observation_id_description(offered) do
    if "screenshot" in offered,
      do:
        "The image these coordinates were read in — the id a " <>
          spoken_list(image_replies(offered), "or") <>
          " reply named. REQUIRED on click/move/drag/scroll" <>
          naming(offered, ["inspect"], "/inspect") <>
          "; an id from one image never applies to another",
      else:
        "The listing these references belong to — the id an `elements` reply named. " <>
          "REQUIRED with an `element_ref`; an id from one listing never applies to another"
  end

  # The fields only a pixel verb takes: a point, a drag, a scroll, a chord, a
  # wait on the screen, a crop and the marks badged on a screenshot. A session
  # whose pixel route was refused is offered none of them.
  defp pixel_properties(offered) do
    if "screenshot" in offered,
      do: Map.merge(pointer_properties(), capture_properties(offered)),
      else: %{}
  end

  defp pointer_properties do
    %{
      "x" => %{
        "type" => "integer",
        "description" => "X pixel in the image named by observation_id"
      },
      "y" => %{
        "type" => "integer",
        "description" => "Y pixel in the image named by observation_id"
      },
      "modifiers" => %{
        "type" => "array",
        "items" => %{"type" => "string", "enum" => @modifiers},
        "description" => "Held modifier keys for a click (e.g. [\"cmd\"])"
      },
      "from" => point_schema("Drag start point, in pixels of the image named by observation_id"),
      "to" => point_schema("Drag end point, in pixels of the image named by observation_id"),
      "direction" => %{
        "type" => "string",
        "enum" => @scroll_directions,
        "description" => "Scroll direction"
      },
      "amount" => %{
        "type" => "integer",
        "minimum" => 1,
        "maximum" => @max_scroll_notches,
        "description" => "Notches to scroll, 1 to #{@max_scroll_notches}"
      },
      "chord" => %{
        "type" => "string",
        "description" => "Key chord for action=key, e.g. \"ctrl+s\""
      }
    }
  end

  defp capture_properties(offered) do
    %{
      "timeout_ms" => %{
        "type" => "integer",
        "description" => "Max ms to wait for a change (for action=wait_for_change; default 10000)"
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
          "Optional zoom rectangle {x,y,w,h}, for `screenshot`" <>
            naming(offered, ["elements"], ", `elements`") <>
            " and `wait_for_change` only. With `observation_id` it is in that image's " <>
            "pixels; without one it is in a full-screen screenshot's pixels" <>
            naming(offered, ["windows"], " (the space `windows` answers in)") <>
            ". The reply names a NEW image — aim in that one. A " <>
            "click, move, drag" <>
            naming(offered, ["inspect"], ", scroll or inspect", " or scroll") <>
            " never carries a region: it names its image with `observation_id` instead."
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
            "image's `observation_id`." <>
            naming(
              offered,
              ["press", "set_value"],
              " On `press`/`set_value` it names the badged CONTROL"
            )
      }
    }
  end

  # The fields that exist only for the accessibility actions (M86 F1): the
  # reference an `elements` listing mints, the text `set_value` sets, and the
  # state `toggle` ends in. Offered with the action they belong to, so a helper
  # without it is not handed the field either.
  defp control_properties(offered, input_methods) do
    element_ref_property(offered, input_methods)
    |> Map.merge(value_property(offered))
    |> Map.merge(on_property(offered))
  end

  defp element_ref_property(offered, input_methods) do
    if "elements" in offered do
      %{
        "element_ref" => %{
          "type" => "string",
          "description" =>
            "A control, by the reference an `elements` listing" <>
              naming(offered, ["screenshot"], " (or a mark)") <>
              " gave it — `e1`, " <>
              "`e2`, … A reference belongs to the listing that minted it, so send it with " <>
              "that reply's `observation_id`. " <>
              required_by(offered) <>
              typing_into(
                offered,
                input_methods,
                "`type` takes it to type into that control; "
              ) <>
              naming(
                offered,
                ["screenshot"],
                "a click, right-click, double-click, move or scroll may take it INSTEAD of x,y " <>
                  "where the control's line gives a point, and its bounds are re-read at that " <>
                  "moment. Never send both a reference and coordinates on one action",
                "the control is found again when the action runs"
              )
        }
      }
    else
      %{}
    end
  end

  # `type` with an `element_ref` types into that control only where the helper
  # sends input through accessibility (`input_methods` holds "ax", PROTOCOL.md
  # §1); elsewhere `type` types at the focus, and the words say nothing more.
  defp typing_into(offered, input_methods, text) do
    if "elements" in offered and "ax" in input_methods, do: text, else: ""
  end

  # The verbs on a control this reading offers, named where the reference is
  # required, so the sentence never names one the enum lacks.
  defp required_by(offered) do
    case Enum.filter(@verbs, &(&1 in offered)) do
      [] -> ""
      verbs -> "REQUIRED by " <> Enum.map_join(verbs, ", ", &"`#{&1}`") <> "; "
    end
  end

  defp on_property(offered) do
    if "toggle" in offered do
      %{
        "on" => %{
          "type" => "boolean",
          "description" =>
            "For action=toggle: the state the control should END in — true for on, false " <>
              "for off. Nothing is sent when it already reads so"
        }
      }
    else
      %{}
    end
  end

  # What `elements` reads beyond the whole window (M86 P2, PROTOCOL.md §2.1):
  # where to start, what to find, how deep to go, and which container to open.
  # Offered with `elements`, whose arguments they are.
  defp listing_properties(offered) do
    if "elements" in offered do
      %{
        "scope" => %{
          "type" => "string",
          "enum" => Protocol.scopes(),
          "description" =>
            "On `elements`" <>
              naming(offered, ["wait_for"], " (and inside `until`)") <>
              ": where to read — window (" <>
              scope_window(offered) <>
              "), app, focused, menu (open menus), dialog (open dialogs and alerts)"
        },
        "query" => %{
          "type" => "object",
          "properties" => %{"role" => %{"type" => "string"}, "name" => %{"type" => "string"}},
          "description" =>
            "On `elements`: list only the controls that match — `role` as a listing names it " <>
              "(button, textfield, checkbox, …) and/or `name`, text in its label, any case"
        },
        "skeleton" => %{
          "type" => "boolean",
          "description" =>
            "On `elements`: true reads three levels deep; a line with `+N inside` is a " <>
              "container to open with `root`"
        },
        "root" => %{
          "type" => "string",
          "description" =>
            "On `elements`: a reference from a listing — list only what is inside that " <>
              "control, with that listing's `observation_id`; references outside it stay valid"
        }
      }
    else
      %{}
    end
  end

  # The window `scope` reads: the bound one only where a window can be bound.
  defp scope_window(offered) do
    if bound?(offered), do: "the bound or front window", else: "the front window"
  end

  # A condition on the accessibility tree (M86 P2, PROTOCOL.md §5.1): what
  # `wait_for` waits for, and what an action that sends input waits for after it,
  # in the same call.
  defp until_property(offered) do
    if "wait_for" in offered do
      %{
        "until" => %{
          "type" => "object",
          "required" => ["kind"],
          "properties" => %{
            "kind" => %{
              "type" => "string",
              "enum" => ~w(appears disappears enabled value window_title menu_open menu_closed
                           text)
            },
            "role" => %{"type" => "string"},
            "name" => %{"type" => "string"},
            "element_ref" => %{"type" => "string"},
            "value" => %{"type" => "string"},
            "contains" => %{"type" => "string"},
            "scope" => %{"type" => "string", "enum" => Protocol.scopes()},
            "timeout_ms" => %{"type" => "integer"}
          },
          "description" =>
            "A condition on the controls. On `wait_for` it is what to wait for; on an action " <>
              "that sends input it waits for that action's effect in the same call. kind: " <>
              "appears / disappears (role and/or name, or disappears by element_ref), enabled " <>
              "(element_ref), value (element_ref + value), window_title / text (contains), " <>
              "menu_open / menu_closed. Optional scope, and timeout_ms 1–25000 (default 5000)"
        }
      }
    else
      %{}
    end
  end

  defp value_property(offered) do
    if "set_value" in offered do
      %{
        "value" => %{
          "type" => "string",
          "description" => "The text to set (for action=set_value)"
        }
      }
    else
      %{}
    end
  end

  # Words that name an accessibility action, rendered only while the helper's
  # reading offers every action they name (M86 F1): a sentence about a verb the
  # enum lacks teaches the model a capability this helper does not have.
  # `otherwise` is the wording without them, where the sentence needs one.
  defp naming(offered, actions, text, otherwise \\ "") do
    if Enum.all?(actions, &(&1 in offered)), do: text, else: otherwise
  end

  # Per-turn schema refresh (called by the agent loop when present): fold the LIVE
  # access mode + its guidance into the `action` description so the model knows the
  # current posture — strict (look only), standard (confirm destructive), or open
  # (autonomous). This is how the prompt-driven §14 confirm principle reaches the
  # model without a cached prompt section that would freeze on config change.
  @spec dynamic_parameters(map()) :: map()
  def dynamic_parameters(_context) do
    reading = HelperActions.reading()

    put_in(
      schema(reading),
      ["properties", "action", "description"],
      action_description(Config.current().access, reading.actions)
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

  defp base_action_description(offered) do
    "The GUI action. Read-only: " <>
      naming(offered, ["screenshot"], "screenshot, ") <>
      naming(offered, ["inspect"], "inspect, ") <>
      naming(
        offered,
        ["elements"],
        "elements (the controls, one line each with a reference and the verbs it takes" <>
          naming(
            offered,
            ["screenshot"],
            "; an empty result does not block pixel targeting of visible content"
          ) <> "), "
      ) <>
      naming(
        offered,
        ["windows"],
        "windows (list the open windows, each with a ready-made `region` — use it to " <>
          "crop to the app you are working in instead of squinting at a downscaled " <>
          "whole screen), "
      ) <>
      naming(
        offered,
        ["wait_for_change"],
        "wait_for_change (block until the screen changes, then return the new frame), "
      ) <>
      naming(offered, ["wait_for"], "wait_for (block until an `until` condition holds), ") <>
      naming(offered, ["mouse_move"], "mouse_move, ") <>
      "wait. Mutating: " <>
      Enum.join(mutating_names(offered), ", ") <>
      offered_verbs(offered) <>
      ". " <>
      background_actions_description(offered) <>
      naming(offered, ["elements"], prefer_control_description(offered))
  end

  # The mutating actions that are not verbs on a control, as the description names
  # them, in its order.
  @mutating_names [
    {"left_click", "left_click"},
    {"right_click", "right_click"},
    {"double_click", "double_click"},
    {"left_click_drag", "left_click_drag"},
    {"scroll", "scroll"},
    {"type", "type"},
    {"paste", "paste (clipboard — prefer for long text)"},
    {"key", "key"}
  ]

  defp mutating_names(offered),
    do: for({action, name} <- @mutating_names, action in offered, do: name)

  # Where only the controls are served, every input names one: there are no
  # keystrokes at the focus and no click to fall back to.
  defp prefer_control_description(offered) do
    if "screenshot" in offered do
      "PREFER A NAMED CONTROL: a verb its `elements` line lists, sent with its " <>
        "`element_ref`, cannot miss. " <>
        naming(offered, ["paste"], "`type` and `paste` remain", "`type` remains") <>
        " for text that must go " <>
        "through real keystrokes; click (by `element_ref` or point) only a control that " <>
        "lists no verb you need. A refused verb is a refusal, never a quiet click."
    else
      "EVERY INPUT NAMES A CONTROL: a verb its `elements` line lists, sent with its " <>
        "`element_ref`, or `type` with an `element_ref` for text. A refused verb is a " <>
        "refusal: nothing is done in its place."
    end
  end

  # The verbs on a control this reading offers, named for the description.
  defp verb_names(offered) do
    @verbs |> Enum.filter(&(&1 in offered)) |> Enum.map_join(", ", &"`#{&1}`")
  end

  # The verbs on a control this reading offers, in the order a listing names them.
  defp offered_verbs(offered) do
    case Enum.filter(@verbs, &(&1 in offered)) do
      [] -> ""
      verbs -> ", " <> Enum.join(verbs, ", ") <> " (verbs on a control)"
    end
  end

  defp background_actions_description(offered) do
    if bound?(offered),
      do:
        "Binding: select_target (bind one window from `windows`, or \"desktop\" for the whole " <>
          "screen), release_target (give it back) — both read-only, neither touches anything. ",
      else: ""
  end

  defp action_description(:strict, offered) do
    base_action_description(offered) <>
      " ACCESS=strict (look only): " <>
      naming(offered, ["screenshot"], "screenshot/mouse_move/wait", "elements/wait") <>
      " run; every mutating action is refused."
  end

  defp action_description(:standard, offered) do
    base_action_description(offered) <>
      " ACCESS=standard: act directly for routine navigation and typing, but FIRST ask the owner" <>
      " and wait for their reply before any irreversible action — delete, send, purchase, sign out," <>
      " overwrite, move to trash."
  end

  defp action_description(:open, offered) do
    base_action_description(offered) <>
      " ACCESS=open (autonomous): act directly, including ordinary destructive steps, WITHOUT" <>
      " asking — but STILL pause to confirm with the owner before a TRULY dangerous, catastrophic" <>
      " action: bulk/mass deletion, wiping or formatting data, sending money or irreversible" <>
      " external messages, or destructive system changes. A higher bar than standard, not zero."
  end

  # Read from the helper's latest reading like the schema, so an example never
  # shows an action the enum lacks (M86 P2). The copy registered at boot is the
  # pixel one; `tool_help` reads this again when it renders.
  @impl true
  def examples do
    offered = HelperActions.offered()
    Enum.filter(all_examples(offered), &example_offered?(&1.args, offered))
  end

  # An `until` rides only where `wait_for` is offered, whatever action carries it.
  defp example_offered?(%{"until" => _until} = args, offered),
    do: args["action"] in offered and "wait_for" in offered

  # `type` with no control types at the focus, which takes the pixel route's keys.
  defp example_offered?(%{"action" => "type"} = args, offered)
       when not is_map_key(args, "element_ref"),
       do: "type" in offered and "key" in offered

  defp example_offered?(args, offered), do: args["action"] in offered

  defp all_examples(offered) do
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
        args: %{"action" => "elements", "query" => %{"role" => "button", "name" => "save"}},
        note: "find a control: each line has its reference and the verbs it takes"
      },
      %{
        args: %{"action" => "press", "observation_id" => "7c1e-13", "element_ref" => "e4"},
        note:
          "press a control whose line lists `press`" <>
            naming(offered, ["screenshot"], " — no pointer, no aim, no miss")
      },
      %{
        args: %{
          "action" => "set_value",
          "observation_id" => "7c1e-13",
          "element_ref" => "e7",
          "value" => "chess.com"
        },
        note:
          "fill a field whose line lists `set_value`" <>
            naming(offered, ["screenshot"], ", instead of clicking it and typing")
      },
      %{
        args: %{
          "action" => "toggle",
          "observation_id" => "7c1e-13",
          "element_ref" => "e3",
          "on" => true
        },
        note: "make sure a checkbox ends ticked; nothing is sent if it already is"
      },
      %{
        args: %{
          "action" => "key",
          "chord" => "cmd+s",
          "until" => %{"kind" => "appears", "role" => "dialog"}
        },
        note: "act and wait for its effect in one call"
      },
      %{args: %{"action" => "type", "text" => "hello"}, note: "type into the focused field"}
    ]
  end

  # Like the examples, read from the helper's latest reading: a failure mode for
  # an action the schema does not carry is a capability advertised through the
  # back door (M86 P2).
  @impl true
  def failure_modes do
    offered = HelperActions.offered()

    common_failure_modes(offered) ++
      naming_list(offered, "screenshot", pixel_failure_modes(offered)) ++
      [consent_failure_mode()] ++
      naming_list(offered, "elements", control_failure_modes(offered)) ++
      naming_list(offered, "wait_for", wait_failure_modes()) ++
      background_failure_modes(offered)
  end

  defp naming_list(offered, action, modes), do: if(action in offered, do: modes, else: [])

  defp common_failure_modes(offered) do
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
            "Looking still works — wait rather than re-sending"
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
            "reached the screen is not knowable; the session was reset — " <>
            naming(offered, ["screenshot"], "read a fresh screenshot", "list the controls again") <>
            " before repeating anything"
      },
      %{
        tag: "performed, not verified",
        description:
          "the action was sent but its check could not be obtained; take a" <>
            naming(offered, ["screenshot"], " screenshot", "n `elements` listing") <>
            " to see the result instead of re-sending the action"
      }
      | addressing_failure_modes(offered)
    ]
  end

  # Where only the controls are served, an id names a listing and an action names
  # a control.
  defp addressing_failure_modes(offered) do
    if "screenshot" in offered do
      [
        %{
          tag: "observation_required",
          description:
            "an action aimed at a point or a control that named no observation_id; nothing " <>
              "was sent. Take a fresh look and send the action with the id it names"
        },
        %{
          tag: "unknown/expired/stale observation",
          description:
            "the image the action named is no longer addressable — replaced, aged out, or " <>
              "its display changed; nothing was sent. Take a fresh screenshot and re-read " <>
              "the coordinates in it"
        }
      ]
    else
      [
        %{
          tag: "observation_required",
          description:
            "an action on a control that named no observation_id; nothing was sent. List " <>
              "the controls again and send the action with the id that listing names"
        },
        %{
          tag: "unknown/expired/stale observation",
          description:
            "the listing the action named is no longer addressable — replaced, aged out, or " <>
              "its display changed; nothing was sent. Take `elements` again and use the " <>
              "references in it"
        }
      ]
    end
  end

  # The refusals only a pixel verb meets: a point, a capture, keys at the focus,
  # and a point named beside a reference or a mark.
  defp pixel_failure_modes(offered) do
    [
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
        tag: "text_outside_layout",
        description:
          "the keyboard layout cannot type that text; nothing was sent" <>
            naming(offered, ["paste"], " — use paste")
      },
      %{
        tag: "no_active_window / keyboard_not_neutral",
        description:
          "no single window is active to take the keys, or Caps Lock, a held key or another " <>
            "layout is on; nothing was sent. Act on the control by reference, or ask the user"
      },
      # A mark and coordinates on one action are refused by any helper that mints
      # marks; a reference joins them only where controls are listed.
      %{
        tag: "addressing_conflict",
        description:
          "the action named its target twice — " <>
            naming(
              offered,
              ["elements"],
              "an element_ref together with coordinates or a mark",
              "a mark together with coordinates"
            ) <> "; nothing was sent. Send one or the other"
      }
    ]
  end

  defp consent_failure_mode do
    %{
      tag: "consent_refused / consent_timeout",
      description:
        "the desktop's own prompt to allow screen capture or control was declined or not " <>
          "answered; nothing was sent. Ask the user, never work around it"
    }
  end

  # The controls a listing names, and every way a verb on one is refused.
  defp control_failure_modes(offered) do
    reference_failure_modes(offered) ++
      linux_control_failure_modes(offered) ++ accessibility_call_failure_modes()
  end

  defp reference_failure_modes(offered) do
    [
      %{
        tag: "stale_element",
        description:
          "the control the element_ref names is gone or was rebuilt; nothing was sent. Take " <>
            "`elements` again and use the new reference"
      },
      %{
        tag: "ambiguous_element / identity_unknown",
        description:
          "the control the element_ref names now matches several, or cannot be read " <>
            "reliably; nothing was sent. Take `elements` again and use the new reference"
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
          "the control has no route for that verb; nothing was sent and " <>
            naming(
              offered,
              ["screenshot"],
              "nothing was switched to a click for you — choose the mechanism yourself",
              "nothing was done in its place — choose another verb its line lists"
            )
      },
      %{
        tag: "state_unreadable",
        description:
          "a verb that reads the control's state first could not read it, so it could not " <>
            "tell whether to act; nothing was sent"
      },
      %{
        tag: "focus_refused",
        description:
          "focus on a control in a window that is not the active one; focus never brings a " <>
            "window forward, so nothing was sent"
      }
    ]
  end

  defp accessibility_call_failure_modes do
    [
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
    ]
  end

  # The refusals of a verb on a control that the Linux build answers: a pixel route
  # refused, and a toolkit that publishes no controls until a switch is set.
  defp linux_control_failure_modes(offered) do
    [
      %{
        tag: "pixels_unavailable",
        description:
          "this desktop cannot serve that action" <>
            naming(offered, ["screenshot"], " by pixels", ": every input here names a control") <>
            ", as the detail says; nothing was " <>
            "sent. Work by control: `elements`, then a verb on a reference"
      },
      %{
        tag: "scope_not_found / toolkit_accessibility_off",
        description:
          "nothing to read: the scope has no root right now (no focused window, no menu or " <>
            "dialog open), or the application's toolkit is not publishing its controls"
      }
    ]
  end

  defp wait_failure_modes do
    [
      %{
        tag: "check_unsupported / invalid_argument",
        description:
          "an `until` on an action that sends no input, or a condition, scope or argument " <>
            "the helper refuses; nothing was sent — fix it, or use wait_for to wait alone"
      },
      %{
        tag: "until not met",
        description:
          "the condition did not hold in time — an answer, not a failure; the action (if " <>
            "any) was still sent, so look before repeating it"
      }
    ]
  end

  # Listed only where the surface is offered: a failure mode for an action the
  # schema does not carry is a capability advertised through the back door.
  defp background_failure_modes(offered) do
    if bound?(offered) do
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
            "the bound window closed, its application quit, or it was minimized or is on " <>
              "another desktop; nothing was sent and nothing was un-minimized. Take windows " <>
              "and bind again"
        },
        %{
          tag: "target_obstructed",
          description:
            "something covers the bound window at that point (a window, a menu or a popup), " <>
              "so a click would land on it; nothing was sent and nothing was raised. Press the " <>
              "control by name instead"
        },
        %{
          tag: "target_binding_unavailable",
          description:
            "the helper cannot prove the window is the one it claims to be (it names no " <>
              "process, or its id now names another window), or this desktop allows no " <>
              "binding; nothing was bound. Take windows again, or work on the whole screen"
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
            "the bound window's own picture stalled or is not yet proven its own (one being " <>
              "checked again after a change: look again in a moment), or the window is too " <>
              "large to hold pictures of within the helper's memory budget; nothing was sent"
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
      metadata:
        telemetry
        |> Map.put(:action, Map.get(params, "action"))
        |> put_verb(params, HelperActions.reading().input_methods),
      input: params,
      result: result
    )

    result
  end

  # The verb an action sent to a control by name (M86 P2): `press`, `toggle`, …,
  # and `type` only when it named a control on a helper that types by
  # accessibility; elsewhere it typed at the focus. A word from the closed verb
  # list, read off the request on every row — refused ones included — and never
  # the value, the text, or the control's label.
  defp put_verb(metadata, %{"action" => "type"} = params, input_methods) do
    named? = Map.has_key?(params, "element_ref") or Map.has_key?(params, "mark")
    if named? and "ax" in input_methods, do: Map.put(metadata, :cu_verb, "type"), else: metadata
  end

  defp put_verb(metadata, %{"action" => action}, _input_methods) when action in @verbs,
    do: Map.put(metadata, :cu_verb, action)

  defp put_verb(metadata, _params, _input_methods), do: metadata

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
      "this origin (#{origin}) cannot start or drive one"
  end

  # A Buzz channel is one other people can post in, so a request there is not
  # proof the owner asked; the sentence names where the owner can ask instead.
  defp unavailable_message(:shared_channel) do
    "Desktop control isn't available from a Buzz channel, where other people can send " <>
      "messages. Ask from the Fermix app, your own chat, or by voice."
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
        {{:ok, Tool.error(gate_message(reason, HelperActions.offered()))},
         refusal_telemetry(reason)}
    end
  end

  # A refusal from this side's own gate. Naming a target twice is answered in the
  # words of the ways this helper's reading offers to name one.
  defp gate_message(:addressing_conflict, offered),
    do: code_message("addressing_conflict", offered)

  defp gate_message(reason, _offered), do: refusal_message(reason)

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
      "action was not sent. Looking still works: a `screenshot` sends no input. Wait for that " <>
      "work to finish, or tell the user you need the machine, before sending this again."
  end

  # WHICH conversation holds the cursor could not be established. A different fact
  # from `input_busy`, and it needs a different next move: telling the model to
  # wait for other work to finish would point it at work that may not exist.
  defp refusal_message({:refused, :input_unavailable}) do
    "this action was not sent: which conversation holds this machine's cursor and keyboard " <>
      "could not be established, and driving it without knowing risks two agents fighting " <>
      "for one pointer. Looking still works: a `screenshot` sends no input. Tell the user " <>
      "computer use needs a restart rather than retrying this."
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
      "belongs to — a target means something only in the image or listing it was read from. " <>
      "Take a fresh look (a `screenshot`, or the listing the target came from), then send " <>
      "this action again with the `observation_id` that reply names and the target you read " <>
      "in it."
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
  defp refusal_message({:background_unavailable, reason, target}) do
    "this action was not sent: the computer-use helper on this machine cannot work inside a " <>
      "bound window — #{background_cause(reason, target)}. Do not retry. Tell the user " <>
      "`fermix doctor` explains it, and work on the whole screen meanwhile."
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

  # A Linux helper binds a window only under X11, and its badge is a program
  # installed beside it; a macOS helper's badge is part of its bundle.
  defp background_cause(:no_targets, {:ok, "linux-" <> _arch}),
    do: "it cannot bind one in this desktop session"

  defp background_cause(:no_targets, _target), do: "this build cannot bind a window at all"

  defp background_cause(:indicator_missing, {:ok, "linux-" <> _arch}),
    do:
      "its on-screen indicator is not installed beside it, and work inside a window is " <>
        "never done without one on screen"

  defp background_cause(:indicator_missing, _target),
    do:
      "its on-screen indicator is not in the installed bundle, and work inside a window is " <>
        "never done without one on screen"

  defp background_cause(_unknown, _target),
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
    perform_result(Session.execute(session, request), request, HelperActions.offered())
  end

  # `offered` is the helper's latest reading: the refusals whose next step is an
  # argument or an action name only what it offers.
  defp perform_result(execution, request, offered) do
    case execution do
      {:ok, %{image: nil} = result} ->
        {{:ok, Tool.success(action_summary(result, offered))}, action_telemetry(result)}

      {:ok, %{image: image} = result} ->
        {{:ok, Tool.success_with_images(action_summary(result, offered), [image])},
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

        {{:ok, Tool.error(failure_message(failure, offered))}, telemetry}

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
  # model aims elsewhere or asks the person to move something. So are the refusals
  # whose detail is the cause: how many applications claim the active window,
  # which key state is on, why this desktop's pixel route is refused, and why a
  # capture could not serve (a bound window not yet proven its own, the desktop's
  # screen-sharing service).
  @detailed_codes ~w(point_outside_observation capture_geometry_mismatch ax_timed_out
                     ax_action_failed target_obstructed scope_not_found toolkit_accessibility_off
                     invalid_argument no_active_window keyboard_not_neutral pixels_unavailable
                     capture_unavailable)

  # The codes the capture behind a check can answer once the input has gone out,
  # each with a sentence true after it: the display's geometry, a capture that
  # stalled, a display that went away. Every other code's sentence was written for
  # a refusal before any input, and many open "this action was not sent", which
  # after a click that landed would buy a second real one.
  @check_codes ~w(capture_geometry_mismatch capture_stalled no_active_display display_asleep
                  display_disconnected)

  # A check the helper refused after the input had already gone out is a SUCCESS
  # here — the action happened — so the code it refused with would otherwise reach
  # neither the model's sentence nor the row. Both matter: `capture_geometry_mismatch`
  # is an operator fault whose own sentence says "do not retry, tell the user", and
  # the generic unverified lead ends in "take a fresh `screenshot`" — the exact
  # retry that code forbids. One authority per code, so the sentence comes from the
  # same `code_message/2` a refusal would have used, with the helper's numbers
  # after it exactly as `failure_message/2` places them. Any other code adds
  # nothing: the row carries it.
  defp action_summary(%{summary: summary, check_code: code} = result, offered)
       when code in @check_codes do
    summary <> " " <> code_message(code, offered) <> check_detail(code, result)
  end

  defp action_summary(%{summary: summary}, _offered), do: summary

  defp check_detail(code, %{check_detail: detail})
       when code in @detailed_codes and is_binary(detail),
       do: " (#{Controls.safe_sentence(detail)})"

  defp check_detail(_code, _result), do: ""

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
  # which are content and belong to the model's side of the wire. Protocol 12
  # adds three counts and a word (M86 P2): how many dialogs or menus an action
  # left open, why a walk stopped short, and what it cost in accessibility
  # messages — never what any of them said.
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
    :cu_mode,
    :cu_surfaces_count,
    :cu_truncated,
    :cu_ax_messages
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
  defp action_error_message(code)
       when code in ["no_active_display", "display_asleep", "display_disconnected"] do
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

  # The helper does not have this action. The schema offers only what the helper
  # listed (M86 F1), so this is a helper replaced under a running daemon.
  defp action_error_message("unknown_action"), do: unavailable_action_message()

  # The operating system's capture wedged inside the helper, which restarts
  # itself after this reply.
  defp action_error_message("capture_stalled") do
    "nothing was captured: the screen capture stalled inside the computer-use helper, which " <>
      "restarts itself after this. Take a `screenshot` again; if it keeps happening, tell the " <>
      "user."
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
    "this action was not sent: that control has no route for this verb — the verbs it takes " <>
      "are the ones its `elements` line lists. Reach it another way if you still want to: " <>
      "another verb it lists, or a click by its `element_ref` where its line gives a point. " <>
      "Nothing was switched for you."
  end

  # The same fact as Fermix's own conflict refusal, from the other side of the
  # wire, so it reads the same whichever half the request met first.

  # The helper wants a control and got none. Fermix never sends this shape (the
  # library refuses it first), so it means the two halves disagree about what the
  # action takes.
  defp action_error_message("element_required") do
    "this action was not sent: it names no control. A verb on a control acts on the " <>
      "`element_ref` an `elements` listing gave it — take `elements`, then send the reference " <>
      "of the control you want with that reply's `observation_id`."
  end

  # The helper said so where this side did not: the action named no image. The
  # same fact, so the same sentence.
  defp action_error_message("observation_required"), do: refusal_message(:observation_required)

  # A verb that reads the control's state first could not read it, so it could
  # not tell whether the control already holds what was asked — and it sent
  # nothing rather than guess (M86 P2). Nothing is switched for the model either.
  defp action_error_message("state_unreadable") do
    "this action was not sent: the control's current state could not be read, so whether " <>
      "it already holds what you asked could not be decided and nothing was sent rather than " <>
      "guessed. Take `elements` again to see it; if the state still reads nothing, choose " <>
      "another way yourself — another verb it lists, or a click by its `element_ref` — and " <>
      "look at the result."
  end

  # `focus` never brings a window forward: a window the person is not in is
  # theirs to switch to, not this action's.
  defp action_error_message("focus_refused") do
    "this action was not sent: that control is in a window that is not the active one, and " <>
      "`focus` never brings a window forward. Work in the window that is in front, or ask the " <>
      "user to switch to that one first."
  end

  # The scope the listing or the condition asked for has no root right now. The
  # helper's detail says which, so it rides after the sentence.
  defp action_error_message("scope_not_found") do
    "this action was not sent: that scope has nothing in it right now — no focused window, " <>
      "nothing focused, or no menu or dialog open, as the detail below says. Use another " <>
      "`scope`, or take a `screenshot` to see what is there."
  end

  # A build with no accessibility API (the Linux helper before it has a reader)
  # was asked about controls. Pixels are the honest alternative, and the only one.
  defp action_error_message("accessibility_unavailable") do
    "this action was not sent: the computer-use helper on this machine cannot read or act on " <>
      "controls at all. Work by pixels: take a `screenshot` and act in the image it names."
  end

  # The mirror image, on Linux: this session's pixel route is refused (a
  # compositor with no qualified route, a portal without its Registry or one that
  # is not running, no display), or the route does not serve this verb (`paste`
  # and `windows` on GNOME Wayland). The helper's detail says which, so it rides
  # after the sentence. Controls are the honest alternative.
  defp action_error_message("pixels_unavailable") do
    "this action was not sent: the computer-use helper cannot do this by pixels on this " <>
      "desktop, as the detail below says, but it can still act on controls. Work by control: " <>
      "list them with `elements` and act with a verb on a reference it gives."
  end

  # Linux: keys go only into a window that reads ACTIVE on the accessibility bus,
  # and none does, or several do, so they would land where nobody chose. Neither
  # the helper nor this side activates a window to make room; the detail says
  # which it was.
  defp action_error_message("no_active_window") do
    "this action was not sent: no single window is active to take the keys — none is, or " <>
      "several applications claim one, as the detail below says — and computer use never " <>
      "brings a window forward itself. Act on the control by reference instead (`type` or " <>
      "`set_value` with its `element_ref`, or `press`), or ask the user to click into the " <>
      "window they mean."
  end

  # Linux (X11): Caps Lock, a held modifier or a layout other than the first would
  # change what the keys type. The detail says which; clearing it is the person's.
  defp action_error_message("keyboard_not_neutral") do
    "this action was not sent: the keyboard is not in its plain state — Caps Lock is on, a " <>
      "key is held, or another layout is selected, as the detail below says — so the text " <>
      "would come out different. Send it with `paste`, or into the control by reference " <>
      "(`type` or `set_value` with its `element_ref`), or ask the user to clear it."
  end

  # The desktop's own capture or input session (GNOME Wayland's portal) failed,
  # went unanswered, or covers more than the one monitor shared. A bound window's
  # stream answers the same code, with its own sentence, where a window can be
  # bound at all (`code_message/2`).
  defp action_error_message("capture_unavailable") do
    "this action was not sent: the desktop's screen-sharing service could not serve it — " <>
      "the service failed or did not answer, or the screen is more than the one monitor that " <>
      "was shared. Work by control meanwhile: list them with `elements` and act with a verb " <>
      "on a reference it gives. If it keeps happening, tell the user."
  end

  # Re-validation found several controls where the reference named one, or could
  # not read the candidate reliably enough to know it is the same control. Acting
  # on either would be a guess, so the next move is a fresh listing.
  defp action_error_message(code) when code in ["ambiguous_element", "identity_unknown"] do
    "this action was not sent: the control its `element_ref` names could not be told apart " <>
      "from others, or could not be read reliably enough to be sure it is still the same one. " <>
      "Take `elements` again and use the reference from THAT reply; do not re-send this one."
  end

  # The application's toolkit publishes no tree until a switch is set (Qt,
  # Chromium). The helper's detail names the switch, which is the user's to set.
  defp action_error_message("toolkit_accessibility_off") do
    "this action was not sent: this application is not publishing its controls, because its " <>
      "toolkit keeps them off until a switch is set — the detail below names it. Work by pixels " <>
      "here (take a `screenshot`), and tell the user the switch if they want controls to work " <>
      "in it."
  end

  # The active keyboard layout cannot produce some character of the text. The
  # clipboard can, and `paste` is offered wherever `type` is.
  defp action_error_message("text_outside_layout") do
    "this action was not sent: the keyboard layout in use cannot type some of that text. " <>
      "Send it with `paste` instead."
  end

  # The person declined the desktop's own consent prompt for screen capture or
  # remote control, now or by an answer the desktop keeps. Theirs to decide; never
  # worked around, and a kept no is theirs to reset.
  defp action_error_message("consent_refused") do
    "this action was not sent: the person declined the desktop's request to let computer use " <>
      "see or control the screen. Do not retry. Ask them whether they want to allow it; a no " <>
      "the desktop remembers stays until they reset it, and `fermix doctor` prints how."
  end

  defp action_error_message("consent_timeout") do
    "this action was not sent: the desktop's request for permission to see or control the " <>
      "screen was not answered in time. Ask the user to watch for that prompt, then try again."
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

  # The build and the installed helper disagree about what a request may contain,
  # or how one is framed. No retry can fix that, and it is an operator fact, not a
  # model one.
  defp action_error_message(code)
       when code in ["unknown_field", "malformed_frame", "untagged_frame", "unknown_frame_type"] do
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
      else: "action failed: #{helper_reason(reason)}"
  end

  # A string here is a code the helper sent that this build has no sentence for:
  # the helper's text, so it reads the way its details do. Anything else is this
  # side's own term.
  defp helper_reason(reason) when is_binary(reason), do: Controls.safe_sentence(reason)
  defp helper_reason(reason), do: format_reason(reason)

  # The window is gone: closed, or its application quit, or the desktop would no
  # longer list its windows. A reused window number or a relaunched application
  # never revives a binding, so there is nothing to re-point at — the window has
  # to be found again from scratch.
  defp background_code_message("target_unavailable") do
    "this action was not sent: the window you bound is gone — it was closed, its " <>
      "application quit, or the desktop would not say which windows are open. Nothing was " <>
      "done to whatever is there now. Take `windows` to see what is open and `select_target` " <>
      "the window you want; do not re-send this one against the old binding."
  end

  # Minimized, or on another desktop, is recoverable by the PERSON, not by the
  # agent: nothing here un-minimizes a window or switches desktops, because that
  # is a visible change to their desktop nobody asked for.
  defp background_code_message("target_minimized") do
    "this action was not sent: the window you bound is minimized or on another desktop, so " <>
      "there is nothing of it to see or act on. Nothing was un-minimized or switched to for " <>
      "you. Ask the user to bring it back, or `select_target` a different window; `windows` " <>
      "shows what is open."
  end

  # A pixel action needs the target to be the topmost window at that point, and
  # a menu or popup no window manager lists counts as in front too. Deliberately
  # does NOT offer to raise it: raising a window is exactly the visible
  # interruption a bound window exists to avoid.
  defp background_code_message("target_obstructed") do
    "this action was not sent: something is in front of the window you bound at that point " <>
      "— another window, or a menu or popup — so a click there would land on whatever is " <>
      "covering it. Nothing was raised, closed or brought forward. The detail below names " <>
      "what is in front; if it is Fermix's own on-screen indicator, that is the panel with " <>
      "pause and stop on it and clicking through it would press one of those. Reach the " <>
      "control by name instead — take `elements` and `press` or `set_value` it, which does " <>
      "not go through the pointer at all — or aim somewhere the window is not covered, or ask " <>
      "the user to move or close what is on top."
  end

  # The window was bound but its accessibility window was not, so there is no
  # root to walk and no control to name. The pointer still works, which is the
  # honest alternative rather than a silent one.
  defp background_code_message("ax_binding_unavailable") do
    "this action was not sent: the window you bound exposes no accessibility window, so its " <>
      "controls cannot be listed or named. Work by pixels here instead: take a `screenshot` " <>
      "and click in the image it names, knowing the pointer moves where the user can see it."
  end

  # The on-screen indicator is not beside the helper, never started, or died. An
  # operator fact: work inside a window is not done invisibly, so the answer is to
  # tell the user, never to retry into the same wall.
  defp background_code_message("control_surface_unavailable") do
    "this action was not sent: the computer-use helper's on-screen indicator is not up — it " <>
      "is not installed beside the helper, or it could not start or stopped — and the helper " <>
      "will not work inside a window with nothing on screen to show the user that it is " <>
      "doing so or to stop it. Do not retry. Tell the user the on-screen computer-use " <>
      "indicator is not running; the whole screen still works as usual."
  end

  # The window's own picture is not delivering, or is not yet proven to be the
  # window's rather than what covered it: it did not repaint in time, or it is
  # proved again after a resize or being shown again, which a moment settles.
  # Distinct from the display being asleep: the display may be perfectly awake.
  # The helper's detail says which, so it rides after the sentence.
  defp background_code_message("capture_unavailable") do
    "this action was not sent: the picture of the window you bound could not be obtained or " <>
      "proven to be that window's own — it did not draw itself in time, it is being checked " <>
      "again after it changed size or was shown again, or its stream stalled, as the detail " <>
      "below says. If it is being checked again, wait a moment and look again; otherwise " <>
      "take `windows` to see whether it is still open, and `select_target` it again to start " <>
      "a fresh picture of it."
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

  # Linux: the helper cannot prove the window is the one it claims to be — it
  # names no process, or its id now belongs to another process's window than
  # `windows` listed — or the desktop allows no binding at all (Wayland). Binding
  # the wrong window is the failure this refuses, so a fresh listing comes first
  # and the whole screen is the honest alternative.
  defp background_code_message("target_binding_unavailable") do
    "this action was not sent: this window cannot be bound — the helper cannot prove it is " <>
      "the window it claims to be (it names no process, as some popups do, or the window " <>
      "with that id is no longer the one `windows` listed), or this desktop allows no binding " <>
      "at all. Take `windows` again and `select_target` the window by the id it lists now; if " <>
      "it is refused again, work on the whole screen instead: " <>
      ~s(`select_target` with `"window_id": "desktop"`.)
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
  # act on. A detail can name a window by the title its maker chose, so it reads
  # the way a bound window's title does.
  defp failure_message(%{code: code, detail: detail} = failure, offered) do
    message = named_failure_message(failure, offered)

    if is_binary(detail) and (code in @detailed_codes or message =~ "action failed:"),
      do: message <> " (#{Controls.safe_sentence(detail)})",
      else: message
  end

  defp named_failure_message(%{code: code, dispatch: dispatch}, _offered)
       when code in @ax_failures,
       do: ax_dispatch_message(ax_cause(code, dispatch), dispatch)

  defp named_failure_message(%{code: code}, offered), do: code_message(code, offered)

  # The refusals whose next step is an argument, an action or a way of naming a
  # target: their sentence names only what this helper's reading offers. Every
  # other code has one sentence whatever the reading.
  defp code_message("check_unsupported", offered), do: check_unsupported_message(offered)
  defp code_message("invalid_argument", offered), do: invalid_argument_message(offered)
  defp code_message("addressing_conflict", offered), do: addressing_conflict_message(offered)

  # One code, two sources: a bound window's stream, and the desktop's own capture
  # on a Linux helper, which lists no binding at all. Only a helper that can bind
  # (with the flag on) can mean the window.
  defp code_message("capture_unavailable", offered) do
    if bound?(offered),
      do: background_code_message("capture_unavailable"),
      else: action_error_message("capture_unavailable")
  end

  # Only X11 answers these two, and it lists `paste`. A reading without it is never
  # sent to the clipboard.
  defp code_message(code, offered) when code in ["keyboard_not_neutral", "text_outside_layout"] do
    if "paste" in offered,
      do: action_error_message(code),
      else: keys_without_paste_message(code)
  end

  defp code_message(code, _offered), do: action_error_message(code)

  defp keys_without_paste_message("keyboard_not_neutral") do
    "this action was not sent: the keyboard is not in its plain state — Caps Lock is on, a " <>
      "key is held, or another layout is selected, as the detail below says — so the text " <>
      "would come out different. Send it into the control by reference (`type` or " <>
      "`set_value` with its `element_ref`), or ask the user to clear it."
  end

  defp keys_without_paste_message("text_outside_layout") do
    "this action was not sent: the keyboard layout in use cannot type some of that text. " <>
      "Tell the user which characters it could not type."
  end

  # Two answers to "where" on one request. Guessing which the model meant is a
  # click on the wrong thing, so it is refused, before anything is dispatched.
  # References exist only where the helper lists controls; a mark and a point
  # clash on any helper that badges marks.
  defp addressing_conflict_message(offered) do
    if "elements" in offered do
      "this action was not sent: it names its target twice — an `element_ref` together with " <>
        "coordinates or a `mark`. Send ONE: the reference, to act on that control wherever it " <>
        "now is, or the point, to act at those pixels of the image you named."
    else
      "this action was not sent: it names its target twice — a `mark` together with " <>
        "coordinates. Send ONE: the mark, to act at the point it badged, or the point, to " <>
        "act at those pixels of the image you named."
    end
  end

  # A check the helper cannot take on this action. Fermix decides the check by
  # rule, so the reachable case is a condition (`until`) on an action that sends
  # nothing, or one the helper could not read. Where `wait_for` is offered,
  # waiting alone is the way; elsewhere no argument of the model's caused it.
  defp check_unsupported_message(offered) do
    if "wait_for" in offered do
      "this action was not sent: its check could not be taken — a condition (`until`) can " <>
        "only follow an action that sends input, and it has to be one of the kinds the " <>
        "schema lists. To wait without acting, use `wait_for`."
    else
      "this action was not sent: its check could not be taken, and sending it again will " <>
        "not change that. Take a `screenshot` to see where things stand, and tell the user " <>
        "if it happens again."
    end
  end

  # A wrong value the helper named. Its detail says which, and that is the fix; the
  # examples are arguments this reading offers.
  defp invalid_argument_message(offered) do
    examples =
      naming_list(offered, "elements", ["an unknown `scope`", "an empty `query`"]) ++
        ["a combination that cannot go together"] ++
        naming_list(offered, "wait_for", ["a bad `until`"]) ++
        naming_list(offered, "toggle", ["a `toggle` without a true or false `on`"]) ++
        ["a `type` without `text`"]

    "this action was not sent: one of its arguments has a value the helper refuses, as the " <>
      "detail below says — " <> or_list(examples) <> ". Fix that argument and send it again."
  end

  defp or_list([only]), do: only
  defp or_list([first, second]), do: first <> " or " <> second
  defp or_list(items), do: Enum.join(Enum.drop(items, -1), ", ") <> ", or " <> List.last(items)

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
