defmodule FermixCore.Tools.Browser do
  @moduledoc """
  Native browser automation through Fermix's supervised browser runtime.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Telemetry
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

  require Logger

  @log_summary_max 200

  @impl true
  @spec name() :: String.t()
  def name, do: "browser"

  @impl true
  @spec description() :: String.t()
  def description do
    "Control a supervised local browser (navigate, snapshot, fill/click/submit forms, tabs, screenshots OF ITS OWN PAGE) — this is its OWN managed browser instance, NOT the page/app/session the user has open on their screen (for that, use computer_use; to screenshot the user's actual desktop that is a computer_use action). USE FOR JavaScript/dynamic/interactive pages and live data (flight prices, dashboards, logins); do NOT use for a static fact (use web_search) or one readable page (use web_fetch)."
  end

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      type: "object",
      required: ["action"],
      properties: %{
        action: %{
          type: "string",
          enum: FermixCore.Browser.actions(),
          description: "Browser action to run."
        },
        profile: %{
          type: "string",
          description: "Browser profile name. Defaults to the configured browser profile."
        },
        url: %{
          type: "string",
          description: "URL for open or navigate actions."
        },
        path: %{
          type: "string",
          description: "Workspace-confined file path for upload actions."
        },
        target: %{
          type: "string",
          description: "Stable tab target id returned by browser results."
        },
        selector: %{
          type: "string",
          description:
            "CSS selector — for `act` `kind=get` `field=rect` (the element to measure) " <>
              "and `kind=wait` `wait_until=element`."
        },
        kind: %{
          type: "string",
          description:
            "Action kind for action=act: click | fill (REPLACE the field value) | " <>
              "type (APPEND text) | submit (find & click the form's primary submit/search " <>
              "button) | press (a key via key=…) | hover | get | wait | click_coords."
        },
        ref: %{
          type: "string",
          description: "Element ref from the latest snapshot."
        },
        text: %{
          type: "string",
          description: "Text for typing, filling, waiting, or dialog prompt input."
        },
        field: %{
          type: "string",
          description:
            "Field for get/storage: url | title | html | text | count | ready_state | " <>
              "rect (the viewport box {x,y,width,height} of the first `selector` match, " <>
              "in the same CSS space click_coords clicks in)."
        },
        value: %{
          type: "string",
          description: "Value for storage writes."
        },
        decision: %{
          type: "string",
          enum: ["accept", "dismiss"],
          description: "Dialog decision for action=dialog."
        },
        x: %{
          type: "number",
          description:
            "X for click_coords, in CSS-pixel page-viewport space (what `get field=rect` " <>
              "returns) — NOT screen pixels from computer_use, and NOT raw pixels off a " <>
              "browser screenshot (those are device pixels; divide by its device_pixel_ratio)."
        },
        y: %{
          type: "number",
          description: "Y for click_coords, in the same CSS-pixel page-viewport space as x."
        },
        button: %{
          type: "string",
          description: "Mouse button name for pointer actions."
        },
        key: %{
          type: "string",
          description: "Keyboard key for press actions."
        },
        wait_until: %{
          type: "string",
          description: "Wait target such as text, url, element, or load."
        },
        full_page: %{
          type: "boolean",
          description: "For screenshot: capture the full page."
        },
        format: %{
          type: "string",
          enum: ["png", "jpeg"],
          description: "Screenshot image format."
        },
        quality: %{
          type: "integer",
          description: "JPEG screenshot quality from 1 to 100."
        },
        width: %{
          type: "integer",
          description: "Reserved viewport width field."
        },
        height: %{
          type: "integer",
          description: "Reserved viewport height field."
        },
        interactive: %{
          type: "boolean",
          description:
            "For snapshot: include only interactive and important content. Defaults true."
        },
        compact: %{
          type: "boolean",
          description: "For snapshot: remove empty structural nodes. Defaults true."
        },
        depth: %{
          type: "integer",
          description: "For snapshot: maximum accessibility tree depth. Defaults 5."
        },
        include_urls: %{
          type: "boolean",
          description: "For snapshot: include link URLs when available. Defaults false."
        },
        timeout_ms: %{
          type: "integer",
          description: "Timeout in milliseconds."
        }
      }
    }
  end

  @impl true
  def when_to_use do
    "JavaScript/dynamic/interactive pages, forms, logins, or live data (e.g. flight prices) — " <>
      "not static text (use web_search/web_fetch), and not the page/app the user already has " <>
      "open on their screen (use computer_use for that; browser drives its own instance). " <>
      "On a desktop OS this IS a real window on the user's screen (it only runs headless on a " <>
      "display-less host, or if the operator configured that) — a separate profile from their " <>
      "own Chrome, but one they can see and touch. That makes it the RIGHT tool for a page you " <>
      "and the human share — a board you play on together, a dashboard you both watch. " <>
      "`state` reports `headless`; if it is ever true the human cannot see this window, so say " <>
      "so instead of assuming they are looking at it. A `snapshot` lists only what the page " <>
      "exposes as elements — a board/map/chart often exposes none, but it is still a DOM " <>
      "element: read its box with `get field=rect` and click positions inside it with " <>
      "`click_coords` (same CSS space, deterministic — no window position, no pixel " <>
      "guessing). `computer_use` pixels are for content OUTSIDE this browser's own window; " <>
      "using both on one page is normal."
  end

  @impl true
  def examples do
    [%{args: %{"action" => "navigate", "url" => "https://example.com"}, note: "open a page"}]
  end

  @impl true
  def failure_modes do
    [
      %{tag: "invalid_action", description: "action is not one of the supported browser verbs"},
      %{tag: "missing_action_arg", description: "the selected action is missing a required arg"},
      %{tag: "chrome_missing", description: "Chrome or Chromium is not installed or configured"},
      %{tag: "navigation_blocked", description: "browser URL policy blocked the navigation"},
      %{tag: "browser_busy", description: "all browser profile slots are active"}
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :web

  @impl true
  @spec execute(map(), Tool.context()) :: {:ok, Tool.tool_result()}
  def execute(args, context) when is_map(args) and is_map(context) do
    start = System.monotonic_time(:millisecond)
    outcome = FermixCore.Browser.execute(args, context)
    duration = System.monotonic_time(:millisecond) - start
    result = to_tool_result(outcome)
    success = match?({:ok, %{success: true}}, result)
    metadata = safe_metadata(args, outcome)

    log_failure(success, metadata)

    # Safe metadata (action/kind/profile/url/target/selector + error code &
    # summary on failure) is always recorded; raw `input`/`output` bodies stay
    # gated behind `capture_content?/0`.
    ToolTelemetry.exec("browser", context, success, duration,
      metadata: metadata,
      input: args,
      result: result
    )

    result
  end

  defp to_tool_result({:ok, output}), do: {:ok, screenshot_aware_success(output)}
  defp to_tool_result({:error, error}), do: {:ok, Tool.error(error_text(error))}

  # A `screenshot` action returns a JSON summary with an `image/*` mime_type and an
  # artifact path. Materialize the bytes as an image content part so the model can
  # SEE the capture instead of a path it can't open. The model-visible text stays
  # the summary — the bytes ride `:images` only, never the text/telemetry. Every
  # other action (and an unreadable artifact) returns the plain text summary, the
  # exact pre-existing shape — not a degraded fallback, just no image to attach.
  @doc false
  @spec screenshot_aware_success(String.t()) :: Tool.tool_result()
  def screenshot_aware_success(json) when is_binary(json) do
    case screenshot_image_part(json) do
      {:ok, image_part} -> Tool.success_with_images(json, [image_part])
      :none -> Tool.success(json)
    end
  end

  defp screenshot_image_part(json) do
    case Jason.decode(json) do
      {:ok, %{"mime_type" => "image/" <> _ = mime, "path" => path}} ->
        read_screenshot_artifact(mime, path)

      _not_an_image_result ->
        :none
    end
  end

  defp read_screenshot_artifact(mime, path) do
    case File.read(path) do
      {:ok, bytes} ->
        {:ok, %{type: :image, mime_type: mime, data: bytes}}

      {:error, reason} ->
        Logger.warning("browser screenshot artifact unreadable (#{inspect(reason)}): #{path}")
        :none
    end
  end

  # Always-on, body-free trace fields: structural identifiers plus a bounded
  # error code/summary on failure. URLs are reduced to scheme+host+path so query
  # tokens and userinfo never reach an ungated field; raw args/output ride the
  # gated `:input`/`:result` instead.
  defp safe_metadata(args, outcome) do
    %{
      action: Map.get(args, "action"),
      kind: Map.get(args, "kind"),
      profile: Map.get(args, "profile"),
      url: sanitize_url(Map.get(args, "url")),
      target_ref: Map.get(args, "target"),
      selector: Map.get(args, "selector")
    }
    |> reject_nil()
    |> put_error(outcome)
  end

  defp put_error(metadata, {:error, %{code: code, message: message}}) do
    metadata
    |> Map.put(:error_code, to_string(code))
    |> Map.put(:error_summary, Telemetry.preview(message))
  end

  defp put_error(metadata, _outcome), do: metadata

  @doc false
  # Public only for unit tests. Reduce a URL to `scheme://host/path`; drop query,
  # fragment, userinfo, and any URL without a network host (file:/data:/about:/
  # relative) so the always-on trace never carries secrets or local paths.
  @spec sanitize_url(term()) :: String.t() | nil
  def sanitize_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, path: path}
      when is_binary(scheme) and is_binary(host) and host != "" ->
        "#{scheme}://#{host}#{path || ""}"

      _other ->
        nil
    end
  end

  def sanitize_url(_url), do: nil

  defp log_failure(true, _metadata), do: :ok

  defp log_failure(false, metadata) do
    Logger.warning(
      "browser action failed: action=#{metadata[:action]} profile=#{metadata[:profile]} " <>
        "code=#{metadata[:error_code]} #{short(metadata[:error_summary])}"
    )
  end

  defp short(nil), do: ""
  defp short(text) when is_binary(text), do: String.slice(text, 0, @log_summary_max)

  defp reject_nil(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  # Surface the structured error (code + details) to the agent, not just the
  # message — details like Chrome's stderr on a launch failure or the blocked
  # URL on a policy denial are what make a failure actionable.
  defp error_text(%{code: code, message: message, details: details})
       when is_map(details) and map_size(details) > 0 do
    "#{message} (#{code}): #{Jason.encode!(details)}"
  end

  defp error_text(%{code: code, message: message}), do: "#{message} (#{code})"
end
