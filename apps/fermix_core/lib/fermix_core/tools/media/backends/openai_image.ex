defmodule FermixCore.Tools.Media.Backends.OpenAIImage do
  @moduledoc """
  OpenAI Images backend (`gpt-image-2`) for the `:image` modality.

  Generate → `POST /v1/images/generations` (JSON); edit → `POST /v1/images/edits`
  (multipart image[+mask] file parts). GPT image models *always* return
  `b64_json` and reject `response_format` / `input_fidelity` / transparent
  `background`, so this backend sends none of them and decodes `data[].b64_json`
  directly (§5). The vendor key is reused from the OpenAI chat-provider config
  (§11.3); a missing key fails loud, never a silent degrade (Rule #12).
  """

  @behaviour FermixCore.Tools.Media.Backend

  alias FermixCore.Net.HttpClient
  alias FermixCore.Net.TimeoutPolicy
  alias FermixCore.Tools.Media.Support

  @base_url "https://api.openai.com/v1"
  @default_model "gpt-image-2"
  @provider :openai
  @mime "image/png"
  @ext "png"

  @impl true
  @spec name() :: atom()
  def name, do: :openai_image

  @impl true
  @spec modality() :: :image
  def modality, do: :image

  @impl true
  @spec configured?(keyword()) :: boolean()
  def configured?(opts) when is_list(opts) do
    match?({:ok, _key}, credential(opts))
  end

  @impl true
  @spec supported_models() :: [String.t(), ...]
  # gpt-image-2 (default) + gpt-image-1.5; never the deprecated gpt-image-1 (§5).
  def supported_models, do: [@default_model, "gpt-image-1.5"]

  @impl true
  @spec capabilities() :: FermixCore.Tools.Media.Backend.capabilities()
  def capabilities,
    do: %{ops: [:generate, :edit], mask: true, multi_image_ref: true, async: false}

  @impl true
  @spec run(:generate | :edit, map(), keyword()) ::
          {:ok, map(), map()} | {:error, String.t(), map()}
  def run(operation, request, opts)
      when operation in [:generate, :edit] and is_map(request) and is_list(opts) do
    context = Keyword.get(opts, :context, %{})
    model = model(opts)

    case credential(opts) do
      {:ok, key} ->
        call = %{key: key, model: model, req_options: req_options(context)}

        Support.with_provider_call(@provider, model, request, context, fn ->
          dispatch(operation, request, call)
        end)

      {:error, reason} ->
        Support.provider_call_error(@provider, model, request, context, reason)
    end
  end

  defp dispatch(:generate, request, call) do
    Req.new(
      url: "#{@base_url}/images/generations",
      method: :post,
      json: generate_body(request, call.model),
      receive_timeout: TimeoutPolicy.receive_timeout_for(:image_generation),
      retry: false
    )
    |> Req.Request.put_header("authorization", "Bearer #{call.key}")
    |> Req.merge(call.req_options)
    |> HttpClient.request("OpenAI Images generate")
    |> handle_response()
  end

  defp dispatch(:edit, request, call) do
    Req.new(
      url: "#{@base_url}/images/edits",
      method: :post,
      form_multipart: edit_fields(request, call.model),
      receive_timeout: TimeoutPolicy.receive_timeout_for(:image_generation),
      retry: false
    )
    |> Req.Request.put_header("authorization", "Bearer #{call.key}")
    |> Req.merge(call.req_options)
    |> HttpClient.request("OpenAI Images edit")
    |> handle_response()
  end

  defp generate_body(request, model) do
    %{model: model, prompt: request.prompt, n: 1}
    |> append_size(request)
  end

  defp append_size(body, %{size: size}) when is_binary(size) and size != "",
    do: Map.put(body, :size, size)

  defp append_size(body, _request), do: body

  defp edit_fields(request, model) do
    [model: model, prompt: request.prompt, n: 1, image: file_part(request.input_image)]
    |> append_size_field(request)
    |> append_mask_field(request)
  end

  defp append_size_field(fields, %{size: size}) when is_binary(size) and size != "",
    do: fields ++ [size: size]

  defp append_size_field(fields, _request), do: fields

  defp append_mask_field(fields, %{mask: %{bytes: _bytes} = mask}),
    do: fields ++ [mask: file_part(mask)]

  defp append_mask_field(fields, _request), do: fields

  defp file_part(%{bytes: bytes, mime: mime, filename: filename}),
    do: {bytes, filename: filename, content_type: mime}

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) when status in 200..299,
    do: extract_artifact(body)

  defp handle_response({:ok, %Req.Response{status: status, body: body}}),
    do: {:error, Support.http_error_message(status, body), %{}}

  defp handle_response({:error, reason}),
    do: {:error, Support.network_error_message(reason), %{}}

  defp extract_artifact(%{"data" => [%{"b64_json" => b64} | _rest]}) when is_binary(b64) do
    case Support.decode_base64(b64) do
      {:ok, bytes} -> {:ok, %{bytes: bytes, mime: @mime, ext: @ext}, %{}}
      {:error, reason} -> {:error, reason, %{}}
    end
  end

  defp extract_artifact(_body),
    do: {:error, "parser_changed: response had no data[].b64_json", %{}}

  defp credential(opts), do: Support.provider_credential(opts, @provider, "OPENAI_API_KEY")

  defp model(opts) do
    case Keyword.get(opts, :model) do
      model when is_binary(model) and model != "" -> model
      _other -> @default_model
    end
  end

  defp req_options(context), do: Map.get(context, :req_options, [])
end
