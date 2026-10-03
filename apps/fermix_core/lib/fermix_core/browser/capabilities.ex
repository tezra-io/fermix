defmodule FermixCore.Browser.Capabilities do
  @moduledoc """
  What a profile mode can do, in one map consulted at the decision points.

  The modes differ in what the browser underneath will answer, and
  `ProfileServer` refuses a verb the mode withholds before any backend is asked
  to do it; the backend consults the rest. A managed Chrome is
  the daemon's: it redirects downloads, enumerates targets, opens and closes
  tabs. A granted tab is the person's: the extension's debugger exposes no
  `Browser` domain at all, the targets are the one tab, and a tab of somebody's
  own browser is not ours to close.

  Those differences live here rather than as `if`s spread through two and a half
  thousand lines, so the whole difference between two modes is readable at once
  and a new decision point is a key rather than another branch.
  """

  alias FermixCore.Browser.Error

  @type capability ::
          :download_redirect
          | :target_discovery
          | :target_attach
          | :tab_cap
          | :new_tab
          | :close_tab
          | :focus_tab
          | :cookies
          | :downloads
          | :webmcp

  @type t :: %{capability() => boolean()}

  # `tab_cap` is whether Fermix owns this browser's tabs and so may close the
  # oldest of them back to `max_tabs` after an `open`: the browser it launched,
  # never one somebody else started.
  @managed %{
    download_redirect: true,
    target_discovery: true,
    target_attach: true,
    tab_cap: true,
    new_tab: true,
    close_tab: true,
    focus_tab: true,
    cookies: true,
    downloads: true,
    webmcp: true
  }

  @attached_browser %{@managed | tab_cap: false}

  @attached_tab %{
    download_redirect: false,
    target_discovery: false,
    target_attach: false,
    tab_cap: false,
    new_tab: false,
    close_tab: false,
    focus_tab: false,
    cookies: false,
    downloads: false,
    webmcp: true
  }

  # The Fermix app's own browser pane, driven over the app's local wire: the
  # engine's browser as the managed Chrome is, so its tabs are Fermix's. The
  # wire addresses a tab by its id, so there is no debugger session to attach,
  # and it carries no WebMCP. It saves no download for a task either: on host
  # protocol 1 a download's `download.began` carries no source address and the
  # wire has no cancel, so a download could be vetted neither by its source nor
  # by its size as Chrome's are, and the app refuses every one. Nothing lands
  # in the workspace, so nothing is redirected there; `tab.open` still names
  # the downloads directory only because that wire requires the field.
  @fermix_app %{
    download_redirect: false,
    target_discovery: true,
    target_attach: false,
    tab_cap: true,
    new_tab: true,
    close_tab: true,
    focus_tab: true,
    cookies: true,
    downloads: false,
    webmcp: false
  }

  @doc """
  The capabilities of a profile mode.

  `:managed`, `:existing_session` and `:remote_cdp` all drive a whole browser
  over one CDP endpoint and differ only in who launched it, which decides
  whose tabs they are.
  """
  @spec for_mode(atom()) :: t()
  def for_mode(:managed), do: @managed
  def for_mode(:attached_tab), do: @attached_tab
  def for_mode(:fermix_app), do: @fermix_app
  def for_mode(mode) when is_atom(mode), do: @attached_browser

  @doc "Whether `capability` is available in `mode`."
  @spec allows?(atom(), capability()) :: boolean()
  def allows?(mode, capability) when is_atom(mode) and is_atom(capability) do
    Map.fetch!(for_mode(mode), capability)
  end

  @doc """
  The refusal for a capability the mode does not have.

  One code per mode, because the cause is always the same — the model asked a
  granted tab to do something browser-wide, or the app's pane for something its
  wire does not carry — and one sentence per capability, because the next move
  is not.
  """
  @spec refuse(atom(), capability()) :: {:error, Error.t()}
  def refuse(:attached_tab, capability) when is_atom(capability) do
    {:error, Error.new("unsupported_in_attached_tab", sentence(capability))}
  end

  def refuse(:fermix_app, capability) when is_atom(capability) do
    {:error, Error.new("unsupported_in_fermix_app", app_sentence(capability))}
  end

  defp sentence(:new_tab) do
    "This is the one tab you were granted, so I cannot open another one in that browser. " <>
      "Navigate this tab, or use the managed browser profile for a second page."
  end

  defp sentence(:close_tab) do
    "I cannot close a tab in your own browser. Close it yourself, or use the managed " <>
      "browser profile for tabs I opened."
  end

  defp sentence(:focus_tab) do
    "I cannot bring a tab of your own browser to the front. Switch to it yourself if you " <>
      "want to watch, and I will keep working in it either way."
  end

  defp sentence(:cookies) do
    "Cookies are browser-wide and the grant covers one tab, so I cannot read or clear them " <>
      "here. Use the managed browser profile for cookie work."
  end

  defp sentence(:downloads) do
    "Downloads in your own browser go wherever it sends them, so I cannot manage one from " <>
      "the granted tab. Use the managed browser profile to download a file."
  end

  defp sentence(capability) do
    "#{capability} is not available in the tab you granted. Use the managed browser profile " <>
      "for that."
  end

  # What the pane cannot do, Chrome can: each sentence names the profile that is
  # always Chrome. For WebMCP the next move is a choice, because the pane's own
  # snapshot and act may do without the page's tools; a file has no such route.
  defp app_sentence(:webmcp) do
    "The Fermix app's browser does not run a page's own WebMCP tools. To use them, open " <>
      ~s(the page with `profile: "fermix_chrome"`, which is always Chrome. When they are ) <>
      "not needed, read the page with `snapshot` and drive it with `act`."
  end

  defp app_sentence(:downloads) do
    "The Fermix app's browser does not save a task's downloads. To download the file, open " <>
      ~s(the page with `profile: "fermix_chrome"`, which is always Chrome, and download it ) <>
      "there."
  end

  defp app_sentence(capability) do
    "#{capability} is not available in the Fermix app's browser."
  end
end
