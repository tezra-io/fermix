defmodule FermixCore.Tools.Media.Backends.GoogleImage do
  @moduledoc """
  Google Gemini image backend (`gemini-3.1-flash-image` default, plus
  `gemini-3-pro-image` and `gemini-2.5-flash-image`) for the
  `:image` modality, over the Gemini Developer API (`x-goog-api-key`, not Vertex
  — lighter for a single-binary BEAM app, §5).

  Generate and edit both use `POST /models/{model}:generateContent` (JSON). Edit
  appends the source image as a `inline_data` part on the request (snake_case);
  the produced image comes back base64 at `candidates[].content.parts[].inlineData.data`
  (camelCase) — the Gemini REST casing trap (§5), handled explicitly. Masks are
  **not** supported (`mask: false`; Gemini edits are instruction-guided) and the
  tool rejects them before dispatch. Unlike OpenAI/xAI the key lives in the tool
  block (`google_api_key`), since Gemini is not a chat provider (§11.3); a
  missing key fails loud.

  Pixel `size` is not forwarded: `generateContent` has no pixel-size knob (it is
  aspect-ratio based), so a requested size does not apply to this backend.
  """

  @behaviour FermixCore.Tools.Media.Backend

  alias FermixCore.Net.HttpClient
  alias FermixCore.Net.TimeoutPolicy
  alias FermixCore.Tools.Media.Support

  @base_url "https://generativelanguage.googleapis.com/v1beta"
  @default_model "gemini-3.1-flash-image"
  @provider :google

  @impl true
  @spec name() :: atom()
  def name, do: :google_image

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
  # default first; gemini-3-pro-image is the higher-quality opt-in tier,
  # gemini-2.5-flash-image the prior-generation flash model.
  def supported_models, do: [@default_model, "gemini-3-pro-image", "gemini-2.5-flash-image"]

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
      url: "#{@base_url}/models/#{call.model}:generateContent",
      method: :post,
      json: %{contents: [%{parts: parts(operation, request)}]},
      receive_timeout: TimeoutPolicy.receive_timeout_for(:image_generation),
      retry: false
    ]
    |> Req.new()
    |> Req.Request.put_header("x-goog-api-key", call.key)
    |> Req.merge(call.req_options)
    |> HttpClient.request("Google Images #{operation}")
    |> handle_response()
  end

  defp parts(:generate, request), do: [%{text: request.prompt}]

  defp parts(:edit, request) do
    %{bytes: bytes, mime: mime} = request.input_image
    [%{text: request.prompt}, %{inline_data: %{mime_type: mime, data: Base.encode64(bytes)}}]
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) when status in 200..299,
    do: extract_artifact(body)

  defp handle_response({:ok, %Req.Response{status: status, body: body}}),
    do: {:error, Support.http_error_message(status, body), %{}}

  defp handle_response({:error, reason}),
    do: {:error, Support.network_error_message(reason), %{}}

  defp extract_artifact(%{"candidates" => [candidate | _rest]}) when is_map(candidate) do
    case candidate |> get_in(["content", "parts"]) |> find_inline() do
      nil -> {:error, "parser_changed: response had no inlineData image part", %{}}
      inline -> build_from_inline(inline)
    end
  end

  defp extract_artifact(_body),
    do: {:error, "parser_changed: response had no candidates[].content.parts", %{}}

  defp find_inline(parts) when is_list(parts), do: Enum.find_value(parts, &inline_part/1)
  defp find_inline(_parts), do: nil

  defp inline_part(%{"inlineData" => %{"data" => data} = inline}) when is_binary(data), do: inline
  defp inline_part(_part), do: nil

  defp build_from_inline(%{"data" => data} = inline) do
    mime = Map.get(inline, "mimeType", "image/png")

    case Support.decode_base64(data) do
      {:ok, bytes} -> {:ok, %{bytes: bytes, mime: mime, ext: Support.ext_for_mime(mime)}, %{}}
      {:error, reason} -> {:error, reason, %{}}
    end
  end

  defp credential(opts), do: Support.config_credential(opts, :google_api_key, "GEMINI_API_KEY")

  defp model(opts) do
    case Keyword.get(opts, :model) do
      model when is_binary(model) and model != "" -> model
      _other -> @default_model
    end
  end

  defp req_options(context), do: Map.get(context, :req_options, [])
end
