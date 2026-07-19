defmodule FermixCore.Tools.Media.Backends.CodexImage do
  @moduledoc """
  Codex/ChatGPT-subscription image backend (`gpt-image-2`) for the `:image`
  modality — the counterpart to `OpenAIImage`, but authenticated by a ChatGPT
  OAuth bearer instead of a platform API key.

  Unlike every other media backend, the subscription cannot call the platform
  Images API (`api.openai.com/v1/images/generations` rejects the OAuth token).
  Instead it drives the built-in `image_generation` hosted tool over the same
  `chatgpt.com/backend-api/codex/responses` endpoint the Codex chat provider
  uses: a Responses-shape request whose top-level `model` is a GPT-5.x *router*
  (config `router_model`, default `gpt-5.6-terra`) and whose tool carries the
  real image model (`gpt-image-2`). The final PNG comes back as base64 in the
  `image_generation_call` output item, parsed out of the SSE stream by the shared
  `Codex.SSEParser`.

  This is an **undocumented, ChatGPT-auth-gated** surface (an API key is rejected
  by design); it is an explicitly experimental, opt-in backend and never a
  fallback (Rule #12). A missing/unusable OAuth token fails loud with an
  actionable `auth_failed`, and a 403 group-gate is surfaced as such — never a
  silent degrade.
  """

  @behaviour FermixCore.Tools.Media.Backend

  alias FermixCore.Auth.CodexToken
  alias FermixCore.Net.HttpClient
  alias FermixCore.Net.TimeoutPolicy
  alias FermixCore.Providers.OpenAI.Codex.SSEParser
  alias FermixCore.Tools.Media.Support

  @url "https://chatgpt.com/backend-api/codex/responses"
  @default_image_model "gpt-image-2"
  @default_router_model "gpt-5.6-terra"
  @instructions "You are an image generation assistant."
  # Telemetry/provider attribution reuses the Codex chat provider id so the image
  # span nests beside the operator's other Codex usage.
  @provider :openai_codex
  @mime "image/png"
  @ext "png"

  @impl true
  @spec name() :: atom()
  def name, do: :codex_image

  @impl true
  @spec modality() :: :image
  def modality, do: :image

  @impl true
  @spec configured?(keyword()) :: boolean()
  def configured?(opts) when is_list(opts) do
    case Keyword.get(opts, :access_token) do
      token when is_binary(token) and token != "" -> true
      _other -> token_present?(opts)
    end
  end

  @impl true
  @spec supported_models() :: [String.t(), ...]
  # The image model, sent as the tool's `model`. gpt-image-2 is GA + the default;
  # the GPT-5.x router is a separate config key, not a selectable image model.
  def supported_models, do: [@default_image_model]

  @impl true
  @spec capabilities() :: FermixCore.Tools.Media.Backend.capabilities()
  # Edit rides an `input_image` data-URI part; mask/inpaint is deferred (v1).
  def capabilities,
    do: %{ops: [:generate, :edit], mask: false, multi_image_ref: false, async: false}

  @impl true
  @spec run(:generate | :edit, map(), keyword()) ::
          {:ok, map(), map()} | {:error, String.t(), map()}
  def run(operation, request, opts)
      when operation in [:generate, :edit] and is_map(request) and is_list(opts) do
    context = Keyword.get(opts, :context, %{})
    image_model = image_model(opts)

    case resolve_token(opts) do
      {:ok, token} ->
        call = %{
          token: token,
          image_model: image_model,
          router_model: router_model(opts),
          req_options: req_options(context)
        }

        Support.with_provider_call(@provider, image_model, request, context, fn ->
          dispatch(operation, request, call)
        end)

      {:error, reason} ->
        Support.provider_call_error(@provider, image_model, request, context, reason)
    end
  end

  defp dispatch(operation, request, call) do
    Req.new(
      url: @url,
      method: :post,
      json: build_body(operation, request, call),
      headers: build_headers(call.token),
      receive_timeout: TimeoutPolicy.receive_timeout_for(:image_generation),
      retry: false
    )
    |> Req.merge(call.req_options)
    |> HttpClient.request("Codex image_generation")
    |> handle_response()
  end

  defp build_body(operation, request, call) do
    %{
      model: call.router_model,
      instructions: @instructions,
      input: [user_message(operation, request)],
      tools: [image_tool(operation, call.image_model, request)],
      tool_choice: "auto",
      store: false,
      stream: true
    }
  end

  defp user_message(:generate, request) do
    %{type: "message", role: "user", content: [text_part(request.prompt)]}
  end

  defp user_message(:edit, %{prompt: prompt, input_image: image}) do
    %{type: "message", role: "user", content: [text_part(prompt), image_part(image)]}
  end

  defp text_part(text), do: %{type: "input_text", text: text}

  defp image_part(%{bytes: bytes, mime: mime}),
    do: %{type: "input_image", image_url: "data:#{mime};base64,#{Base.encode64(bytes)}"}

  defp image_tool(operation, model, request) do
    %{type: "image_generation", model: model, output_format: @ext}
    |> maybe_put_action(operation)
    |> maybe_put_size(request)
  end

  # Generate stays byte-identical to the proven probe body (no `action`); edit is
  # made deterministic with an explicit `action`.
  defp maybe_put_action(tool, :edit), do: Map.put(tool, :action, "edit")
  defp maybe_put_action(tool, :generate), do: tool

  defp maybe_put_size(tool, %{size: size}) when is_binary(size) and size != "",
    do: Map.put(tool, :size, size)

  defp maybe_put_size(tool, _request), do: tool

  # The proven-in-prod Codex header profile (identical to the chat adapter's):
  # `stream: true` in the body — not an `accept` header — drives the SSE response.
  defp build_headers(token) do
    [
      {"authorization", "Bearer #{token}"},
      {"openai-beta", "responses=experimental"},
      {"originator", "pi"},
      {"content-type", "application/json"}
    ]
    |> maybe_put_account_id(token)
  end

  defp maybe_put_account_id(headers, token) do
    case CodexToken.account_id_from_token(token) do
      {:ok, account_id} -> [{"chatgpt-account-id", account_id} | headers]
      {:error, _reason} -> headers
    end
  end

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}), do: extract_image(body)

  defp handle_response({:ok, %Req.Response{status: 403, body: body}}) do
    if group_gated?(body),
      do: {:error, group_gate_message(), %{}},
      else: {:error, Support.http_error_message(403, decode_error_map(body)), %{}}
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}),
    do: {:error, Support.http_error_message(status, decode_error_map(body)), %{}}

  defp handle_response({:error, reason}),
    do: {:error, Support.network_error_message(reason), %{}}

  defp extract_image(body) do
    parsed = parse_body(body)

    case find_image_result(parsed) do
      {:ok, b64} ->
        case Support.decode_base64(b64) do
          {:ok, bytes} -> {:ok, %{bytes: bytes, mime: @mime, ext: @ext}, %{}}
          {:error, reason} -> {:error, reason, %{}}
        end

      :no_image ->
        {:error, no_image_message(parsed), %{}}
    end
  end

  # 200 SSE arrives as a raw string; parse to the body-shaped map. A defensive
  # map passthrough covers a non-stream shape without a second code path.
  defp parse_body(body) when is_binary(body), do: SSEParser.parse(body)
  defp parse_body(body) when is_map(body), do: body

  defp find_image_result(%{"output" => items}) when is_list(items) do
    Enum.find_value(items, :no_image, fn
      %{"type" => "image_generation_call", "result" => result}
      when is_binary(result) and result != "" ->
        {:ok, result}

      _item ->
        nil
    end)
  end

  defp find_image_result(_parsed), do: :no_image

  # A 200 with no image is either a model refusal (text present) or a shape the
  # parser no longer recognizes — surfaced distinctly, never as a fake success.
  defp no_image_message(parsed) do
    case assistant_text(parsed) do
      "" -> "parser_changed: Codex response had no image_generation_call result"
      text -> "provider_error: Codex returned text instead of an image: #{truncate(text)}"
    end
  end

  defp assistant_text(%{"output" => items}) when is_list(items) do
    items
    |> Enum.flat_map(fn
      %{"type" => "message", "content" => parts} when is_list(parts) -> parts
      _item -> []
    end)
    |> Enum.flat_map(fn
      %{"text" => text} when is_binary(text) -> [text]
      _part -> []
    end)
    |> Enum.join(" ")
    |> String.trim()
  end

  defp assistant_text(_parsed), do: ""

  defp group_gated?(body) do
    body
    |> decode_error_map()
    |> get_in(["error", "message"])
    |> then(fn
      message when is_binary(message) ->
        String.contains?(String.downcase(message), "image generation is not enabled")

      _other ->
        false
    end)
  end

  defp group_gate_message do
    "auth_failed: image generation is not enabled for this ChatGPT account/plan " <>
      "(the Codex backend gates the built-in image tool by plan tier). Use an " <>
      "API-key image backend instead, or try a plan that entitles it."
  end

  defp decode_error_map(body) when is_map(body), do: body

  defp decode_error_map(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) -> map
      _not_json -> %{}
    end
  end

  defp decode_error_map(_body), do: %{}

  defp resolve_token(opts) do
    case Keyword.get(opts, :access_token) do
      token when is_binary(token) and token != "" ->
        {:ok, token}

      _other ->
        case CodexToken.get_token(token_opts(opts)) do
          {:ok, token} ->
            {:ok, token}

          {:error, reason} ->
            {:error,
             "auth_failed: Codex OAuth token unavailable (#{inspect(reason)}). " <>
               "Run `fermix setup` and connect OpenAI Codex."}
        end
    end
  end

  defp token_present?(opts) do
    result =
      case Keyword.get(opts, :fermix_auth_path) do
        path when is_binary(path) -> CodexToken.read_entry(path)
        _other -> CodexToken.read_entry()
      end

    match?({:ok, %{tokens: %{access_token: token}}} when is_binary(token) and token != "", result)
  end

  defp token_opts(opts) do
    case Keyword.get(opts, :fermix_auth_path) do
      path when is_binary(path) -> [fermix_auth_path: path]
      _other -> []
    end
  end

  defp image_model(opts) do
    case Keyword.get(opts, :model) do
      model when is_binary(model) and model != "" -> model
      _other -> @default_image_model
    end
  end

  defp router_model(opts) do
    case Keyword.get(opts, :router_model) do
      model when is_binary(model) and model != "" -> model
      _other -> @default_router_model
    end
  end

  defp req_options(context), do: Map.get(context, :req_options, [])

  defp truncate(text) when is_binary(text) do
    if String.length(text) <= 200, do: text, else: String.slice(text, 0, 200) <> "…"
  end
end
