defmodule FermixWebWeb.SetupLive.AlwaysOn do
  @moduledoc """
  The browser setup's Always On tab (M75 §14, B14, lean v1 §7): the summary
  every surface prints (`home.status.summary`), and the device role's word on
  the rest of the page. Setting Always On up, and everything else it shows,
  belongs to the Fermix apps.

  The summary comes from `Management.Home.status/1` (`home.status`), read in
  the page's own process when the tab opens and on Refresh: its one sentence,
  and its action as the Fermix app's to take, or, for Learn more, the Always
  On docs page. Nothing on the tab names the engine's own words for the move.

  All of its state is the page's one `:always_on` assign. Seam, under
  `config :fermix_web, :always_on`: `home` (options for
  `Management.Home.status/1`).
  """

  use FermixWebWeb, :html

  alias FermixCore.Home.Role
  alias FermixCore.Management.Home
  alias FermixCore.Management.Placement

  require Logger

  @docs_url "https://fermix.ai/docs/always-on"
  @card "rounded-box border border-base-300 bg-base-100/80 p-5 shadow-sm"

  # Each tab of the page by the management request its controls make, so the
  # one placement table (`Management.Placement`) decides which engine serves
  # it. A tab missing here fails loud rather than being served by default.
  @tab_requests %{
    "provider" => {"settings.apply", "providers.openai"},
    "realtime" => {"settings.apply", "realtime"},
    "channels" => {"settings.apply", "channels.telegram"},
    "transcription" => {"settings.apply", "transcription"},
    "plugins" => {"plugins.list", nil},
    "search" => {"settings.apply", "web_search"},
    "media" => {"settings.apply", "generate_image"},
    "sandbox" => {"settings.apply", "sandbox"},
    "coding" => {"settings.apply", "harness"},
    "memory" => {"settings.apply", "memory"},
    "personalization" => {"settings.apply", "personalization"},
    "cues" => {"settings.apply", "cues"},
    "always_on" => {"home.status", nil},
    "doctor" => {"doctor.start", nil}
  }

  # -- the device role's word on the page ----------------------------------------

  @doc """
  The tabs the primary serves, which a device-role page shows as unavailable
  rather than editable: none off the device role.
  """
  @spec primary_tabs(Role.record(), [%{id: String.t()}]) :: [String.t()]
  def primary_tabs(%{role: :device}, tabs) when is_list(tabs) do
    for %{id: id} <- tabs, place(Map.fetch!(@tab_requests, id)) == :primary, do: id
  end

  def primary_tabs(%{role: role}, tabs) when role in [:primary, :candidate] and is_list(tabs),
    do: []

  defp place({method, nil}), do: Placement.place(method, %{})
  defp place({method, section}), do: Placement.place(method, %{"section" => section})

  # The server's own setup page is unreachable from here on most servers (it
  # listens on the server's loopback only), so the page points at the app.
  @doc "The notice a device-role page leads with, or nil off the device role."
  @spec device_notice(Role.record()) :: String.t() | nil
  def device_notice(%{role: :device} = record) do
    "This computer runs Fermix as a desktop of #{server_words(record)}. Fermix-wide " <>
      "settings live on the server: change them in the Fermix app on this computer. " <>
      "This page sets up this computer."
  end

  def device_notice(%{role: role}) when role in [:primary, :candidate], do: nil

  @doc "The sentence a tab the primary serves shows in the device role."
  @spec unavailable_sentence(Role.record()) :: String.t()
  def unavailable_sentence(%{role: :device} = record) do
    "These settings are Fermix-wide, so they live on #{server_words(record)}. Change them " <>
      "in the Fermix app on this computer."
  end

  defp server_words(%{primary: name}) when is_binary(name) and name != "",
    do: "your server, #{name}"

  defp server_words(_record), do: "your server"

  # -- state ---------------------------------------------------------------------

  @doc "The tab's state before anything is read, for the role the page booted in."
  @spec initial(Role.record()) :: map()
  def initial(%{role: role} = record) when role in [:primary, :device, :candidate],
    do: %{record: record, status: nil}

  @doc "Reads the picture afresh."
  @spec load(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def load(socket),
    do: Phoenix.Component.update(socket, :always_on, &%{&1 | status: Home.status(home_opts(&1))})

  @doc "The page moved to `tab`: the Always On tab is read afresh."
  @spec on_tab(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def on_tab(socket, "always_on"), do: load(socket)
  def on_tab(socket, tab) when is_binary(tab), do: socket

  # -- events --------------------------------------------------------------------

  @doc "One `always_on_*` event: Refresh reads the picture again."
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          Phoenix.LiveView.Socket.t()
  def handle_event("always_on_refresh", _params, socket), do: load(socket)

  # Anything else is not an event this tab draws: it changes nothing, and only
  # its name reaches the log, never its parameters.
  def handle_event(event, _params, socket) do
    Logger.warning("setup always on: ignored a malformed #{event} event")
    socket
  end

  # -- seams ---------------------------------------------------------------------

  defp home_opts(%{record: record}) do
    :fermix_web
    |> Application.get_env(:always_on, [])
    |> Keyword.get(:home, [])
    |> Keyword.put_new(:engine_role, record)
  end

  # -- drawing -------------------------------------------------------------------

  attr :always_on, :map, required: true

  @doc "The Always On tab."
  def pane(assigns) do
    ~H"""
    <div id="always-on-pane" class="space-y-6">
      <.title />
      <.status :if={@always_on.status} status={@always_on.status} />
    </div>
    """
  end

  defp title(assigns) do
    assigns = assign(assigns, docs: @docs_url)

    ~H"""
    <div class="flex flex-wrap items-start justify-between gap-3">
      <div class="min-w-0">
        <h2 class="text-2xl font-semibold tracking-normal">Always On</h2>
        <p class="mt-1 text-sm text-base-content/70">
          Fermix on a server you control, so it keeps working with this computer closed.
        </p>
      </div>
      <div class="flex gap-1">
        <button type="button" class="btn btn-ghost btn-sm" phx-click="always_on_refresh">
          <.icon name="hero-arrow-path" class="size-4" /> Refresh
        </button>
        <a href={@docs} target="_blank" rel="noopener noreferrer" class="btn btn-ghost btn-sm gap-1.5">
          <.icon name="hero-book-open" class="size-4" /> Docs
        </a>
      </div>
    </div>
    """
  end

  attr :status, :any, required: true

  defp status(assigns) do
    {:ok, %{"summary" => summary}} = assigns.status
    assigns = assign(assigns, summary: summary, card: @card, docs: @docs_url)

    ~H"""
    <section id="always-on-status" class={@card}>
      <p id="always-on-sentence" class="text-sm">{@summary["sentence"]}</p>
      <.summary_action action={@summary["action"]} docs={@docs} />
    </section>
    """
  end

  attr :action, :any, required: true
  attr :docs, :string, required: true

  # Learn more opens the docs here too; every other action is the app's.
  defp summary_action(%{action: nil} = assigns), do: ~H""

  defp summary_action(%{action: %{"id" => "learn_more"}} = assigns) do
    ~H"""
    <a
      id="always-on-learn-more"
      href={@docs}
      target="_blank"
      rel="noopener noreferrer"
      class="link mt-2 inline-block text-sm"
    >
      {@action["label"]}
    </a>
    """
  end

  defp summary_action(assigns) do
    ~H"""
    <p id="always-on-action" class="mt-2 text-sm text-base-content/70">
      In the Fermix app: {@action["label"]}.
    </p>
    """
  end
end
