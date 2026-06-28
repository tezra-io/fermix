defmodule FermixCore.Tools.Media.Backends.XAIImage do
  @moduledoc """
  xAI "Imagine" image backend (`grok-imagine-image-quality`) for the `:image`
  modality.

  Generate → `POST /v1/images/generations`; edit → `POST /v1/images/edits`, the
  source image embedded as a base64 data-URI (§6). xAI defaults to returning a
  *temporary* URL, so this backend always requests `response_format=b64_json`
  and decodes `data[].b64_json` directly; if a URL comes back anyway it is
  eagerly materialized to bytes before they expire (§428) — not a fallback but
  the provider's two documented response shapes. Masks are **not** supported
  (`mask: false`) and the tool rejects them before dispatch. The vendor key is
  reused from the xAI chat-provider config (§11.3); a missing key fails loud.
  """

  @behaviour FermixCore.Tools.Media.Backend

  alias FermixCore.Net.HttpClient
  alias FermixCore.Net.TimeoutPolicy
  alias FermixCore.Tools.Media.Support

  @base_url "https://api.x.ai/v1"
  @default_model "grok-imagine-image-quality"
  @provider :xai
  @ext "png"

  @impl true
  @spec name() :: atom()
  def name, do: :xai_image

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
  def supported_models, do: [@default_model]

  @impl true
  @spec capabilities() :: FermixCore.Tools.Media.Backend.capabilities()
  def capabilities,
    do: %{ops: [:generate, :edit], mask: false, multi_image_ref: false, async: false}

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

  defp dispatch(operation, request, call) do
    [
      url: "#{@base_url}/images/#{path(operation)}",
      method: :post,
      json: body(operation, request, call.model),
      receive_timeout: TimeoutPolicy.receive_timeout_for(:image_generation),
      retry: false
    ]
    |> Req.new()
    |> Req.Request.put_header("authorization", "Bearer #{call.key}")
    |> Req.merge(call.req_options)
    |> HttpClient.request("xAI Images #{operation}")
    |> handle_response(call)
  end

  defp path(:generate), do: "generations"
  defp path(:edit), do: "edits"

  defp body(:generate, request, model) do
    %{model: model, prompt: request.prompt, n: 1, response_format: "b64_json"}
    |> append_size(request)
  end

  defp body(:edit, request, model) do
    %{
      model: model,
      prompt: request.prompt,
      n: 1,
      response_format: "b64_json",
      image: data_uri(request.input_image)
    }
    |> append_size(request)
  end

  defp append_size(body, %{size: size}) when is_binary(size) and size != "",
    do: Map.put(body, :size, size)

  defp append_size(body, _request), do: body

  defp data_uri(%{bytes: bytes, mime: mime}),
    do: "data:#{mime};base64,#{Base.encode64(bytes)}"

  defp handle_response({:ok, %Req.Response{status: status, body: body}}, call)
       when status in 200..299,
       do: extract_artifact(body, call)

  defp handle_response({:ok, %Req.Response{status: status, body: body}}, _call),
    do: {:error, Support.http_error_message(status, body), %{}}

  defp handle_response({:error, reason}, _call),
    do: {:error, Support.network_error_message(reason), %{}}

  # Primary shape: the base64 we asked for.
  defp extract_artifact(%{"data" => [%{"b64_json" => b64} | _rest]}, _call) when is_binary(b64) do
    case Support.decode_base64(b64) do
      {:ok, bytes} -> {:ok, %{bytes: bytes, mime: "image/png", ext: @ext}, %{}}
      {:error, reason} -> {:error, reason, %{}}
    end
  end

  # Documented alternate shape: a temporary URL → materialize before it expires.
  defp extract_artifact(%{"data" => [%{"url" => url} | _rest]}, call) when is_binary(url) do
    case Support.materialize_url(url, call.req_options) do
      {:ok, %{bytes: bytes, mime: mime}} ->
        {:ok, %{bytes: bytes, mime: mime, ext: Support.ext_for_mime(mime)}, %{}}

      {:error, reason} ->
        {:error, reason, %{}}
    end
  end

  defp extract_artifact(_body, _call),
    do: {:error, "parser_changed: response had no data[].b64_json or data[].url", %{}}

  defp credential(opts), do: Support.provider_credential(opts, @provider, "XAI_API_KEY")

  defp model(opts) do
    case Keyword.get(opts, :model) do
      model when is_binary(model) and model != "" -> model
      _other -> @default_model
    end
  end

  defp req_options(context), do: Map.get(context, :req_options, [])
end
