defmodule FermixCore.Browser.Capabilities do
  @moduledoc """
  What a profile mode can do, in one map consulted at the decision points.

  `ProfileServer` is one implementation of the whole browser surface, and the
  modes differ in what the browser underneath will answer. A managed Chrome is
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
          | :new_tab
          | :close_tab
          | :focus_tab
          | :cookies
          | :downloads

  @type t :: %{capability() => boolean()}

  @whole_browser %{
    download_redirect: true,
    target_discovery: true,
    target_attach: true,
    new_tab: true,
    close_tab: true,
    focus_tab: true,
    cookies: true,
    downloads: true
  }

  @attached_tab %{
    download_redirect: false,
    target_discovery: false,
    target_attach: false,
    new_tab: false,
    close_tab: false,
    focus_tab: false,
    cookies: false,
    downloads: false
  }

  @doc """
  The capabilities of a profile mode.

  `:managed`, `:existing_session` and `:remote_cdp` all drive a whole browser
  over one CDP endpoint and differ only in who launched it.
  """
  @spec for_mode(atom()) :: t()
  def for_mode(:attached_tab), do: @attached_tab
  def for_mode(mode) when is_atom(mode), do: @whole_browser

  @doc "Whether `capability` is available in `mode`."
  @spec allows?(atom(), capability()) :: boolean()
  def allows?(mode, capability) when is_atom(mode) and is_atom(capability) do
    Map.fetch!(for_mode(mode), capability)
  end

  @doc """
  The refusal for a capability the mode does not have.

  One code, because the cause is always the same — the model asked a granted tab
  to do something browser-wide — and one sentence per capability, because the
  next move is not.
  """
  @spec refuse(capability()) :: {:error, Error.t()}
  def refuse(capability) when is_atom(capability) do
    {:error, Error.new("unsupported_in_attached_tab", sentence(capability))}
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
end
