defmodule FermixCore.Capabilities.Builtin.Tool do
  @moduledoc """
  Behaviour for built-in tool implementations.

  Built-in tools live in `FermixCore.Tools.*` and surface as
  `kind: :builtin` capabilities through `FermixCore.Capabilities.Builtin.from_tool_module/1`.
  Each module declares its name/description/JSON-Schema parameters and a
  `c:execute/2` that returns a normalized result map.

  This behaviour replaces the older `FermixCore.Tools.Tool` behaviour
  removed in M4.9 Stage 7. Skill and MCP capabilities reuse `success/1`
  and `error/1` here so every capability returns the same result shape
  regardless of `kind`.
  """

  @type image_part :: %{
          required(:type) => :image,
          required(:mime_type) => String.t(),
          required(:data) => binary()
        }

  @type tool_result :: %{
          required(:success) => boolean(),
          required(:output) => String.t(),
          required(:error) => String.t() | nil,
          optional(:images) => [image_part()]
        }

  @type context :: %{
          required(:agent_name) => String.t(),
          required(:conversation_key) => term(),
          optional(atom()) => term()
        }

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters() :: map()
  @callback when_to_use() :: String.t()
  @callback examples() :: [map()]
  @callback failure_modes() :: [map()]
  @callback requires_setup() :: nil | map()
  @callback category() :: atom()
  @callback execute(map(), context()) :: {:ok, tool_result()} | {:error, term()}

  @optional_callbacks when_to_use: 0,
                      examples: 0,
                      failure_modes: 0,
                      requires_setup: 0,
                      category: 0

  @spec success(String.t()) :: tool_result()
  def success(output) when is_binary(output) do
    %{success: true, output: output, error: nil}
  end

  @doc """
  A successful result that returns one or more images to the model (e.g. a
  screenshot). `output` is the model-visible text summary; the images ride a
  dedicated `:images` field so they reach the provider as image content parts and
  never leak into text logs or telemetry — `Tools.Telemetry`/`Providers.Telemetry`
  preview `:output`/`:result`, never `:images`. Use `success/1` when there are no
  images; an empty image list here is a caller bug and fails loud.
  """
  @spec success_with_images(String.t(), [image_part()]) :: tool_result()
  def success_with_images(_output, []) do
    raise ArgumentError,
          "success_with_images/2 requires at least one image; use success/1 for none"
  end

  def success_with_images(output, images) when is_binary(output) and is_list(images) do
    Enum.each(images, &validate_image_part!/1)
    %{success: true, output: output, error: nil, images: images}
  end

  @spec error(String.t()) :: tool_result()
  def error(message) when is_binary(message) do
    %{success: false, output: "", error: message}
  end

  defp validate_image_part!(%{type: :image, mime_type: mime, data: data})
       when is_binary(mime) and mime != "" and is_binary(data),
       do: :ok

  defp validate_image_part!(part) do
    raise ArgumentError,
          "invalid image part for success_with_images/2: expected " <>
            "%{type: :image, mime_type: binary, data: binary}, got #{inspect(part)}"
  end
end
