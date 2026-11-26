defmodule FermixWebWeb.SetupLive.ModelSource do
  @moduledoc """
  Which models the setup page's provider picker shows (M107): the built-in
  catalog's options, and, for a provider with a live listing
  (`ModelListing.live?/1`), the listing of the **source** the Provider pane
  shows.

  A source (`source/4`) is everything that listing's answer depends on: the
  provider, the URL it is read from (Ollama's base URL as edited in the pane,
  else the configured one), the key it is read with (Vercel AI Gateway's as
  typed in the pane, else the configured one, held only as its SHA-256), and
  the ChatGPT sign-in OpenAI Codex's is read with (`ChatGPT.summary/0`, never
  the token, which rotates). The key itself goes only to the request.

  One slot holds the source last asked (`@model_source`) and its answer
  (`@live_models`: `nil` for a provider with no listing, `:loading`,
  `{:ok, models}` or `{:error, sentence}`). The listing is asked only from a
  connected page whose Provider tab shows, only when the source differs from
  the slot's, and off the page's process (`start_async/3`, keyed by the
  source): another tab, an edit no listing reads, a save that changes no
  source and showing the tab again ask nothing. An answer is applied only
  while its source is still the slot's and never touches the provider form,
  so edits typed meanwhile stay; a listing that stops answers with a sentence.
  Refresh (`refresh/1`) asks the slot's source again. The page keeps no typed
  key, so it is offered (`@model_refresh?`) only for a source the page can
  ask again by itself. A device-role engine asks nothing: the picker says
  why, at once.

  Seam: `config :fermix_web, :model_listing_impl` (default
  `FermixCore.Providers.ModelListing`), which the sign-in's own model check
  reads too (`listing_impl/0`).
  """

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, start_async: 3]

  alias FermixCore.Auth.ChatGPT
  alias FermixCore.Config
  alias FermixCore.Home.Role
  alias FermixCore.Providers.Descriptor
  alias FermixCore.Providers.ModelCatalog
  alias FermixCore.Providers.ModelListing
  alias Phoenix.LiveView.Socket

  require Logger

  @tab "provider"
  @stopped "the listing stopped before it answered"

  @type t :: %{
          provider: atom(),
          base_url: String.t() | nil,
          key_sha256: binary() | nil,
          sign_in: ChatGPT.summary() | nil
        }

  @doc "The slot before anything is asked."
  @spec init(Socket.t()) :: Socket.t()
  def init(%Socket{} = socket),
    do: assign(socket, live_models: nil, model_source: nil, model_refresh?: false)

  @doc """
  Brings the picker in line with the provider form: its catalog options, and
  the listing of its source when that is one to ask (see the moduledoc).
  `params` is the form as last posted, which carries a key typed in the pane.
  """
  @spec sync(Socket.t(), map()) :: Socket.t()
  def sync(%Socket{} = socket, params \\ %{}) when is_map(params) do
    provider = socket.assigns.provider_form.provider

    socket
    |> assign(:provider_models, catalog_models(provider))
    |> sync_listing(provider, listing_impl(), params)
  end

  @doc """
  After a move from `previous` to the active tab. The Provider pane shown
  afresh draws an empty key field, so its source is read without one.
  """
  @spec shown(Socket.t(), String.t()) :: Socket.t()
  def shown(%Socket{assigns: %{active_tab: @tab}} = socket, previous)
      when is_binary(previous) and previous != @tab,
      do: sync(socket)

  def shown(%Socket{} = socket, previous) when is_binary(previous), do: socket

  @doc "Refresh: asks the slot's source again, when the page can ask it by itself."
  @spec refresh(Socket.t()) :: Socket.t()
  def refresh(%Socket{assigns: %{active_tab: @tab, model_refresh?: true}} = socket),
    do: socket |> assign(:model_source, nil) |> sync()

  def refresh(%Socket{} = socket), do: socket

  @doc "An answer, applied only while its source is still the slot's."
  @spec handle_async({:model_source, t()}, {:ok, term()} | {:exit, term()}, Socket.t()) ::
          Socket.t()
  def handle_async({:model_source, %{provider: provider} = source}, result, %Socket{} = socket) do
    answer = answer(provider, result)

    if source == socket.assigns.model_source,
      do: assign(socket, :live_models, answer),
      else: socket
  end

  @doc """
  The source a listing of `provider` answers for: `inputs` are the pane's (the
  request's own options: `:base_url` as edited, `:api_key` as typed),
  `configured` the provider's configured block, which the listing reads where
  the pane gives nothing, and `sign_in` the ChatGPT sign-in (OpenAI Codex
  only, else nil). A key is kept as its SHA-256 alone.
  """
  @spec source(atom(), keyword(), keyword(), ChatGPT.summary() | nil) :: t()
  def source(provider, inputs, configured, sign_in)
      when is_atom(provider) and is_list(inputs) and is_list(configured) and
             (is_map(sign_in) or is_nil(sign_in)) do
    %{
      provider: provider,
      base_url: Keyword.get(inputs, :base_url) || Keyword.get(configured, :base_url),
      key_sha256: key_sha256(provider, inputs, configured),
      sign_in: sign_in
    }
  end

  @doc "The listing the page reads (`:model_listing_impl`); the sign-in's model check reads it too."
  @spec listing_impl() :: module()
  def listing_impl, do: Application.get_env(:fermix_web, :model_listing_impl, ModelListing)

  defp sync_listing(socket, provider, impl, params) do
    if impl.live?(provider),
      do: listing(socket, Role.admit(socket.assigns.engine_record), provider, impl, params),
      else: assign(socket, live_models: nil, model_source: nil, model_refresh?: false)
  end

  # A listing calls the provider; a device-role engine shows why it has none.
  defp listing(socket, {:error, {:device_role, sentence}}, _provider, _impl, _params),
    do: assign(socket, live_models: {:error, sentence}, model_source: nil, model_refresh?: false)

  # The static render never asks: the connected mount after it does.
  defp listing(socket, :ok, provider, impl, params) do
    cond do
      not connected?(socket) -> assign(socket, :live_models, :loading)
      socket.assigns.active_tab != @tab -> socket
      true -> ask_changed(socket, wanted(provider, socket.assigns.provider_form, params), impl)
    end
  end

  defp ask_changed(socket, {source, inputs, refresh?}, impl) do
    if source == socket.assigns.model_source,
      do: assign(socket, :model_refresh?, refresh?),
      else: ask(socket, source, inputs, refresh?, impl)
  end

  defp ask(socket, %{provider: provider} = source, inputs, refresh?, impl) do
    socket
    |> assign(live_models: :loading, model_source: source, model_refresh?: refresh?)
    |> start_async({:model_source, source}, fn -> impl.live_models(provider, inputs) end)
  end

  # The source the pane shows, the request's options, and whether the page
  # could ask that source again without the key typed in the pane.
  defp wanted(provider, provider_form, params) do
    inputs = inputs(provider, provider_form, params)
    configured = configured(provider)
    sign_in = sign_in(provider)
    source = source(provider, inputs, configured, sign_in)
    untyped = source(provider, Keyword.delete(inputs, :api_key), configured, sign_in)
    {source, inputs, source == untyped}
  end

  defp inputs(:ollama, provider_form, _params) do
    case Map.get(provider_form.field_values || %{}, :ollama_base_url) do
      url when is_binary(url) and url != "" -> [base_url: url]
      _absent -> []
    end
  end

  # Vercel AI Gateway lists only what a key's team may use (M105 §11.9), so a
  # key entered in the pane is the one asked with, before it is saved, as the
  # bytes a save stores (`maybe_put_string/3` keeps them as given); with the
  # field blank the listing uses the configured key, if any.
  defp inputs(:vercel, _provider_form, %{"vercel_api_key" => key}) when is_binary(key) do
    if String.trim(key) == "", do: [], else: [api_key: key]
  end

  defp inputs(_provider, _provider_form, _params), do: []

  defp configured(provider) do
    case Config.provider(provider) do
      {:ok, config} -> config
      {:error, :not_configured} -> []
    end
  end

  defp sign_in(:openai_codex), do: ChatGPT.summary()
  defp sign_in(_provider), do: nil

  # The key the Vercel AI Gateway listing is read with; the others read none.
  defp key_sha256(:vercel, inputs, configured) do
    case Keyword.get(inputs, :api_key) || Keyword.get(configured, :api_key) do
      key when is_binary(key) and key != "" -> :crypto.hash(:sha256, key)
      _none -> nil
    end
  end

  defp key_sha256(_provider, _inputs, _configured), do: nil

  defp answer(_provider, {:ok, {:ok, models}}) when is_list(models), do: {:ok, models}

  defp answer(_provider, {:ok, {:error, sentence}}) when is_binary(sentence),
    do: {:error, sentence}

  # Only the exit's kind reaches the log: its stack can hold the arguments of
  # the call it stopped in, and those can carry the key the pane was given.
  defp answer(provider, {:exit, reason}) do
    Logger.error("setup: the #{provider} model listing stopped: #{exit_kind(reason)}")
    {:error, @stopped}
  end

  defp exit_kind({%{__exception__: true, __struct__: module}, _stacktrace}), do: inspect(module)
  defp exit_kind(reason) when is_atom(reason), do: inspect(reason)
  defp exit_kind(_reason), do: "an exit"

  defp catalog_models(provider) do
    if provider in Descriptor.ids(),
      do: ModelCatalog.models_for(provider),
      else: ModelCatalog.models_for(:openai)
  end
end
