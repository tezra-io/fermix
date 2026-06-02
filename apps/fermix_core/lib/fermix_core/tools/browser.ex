defmodule FermixCore.Tools.Browser do
  @moduledoc """
  Native browser automation through Fermix's supervised browser runtime.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool

  @impl true
  @spec name() :: String.t()
  def name, do: "browser"

  @impl true
  @spec description() :: String.t()
  def description do
    "Control a supervised local browser for navigation, snapshots, tabs, screenshots, and actions."
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
          description: "Reserved selector field for future scoped reads."
        },
        kind: %{
          type: "string",
          description: "Action kind for action=act."
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
          description: "Field name for get/storage actions."
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
          description: "X coordinate for coordinate actions."
        },
        y: %{
          type: "number",
          description: "Y coordinate for coordinate actions."
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
    "Open, inspect, and operate pages that require a JavaScript-capable browser."
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
    agent = Map.get(context, :agent_name, "unknown")

    result = do_execute(args, context)

    duration = System.monotonic_time(:millisecond) - start
    success = match?({:ok, %{success: true}}, result)

    # Record the action (and act-kind) so per-verb latency is visible in
    # tool_exec traces — the handler passes all metadata through.
    :telemetry.execute(
      [:fermix, :tool, :exec],
      %{duration_ms: duration},
      %{
        tool: "browser",
        action: Map.get(args, "action"),
        kind: Map.get(args, "kind"),
        agent: agent,
        success: success
      }
    )

    result
  end

  defp do_execute(args, context) do
    case FermixCore.Browser.execute(args, context) do
      {:ok, output} -> {:ok, Tool.success(output)}
      {:error, error} -> {:ok, Tool.error(error_text(error))}
    end
  end

  # Surface the structured error (code + details) to the agent, not just the
  # message — details like Chrome's stderr on a launch failure or the blocked
  # URL on a policy denial are what make a failure actionable.
  defp error_text(%{code: code, message: message, details: details})
       when is_map(details) and map_size(details) > 0 do
    "#{message} (#{code}): #{Jason.encode!(details)}"
  end

  defp error_text(%{code: code, message: message}), do: "#{message} (#{code})"
end
