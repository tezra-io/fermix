defmodule FermixCore.Tools.SendAttachment do
  @moduledoc """
  Send a local file through the active channel reply port.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Sandbox
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

  @kinds ~w(image document audio video voice)a

  @impl true
  @spec name() :: String.t()
  def name, do: "send_attachment"

  @impl true
  @spec description() :: String.t()
  def description do
    "Send a local file as an attachment through the current chat channel. URLs are not fetched."
  end

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      type: "object",
      required: ["path"],
      properties: %{
        path: %{
          type: "string",
          description: "Local file path to attach. URLs are not supported."
        },
        kind: %{
          type: "string",
          enum: Enum.map(@kinds, &Atom.to_string/1),
          description: "Attachment kind. Defaults to document."
        },
        caption: %{
          type: "string",
          description: "Optional text caption to send with the attachment."
        },
        filename: %{
          type: "string",
          description: "Optional display filename. Defaults to the local basename."
        },
        mime_type: %{
          type: "string",
          description: "Optional MIME type for channel APIs that accept it."
        }
      }
    }
  end

  @impl true
  def when_to_use do
    "Attach a local file already present in the sandbox to the active chat channel."
  end

  @impl true
  def examples do
    [
      %{
        args: %{"path" => "reports/summary.pdf", "kind" => "document", "caption" => "Summary"},
        note: "send a local document"
      }
    ]
  end

  @impl true
  def failure_modes do
    [
      %{tag: "reply_fn_required", description: "no active channel reply function is available"},
      %{tag: "url_not_supported", description: "URLs are sent as text by the model, not fetched"},
      %{tag: "sandbox_denied", description: "the local path is outside the sandbox roots"},
      %{tag: "not_regular_file", description: "the path is missing or is not a regular file"}
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
        {:ok, filename} -> {:ok, Tool.success("Sent attachment: #{filename}")}
        {:error, reason} -> {:ok, Tool.error(format_error(reason))}
      end

    duration = System.monotonic_time(:millisecond) - start
    success = match?({:ok, %{success: true}}, result)

    ToolTelemetry.exec("send_attachment", context, success, duration, input: args, result: result)

    result
  end

  defp do_execute(args, context) do
    with {:ok, reply_fn} <- reply_fn(context),
         {:ok, input_path} <- input_path(args),
         :ok <- reject_url(input_path),
         {:ok, kind} <- kind(args),
         {:ok, resolved_path} <- Sandbox.read_path(input_path, :send_attachment, context),
         :ok <- regular_file(resolved_path),
         {:ok, part} <- media_part(args, resolved_path, kind),
         :ok <- deliver(reply_fn, part) do
      {:ok, part.filename}
    end
  end

  defp reply_fn(%{reply_fn: reply_fn}) when is_function(reply_fn, 1), do: {:ok, reply_fn}

  defp reply_fn(_context), do: {:error, "send_attachment requires a channel reply context"}

  defp input_path(%{"path" => path}) when is_binary(path) and path != "", do: {:ok, path}
  defp input_path(_args), do: {:error, "Missing required parameter: path"}

  defp reject_url(path) do
    if String.match?(path, ~r/^[a-z][a-z0-9+.-]*:\/\//i),
      do: {:error, "URLs are not supported by send_attachment; send the link as text instead."},
      else: :ok
  end

  defp kind(args) do
    raw_kind = Map.get(args, "kind", "document")

    case raw_kind do
      kind when is_binary(kind) -> kind_from_string(kind)
      _other -> {:error, "kind must be one of: #{kind_list()}"}
    end
  end

  defp kind_from_string(kind) do
    atom = String.to_existing_atom(kind)

    if atom in @kinds,
      do: {:ok, atom},
      else: {:error, "kind must be one of: #{kind_list()}"}
  rescue
    ArgumentError -> {:error, "kind must be one of: #{kind_list()}"}
  end

  defp regular_file(path) do
    case File.stat(path) do
      {:ok, %{type: :regular}} -> :ok
      {:ok, %{type: type}} -> {:error, "Attachment path is not a regular file: #{inspect(type)}"}
      {:error, :enoent} -> {:error, "Attachment file not found: #{path}"}
      {:error, reason} -> {:error, "Failed to inspect attachment: #{inspect(reason)}"}
    end
  end

  defp media_part(args, path, kind) do
    filename = optional_string(args, "filename") || Path.basename(path)

    {:ok,
     %{
       kind: kind,
       path: path,
       filename: filename
     }
     |> maybe_put(:caption, optional_string(args, "caption"))
     |> maybe_put(:mime_type, optional_string(args, "mime_type"))}
  end

  defp optional_string(args, key) do
    case Map.get(args, key) do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp deliver(reply_fn, part) do
    case reply_fn.({:media, part}) do
      :ok -> :ok
      {:error, reason} -> {:error, "Failed to send attachment: #{format_delivery_error(reason)}"}
      other -> {:error, "Failed to send attachment: invalid reply result #{inspect(other)}"}
    end
  end

  defp format_delivery_error({:byte_cap_exceeded, actual, allowed}) do
    "attachment is #{format_bytes(actual)}; limit is #{format_bytes(allowed)}"
  end

  defp format_delivery_error({:rate_limited, retry_after_ms}) do
    "channel is rate limited; retry after #{format_duration(retry_after_ms)}"
  end

  defp format_delivery_error({:text_cap_exceeded, actual, allowed}) do
    "reply text is #{actual} characters; limit is #{allowed} characters"
  end

  defp format_delivery_error(reason), do: inspect(reason)

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1_048_576 do
    "#{Float.round(bytes / 1_048_576, 1)} MiB"
  end

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1_024 do
    "#{Float.round(bytes / 1_024, 1)} KiB"
  end

  defp format_bytes(bytes) when is_integer(bytes), do: "#{bytes} bytes"
  defp format_bytes(value), do: inspect(value)

  defp format_duration(ms) when is_integer(ms) and ms >= 1_000 and rem(ms, 1_000) == 0 do
    "#{div(ms, 1_000)}s"
  end

  defp format_duration(ms) when is_integer(ms) and ms >= 0, do: "#{ms}ms"
  defp format_duration(value), do: inspect(value)

  defp format_error(message) when is_binary(message), do: message
  defp format_error({:protected_path, path}), do: "Path is protected by the sandbox: #{path}"
  defp format_error({:outside_root, path}), do: "Path is outside the sandbox roots: #{path}"
  defp format_error({:blocked_root, path}), do: "Path is under a blocked root: #{path}"

  defp format_error({:too_many_symlinks, path}),
    do: "Path resolved through too many symlinks: #{path}"

  defp format_error(reason), do: "Sandbox denied: #{inspect(reason)}"

  defp kind_list, do: @kinds |> Enum.map(&Atom.to_string/1) |> Enum.join(", ")
end
