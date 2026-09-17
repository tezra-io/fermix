defmodule FermixCore.Tools.GenerateImage do
  @moduledoc """
  Create or edit a raster image from a text prompt; the result is written to the
  sandbox and, unless told otherwise, sent to the current chat.

  `delivery` makes that choice explicit: `"save"` generates and saves without
  touching a channel (the review-before-sending workflow — save, `view_image`
  the result, then `send_attachment`), `"send"` requires a usable media reply
  path BEFORE any provider call, and an omitted value keeps the declared context
  default. A requested send that fails is never reported as a successful save:
  the saved path comes back with the delivery error so the file can be retried
  without paying to generate it again.

  The agent states intent (prompt + a couple of enums); the operator's config
  picks the provider/model (`Media.Registry`). Edit references a source image by
  sandbox path or `inbound:last` (the image just sent in chat). The `edit`
  operation and the `mask` field are gated against the backend's declared
  `capabilities()` and rejected loudly when unsupported — never silently dropped
  (Rule #12).
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Config
  alias FermixCore.Tools.Media.Output
  alias FermixCore.Tools.Media.Registry
  alias FermixCore.Tools.Media.Support, as: MediaSupport
  alias FermixCore.Tools.Support, as: ToolSupport

  @operations ~w(generate edit)
  @deliveries ~w(save send)
  @modality :image

  @impl true
  @spec name() :: String.t()
  def name, do: "generate_image"

  @impl true
  @spec description() :: String.t()
  def description do
    "Create or edit a raster image (photo, illustration, render) from a text prompt; " <>
      "the result is saved to the sandbox and sent to the current chat unless " <>
      "delivery is \"save\". Not for diagrams, charts, or code assets, and not for live data."
  end

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      type: "object",
      required: ["prompt"],
      properties: %{
        prompt: %{
          type: "string",
          description: "What to create, or — for an edit — how to change the source image."
        },
        operation: %{
          type: "string",
          enum: @operations,
          description: "generate a new image (default) or edit an existing one."
        },
        input_image: %{
          type: "string",
          description:
            "For edit only: a sandbox path to the source image, or `inbound:last` to edit the image just sent in this chat."
        },
        mask: %{
          type: "string",
          description:
            "Optional sandbox path to a PNG-alpha mask (OpenAI backend only); only its transparent regions are edited."
        },
        size: %{
          type: "string",
          description: "Optional output size (e.g. 1024x1024). Defaults to the configured size."
        },
        model: %{type: "string", description: "Optional model override for this call."},
        delivery: %{
          type: "string",
          enum: @deliveries,
          description:
            "save = write the file and do not send it (inspect it with view_image first, " <>
              "then send_attachment); send = require a chat destination before generating. " <>
              "Omitted sends when this run has a chat channel and saves only when it does not."
        }
      }
    }
  end

  @impl true
  def when_to_use do
    "Create or edit a raster image from a text prompt (and optionally a source image already in the sandbox or just sent in chat); the result is sent to the chat unless you ask for delivery \"save\"."
  end

  @impl true
  def examples do
    [
      %{
        args: %{"prompt" => "a watercolor fox in a sunlit forest"},
        note: "generate a new image"
      },
      %{
        args: %{
          "operation" => "edit",
          "input_image" => "inbound:last",
          "prompt" => "make the sky stormy"
        },
        note: "edit the image just sent in chat"
      },
      %{
        args: %{"prompt" => "an outfit preview", "delivery" => "save"},
        note: "save it without sending, so you can look at it before you attach it"
      }
    ]
  end

  @impl true
  def failure_modes do
    [
      %{tag: "not_configured", description: "no image backend is configured (run setup)"},
      %{tag: "auth_failed", description: "the backend's vendor API key is missing or invalid"},
      %{tag: "edit_unsupported", description: "the configured backend cannot edit images"},
      %{tag: "mask_unsupported", description: "the configured backend does not support masks"},
      %{
        tag: "media_reply_unavailable",
        description: "delivery \"send\" was asked for but this run has no chat destination"
      },
      %{tag: "sandbox_denied", description: "a source/output path is outside the sandbox roots"},
      %{tag: "rate_limited", description: "the provider returned a rate limit"},
      %{tag: "provider_error", description: "the provider returned an unexpected HTTP error"},
      %{tag: "network", description: "transport or HTTP failure"}
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :media

  @impl true
  @spec execute(map(), Tool.context()) :: {:ok, Tool.tool_result()}
  def execute(args, context) when is_map(args) and is_map(context) do
    ToolSupport.run(name(), Map.delete(context, :tool_trace), fn -> do_execute(args, context) end)
  end

  defp do_execute(args, context) do
    case Config.tool(:generate_image) do
      {:ok, config} ->
        run_with_config(args, config, context)

      {:error, :not_configured} ->
        ToolSupport.error(
          "Image generation is not configured. Run `fermix setup` and choose an image backend."
        )
    end
  end

  defp run_with_config(args, config, context) do
    with {:ok, prompt} <- ToolSupport.required_string(args, "prompt"),
         {:ok, delivery} <- delivery(args),
         {:ok, backend} <- Registry.active_backend(@modality, config),
         {:ok, operation} <- operation(args),
         caps = backend.capabilities(),
         :ok <- ensure_operation(operation, caps),
         :ok <- ensure_delivery_route(delivery, context),
         {:ok, request} <- build_request(operation, prompt, args, config, caps, context) do
      opts = backend_opts(config, args, context)
      generate(backend, operation, request, opts, context, delivery)
    else
      {:error, message} -> ToolSupport.error(message)
    end
  end

  defp delivery(args) do
    case Map.get(args, "delivery") do
      nil ->
        {:ok, :default}

      "save" ->
        {:ok, :save}

      "send" ->
        {:ok, :send}

      other ->
        {:error,
         "delivery must be one of: #{Enum.join(@deliveries, ", ")} (got #{inspect(other)})"}
    end
  end

  # An explicit send is gated BEFORE the provider call so a run with nowhere to
  # deliver never pays for an image it cannot hand over.
  defp ensure_delivery_route(:send, context) do
    case Map.get(context, :reply_fn) do
      reply_fn when is_function(reply_fn, 1) ->
        :ok

      _absent ->
        {:error,
         "media_reply_unavailable: this run has no chat destination to send an image to. " <>
           "Use delivery \"save\" and report the saved path instead."}
    end
  end

  defp ensure_delivery_route(_delivery, _context), do: :ok

  defp operation(args) do
    case Map.get(args, "operation", "generate") do
      "generate" ->
        {:ok, :generate}

      "edit" ->
        {:ok, :edit}

      other ->
        {:error,
         "operation must be one of: #{Enum.join(@operations, ", ")} (got #{inspect(other)})"}
    end
  end

  defp ensure_operation(:generate, _caps), do: :ok

  defp ensure_operation(:edit, %{ops: ops}) do
    if :edit in ops,
      do: :ok,
      else:
        {:error,
         "The configured image backend does not support editing; switch backend or use generate."}
  end

  defp build_request(:generate, prompt, args, config, _caps, _context) do
    {:ok, %{prompt: prompt} |> put_size(args, config)}
  end

  defp build_request(:edit, prompt, args, config, caps, context) do
    with {:ok, source} <- ToolSupport.required_string(args, "input_image"),
         {:ok, input_image} <- MediaSupport.resolve_edit_image(source, context),
         {:ok, mask} <- resolve_mask(args, caps, context) do
      request =
        %{prompt: prompt, input_image: input_image}
        |> put_size(args, config)
        |> put_mask(mask)

      {:ok, request}
    end
  end

  defp resolve_mask(args, caps, context) do
    case Map.get(args, "mask") do
      mask when is_binary(mask) and mask != "" -> resolve_mask_path(mask, caps, context)
      _absent -> {:ok, nil}
    end
  end

  defp resolve_mask_path(mask, %{mask: true}, context),
    do: MediaSupport.resolve_edit_image(mask, context)

  defp resolve_mask_path(_mask, %{mask: false}, _context),
    do:
      {:error,
       "Mask editing is only supported by the OpenAI backend; remove mask or switch backend."}

  defp put_mask(request, nil), do: request
  defp put_mask(request, mask), do: Map.put(request, :mask, mask)

  defp put_size(request, args, config) do
    case size_value(args, config) do
      size when is_binary(size) and size != "" -> Map.put(request, :size, size)
      _none -> request
    end
  end

  defp size_value(args, config) do
    case Map.get(args, "size") do
      size when is_binary(size) and size != "" -> size
      _absent -> Keyword.get(config, :size)
    end
  end

  defp backend_opts(config, args, context) do
    config
    |> Keyword.put(:context, context)
    |> put_model_override(args)
  end

  defp put_model_override(opts, args) do
    case Map.get(args, "model") do
      model when is_binary(model) and model != "" -> Keyword.put(opts, :model, model)
      _absent -> opts
    end
  end

  defp generate(backend, operation, request, opts, context, delivery) do
    case backend.run(operation, request, opts) do
      {:ok, artifact, _trace} ->
        emit_and_report(backend, operation, artifact, context, delivery)

      {:error, reason, _trace} ->
        ToolSupport.error(reason)
    end
  end

  defp emit_and_report(backend, operation, artifact, context, delivery) do
    case Output.emit(artifact, %{modality: @modality, delivery: delivery}, context) do
      {:ok, %{path: path, delivered?: delivered?}} ->
        message = success_message(operation, path, delivered?, delivery)

        {:ok, Tool.success(message),
         trace(backend, operation, artifact, path, delivered?, delivery)}

      {:error, %{path: path, reason: reason}} ->
        ToolSupport.error(
          "The image was generated and saved to #{path} but could not be delivered: #{reason}"
        )

      {:error, %{reason: reason}} ->
        ToolSupport.error("The image was generated but could not be saved: #{reason}")
    end
  end

  defp success_message(_operation, path, false, :save),
    do: "Saved the image to #{path}; it was not sent."

  defp success_message(operation, path, true, _delivery),
    do: "#{verb(operation)} and sent the image (#{Path.basename(path)})."

  defp success_message(operation, path, false, _delivery),
    do:
      "#{verb(operation)} the image and saved it to #{path} (no chat channel was available to send it to)."

  defp verb(:generate), do: "Generated"
  defp verb(:edit), do: "Edited"

  defp trace(backend, operation, artifact, path, delivered?, delivery) do
    %{
      backend: Atom.to_string(backend.name()),
      operation: Atom.to_string(operation),
      bytes: byte_size(artifact.bytes),
      filename: Path.basename(path),
      delivered: delivered?,
      delivery_mode: Atom.to_string(delivery)
    }
  end
end
