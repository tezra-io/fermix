defmodule FermixCore.Tools.ViewImage do
  @moduledoc """
  Look at local image files: 1–6 sandbox-approved paths become image content
  parts on the next model continuation (M46 §5).

  This is the read-only counterpart to `file_read`, which is a text reader: the
  bytes ride the tool result's `:images` field and never appear in `:output`,
  in a log, or in a telemetry preview. The read is all-or-error — one bad path
  fails the whole call rather than silently omitting a reference the model then
  assumes it saw.

  Tool success proves the bytes were supplied, not that the picture shows what
  the model concludes; the inspection itself happens on the continuation.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Tools.Media.Support, as: MediaSupport
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

  @max_paths 6
  @max_file_bytes 10 * 1024 * 1024
  @max_total_bytes 24 * 1024 * 1024
  @allowed_mimes ["image/jpeg", "image/png", "image/webp"]
  @action :view_image

  @impl true
  @spec name() :: String.t()
  def name, do: "view_image"

  @impl true
  @spec description() :: String.t()
  def description do
    "Look at local image files. Returns the images themselves so you can see them, " <>
      "in the order given. JPEG, PNG and WebP only; 1-6 files per call."
  end

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      type: "object",
      required: ["paths"],
      properties: %{
        paths: %{
          type: "array",
          minItems: 1,
          maxItems: @max_paths,
          items: %{type: "string"},
          description:
            "Local paths to the images to look at, in reference order. One image is a " <>
              "one-element list. URLs, globs and directories are not accepted."
        }
      }
    }
  end

  @impl true
  def when_to_use do
    "See what a local image actually shows — a photo, a screenshot on disk, or a " <>
      "preview you just generated — before describing, comparing or sending it."
  end

  @impl true
  def examples do
    [
      %{args: %{"paths" => ["wardrobe/images/top.jpg"]}, note: "look at one photo"},
      %{
        args: %{
          "paths" => [
            "wardrobe/images/top.jpg",
            "wardrobe/images/trousers.jpg",
            "wardrobe/images/shoes.jpg"
          ]
        },
        note: "look at three garment references in order"
      }
    ]
  end

  @impl true
  def failure_modes do
    [
      %{tag: "missing_paths", description: "paths is absent, empty, or not a list of strings"},
      %{tag: "too_many_paths", description: "more than #{@max_paths} paths in one call"},
      %{tag: "sandbox_denied", description: "a path is outside the sandbox roots"},
      %{tag: "not_regular_file", description: "a path is missing, empty, or not a regular file"},
      %{tag: "image_too_large", description: "one file or the batch exceeds the byte cap"},
      %{tag: "image_type_unsupported", description: "the bytes are not JPEG, PNG or WebP"}
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :file

  @impl true
  @spec execute(map(), Tool.context()) :: {:ok, Tool.tool_result()}
  def execute(args, context) when is_map(args) and is_map(context) do
    start = System.monotonic_time(:millisecond)
    loaded = load(args, context)
    result = to_result(loaded)
    duration = System.monotonic_time(:millisecond) - start

    # `:result` deliberately carries the image-free result: the telemetry
    # emitter previews `:output`/`:error`, and raw pixels must never reach a
    # trace file or Opik.
    ToolTelemetry.exec(name(), context, match?({:ok, _images}, loaded), duration,
      metadata: metadata(loaded),
      input: args,
      result: without_images(result)
    )

    result
  end

  defp load(args, context) do
    with {:ok, paths} <- validate_paths(args) do
      read_all(paths, context)
    end
  end

  defp to_result({:ok, images}),
    do: {:ok, Tool.success_with_images(summary(images), Enum.map(images, &image_part/1))}

  defp to_result({:error, message}), do: {:ok, Tool.error(message)}

  defp without_images({:ok, result}), do: {:ok, Map.delete(result, :images)}

  # --- Validation ---------------------------------------------------------

  defp validate_paths(%{"paths" => paths}) when is_list(paths) do
    cond do
      paths == [] ->
        {:error, "paths must list at least one image path"}

      length(paths) > @max_paths ->
        {:error, "paths accepts at most #{@max_paths} images per call (got #{length(paths)})"}

      true ->
        validate_each(paths)
    end
  end

  defp validate_paths(%{"paths" => _other}),
    do: {:error, "paths must be an array of local image paths"}

  defp validate_paths(_args), do: {:error, "Missing required parameter: paths"}

  defp validate_each(paths) do
    paths
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, paths}, fn {path, index}, acc ->
      case validate_one(path) do
        :ok -> {:cont, acc}
        {:error, message} -> {:halt, {:error, "Reference #{index}: #{message}"}}
      end
    end)
  end

  defp validate_one(path) when is_binary(path) and path != "" do
    cond do
      String.contains?(path, "\0") -> {:error, "path contains null bytes"}
      url?(path) -> {:error, "URLs are not supported; give a local file path"}
      true -> :ok
    end
  end

  defp validate_one(_path), do: {:error, "path must be a non-empty string"}

  defp url?(path), do: String.match?(path, ~r/^[a-z][a-z0-9+.-]*:\/\//i)

  # --- Reading ------------------------------------------------------------

  # All-or-error: the first failing reference halts the batch and names itself,
  # so the model never gets a partial reference set it believes is complete.
  defp read_all(paths, context) do
    paths
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, [], 0}, fn {path, index}, {:ok, acc, total} ->
      read_one(path, index, context, acc, total)
    end)
    |> case do
      {:ok, acc, _total} -> {:ok, Enum.reverse(acc)}
      {:error, message} -> {:error, message}
    end
  end

  defp read_one(path, index, context, acc, total) do
    opts = [action: @action, max_bytes: @max_file_bytes, allowed_mimes: @allowed_mimes]

    case MediaSupport.read_local_image(path, context, opts) do
      {:ok, image} -> accumulate(image, index, path, acc, total)
      {:error, message} -> {:halt, {:error, reference_error(index, path, message)}}
    end
  end

  defp accumulate(image, index, path, acc, total) do
    running = total + byte_size(image.bytes)

    if running > @max_total_bytes do
      {:halt,
       {:error,
        reference_error(
          index,
          path,
          "the batch would reach #{running} bytes; the limit is #{@max_total_bytes} bytes"
        )}}
    else
      {:cont, {:ok, [Map.put(image, :index, index) | acc], running}}
    end
  end

  defp reference_error(index, path, message),
    do: "Reference #{index} (#{Path.basename(path)}): #{message}"

  # --- Result -------------------------------------------------------------

  defp summary(images) do
    Enum.map_join(images, "\n", fn image ->
      "Reference #{image.index}: #{image.filename} " <>
        "(#{image.mime}, #{human_bytes(byte_size(image.bytes))})"
    end)
  end

  defp image_part(image), do: %{type: :image, mime_type: image.mime, data: image.bytes}

  defp metadata({:ok, images}) do
    %{
      count: length(images),
      bytes: Enum.reduce(images, 0, &(byte_size(&1.bytes) + &2)),
      mime_types: images |> Enum.map(& &1.mime) |> Enum.uniq()
    }
  end

  defp metadata({:error, message}),
    do: %{count: 0, bytes: 0, mime_types: [], error: message}

  defp human_bytes(bytes) when bytes >= 1_048_576,
    do: "#{Float.round(bytes / 1_048_576, 1)} MiB"

  defp human_bytes(bytes) when bytes >= 1_024, do: "#{Float.round(bytes / 1_024, 1)} KiB"
  defp human_bytes(bytes), do: "#{bytes} bytes"
end
