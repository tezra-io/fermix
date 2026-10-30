defmodule FermixCore.Management.Browser do
  @moduledoc """
  The browser session hand-off's management methods (M75 D18, B10, §14), which
  the `fermix browser signin|handoff|handoffs` verbs call on `daemon.sock`.

    * `browser.signin.open {url}` (device-class): opens `url` in a headed
      Chrome on the engine-owned owner profile, for the owner to sign in; a
      host with no screen (a headless server) refuses it by name, since a
      sign-in there starts on the owner's desktop and is handed over.
    * `browser.handoff.send {sites, expires_s?, allow_identity_provider?}`
      (device-class, the device role only): reads that profile's cookies for
      exactly `sites` and sends them to the primary, which stores them until
      `expires_s` from now (7 days unless said, at most 30) and answers how
      many it stored. Identity providers are refused unless
      `allow_identity_provider` is true (`Browser.Handoff.Sites`).
    * `browser.handoffs.list` (primary-class: a linked desktop forwards it):
      the hand-offs this primary stores, from its ledger; never a value.
    * `browser.handoffs.wipe {sites?}` (device-class): on the primary, deletes
      the cookies of those sites' hand-offs, or of every one, now; on a
      desktop, asks its primary to (`handoff_wipe`) and answers the count the
      primary deleted.

  The agent reaches none of these: they are the owner's, at a terminal on
  `daemon.sock`, and no tool calls them.

  Every refusal is a sentence (`sentences/0` lists the fixed ones for the copy
  gate). Test seams in `opts`: `:engine_role` (a `Role` record), `:home`,
  `:now`, `:devtools`, `:open_headed`, `:display?` (in place of
  `ChromeLauncher.display?/0`), `:link` (in place of
  `Browser.Handoff.Link.impl/0`).
  """

  alias FermixCore.Browser.ChromeLauncher
  alias FermixCore.Browser.Error, as: BrowserError
  alias FermixCore.Browser.Handoff
  alias FermixCore.Browser.Handoff.Cookies
  alias FermixCore.Browser.Handoff.DevTools
  alias FermixCore.Browser.Handoff.Link
  alias FermixCore.Home.Role

  require Logger

  @capability "browser"
  @max_url_bytes 2_048
  @url_sentence "Give the address of the page to sign in on, starting with https:// or http://."
  @profile_sentence "The configured browser profile is not one Fermix runs Chrome in, so there " <>
                      "is no Fermix profile to sign in to or hand off from."
  @not_desktop_sentence "A hand-off starts on a desktop whose home moved to a server. This " <>
                          "engine is the primary."
  @no_sites_sentence "Name at least one site, such as example.com."
  @too_many_sentence "Name at most 64 sites in one hand-off."
  @expiry_sentence "A hand-off lasts at most 30 days."
  @no_cookies_sentence "The Fermix browser profile holds no cookies for these sites. Sign in " <>
                         "to them in Fermix's browser on this computer first."
  @read_sentence "Fermix could not read the browser profile's cookies. See the daemon log."
  @store_sentence "Fermix could not change the browser profile's cookies. See the daemon log."
  @ledger_sentence "The record of hand-offs could not be read or written. See the daemon log."
  @timeout_sentence "The server did not confirm the hand-off in time. Its list of " <>
                      "hand-offs shows whether it arrived."
  @wipe_timeout_sentence "The server did not confirm the wipe in time. Its list of " <>
                           "hand-offs shows what it still holds."
  @owner_sentence "Only the owner can sign in or hand off a browser session: do it " <>
                    "yourself, not through a task Fermix runs."
  @no_display_sentence "This computer has no screen to open a sign-in window on. Sign in on " <>
                         "your desktop's Fermix browser, then hand the session to this server."

  @doc "The capability a refusal of this family names."
  @spec capability() :: String.t()
  def capability, do: @capability

  @doc """
  The sentence `daemon.sock` answers when a process Fermix started (or one it
  cannot place) asks to sign in, hand off or wipe: the owner's decisions.
  """
  @spec owner_only_sentence() :: String.t()
  def owner_only_sentence, do: @owner_sentence

  @doc "Every fixed sentence this family answers, for the copy gate."
  @spec sentences() :: [String.t()]
  def sentences do
    [
      @owner_sentence,
      @no_display_sentence,
      @url_sentence,
      @profile_sentence,
      @not_desktop_sentence,
      @no_sites_sentence,
      @too_many_sentence,
      @expiry_sentence,
      @no_cookies_sentence,
      @read_sentence,
      @store_sentence,
      @ledger_sentence,
      @timeout_sentence,
      @wipe_timeout_sentence,
      site_sentence({:invalid_site, "example.com:443"}),
      site_sentence({:public_suffix, "example.co"}),
      site_sentence({:identity_provider, "accounts.example.com"}),
      signin_sentence(),
      sent_sentence(2, 1, ~U[2026-11-03 09:00:00Z]),
      wipe_sentence(:all, 3),
      wipe_sentence(["news.example.org"], 0),
      list_sentence([])
    ]
  end

  @doc "`browser.signin.open`: opens `url` for the owner to sign in."
  @spec signin_open(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def signin_open(url, opts \\ []) when is_list(opts) do
    open = Keyword.get(opts, :open_headed, &DevTools.open_headed/2)
    display? = Keyword.get(opts, :display?, &ChromeLauncher.display?/0)

    with {:ok, url} <- signin_url(url),
         :ok <- screen(display?.()) do
      case open.(url, opts) do
        :ok -> {:ok, %{"sentence" => signin_sentence()}}
        {:error, reason} -> {:error, {:unavailable, @capability, browser_sentence(reason)}}
      end
    end
  end

  @doc "`browser.handoff.send`: collects and sends one hand-off from this desktop."
  @spec handoff_send(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def handoff_send(params, opts \\ []) when is_map(params) and is_list(opts) do
    now = Keyword.get(opts, :now, &DateTime.utc_now/0).()

    with :ok <- on_a_desktop(opts),
         {:ok, sites} <- sites(params),
         {:ok, expires_at} <- expires_at(params, now),
         {:ok, cookies} <- collect(sites, opts) do
      send_collected(sites, expires_at, cookies, opts)
    end
  end

  @doc "`browser.handoffs.list`: the hand-offs this primary stores."
  @spec handoffs_list(keyword()) :: {:ok, map()} | {:error, term()}
  def handoffs_list(opts \\ []) when is_list(opts) do
    now = Keyword.get(opts, :now, &DateTime.utc_now/0).()

    case Handoff.list(opts) do
      {:ok, entries} ->
        rows = Enum.map(entries, &row(&1, now))
        {:ok, %{"handoffs" => rows, "sentence" => list_sentence(rows)}}

      {:error, reason} ->
        ledger_refusal(reason)
    end
  end

  @doc "`browser.handoffs.wipe`: wipes hand-offs here (the primary) or asks the primary to."
  @spec handoffs_wipe(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def handoffs_wipe(params, opts \\ []) when is_map(params) and is_list(opts) do
    with {:ok, sites} <- wipe_sites(params) do
      case role(opts).role do
        :device -> send_wipe(sites, opts)
        _primary -> wipe_here(sites, opts)
      end
    end
  end

  defp screen(true), do: :ok
  defp screen(false), do: {:error, {:unavailable, @capability, @no_display_sentence}}

  defp signin_url(url) when is_binary(url) and byte_size(url) <= @max_url_bytes do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["https", "http"] and is_binary(host) and host != "" ->
        {:ok, url}

      _invalid ->
        {:error, {:invalid_params, "url", @url_sentence}}
    end
  end

  defp signin_url(_url), do: {:error, {:invalid_params, "url", @url_sentence}}

  defp on_a_desktop(opts) do
    case role(opts).role do
      :device -> :ok
      _other -> {:error, {:unavailable, @capability, @not_desktop_sentence}}
    end
  end

  defp sites(%{"sites" => names} = params) when is_list(names) do
    allow? = Map.get(params, "allow_identity_provider", false) == true

    case Handoff.sites(names, allow?) do
      {:ok, sites} -> {:ok, sites}
      {:error, reason} -> {:error, {:invalid_params, "sites", site_sentence(reason)}}
    end
  end

  defp sites(_params), do: {:error, {:invalid_params, "sites", @no_sites_sentence}}

  defp expires_at(params, now) do
    with {:ok, seconds} <- expiry_seconds(Map.get(params, "expires_s")),
         {:ok, expires_at} <- Handoff.expires_at(seconds, now) do
      {:ok, expires_at}
    else
      {:error, _reason} -> {:error, {:invalid_params, "expires_s", @expiry_sentence}}
    end
  end

  defp expiry_seconds(nil), do: {:ok, nil}
  defp expiry_seconds(seconds) when is_integer(seconds) and seconds > 0, do: {:ok, seconds}
  defp expiry_seconds(_invalid), do: {:error, :invalid_expiry}

  defp collect(sites, opts) do
    case Handoff.collect(sites, opts) do
      {:ok, cookies} ->
        {:ok, cookies}

      {:error, :no_cookies} ->
        {:error, {:unavailable, @capability, @no_cookies_sentence}}

      {:error, reason} ->
        Logger.error("browser hand-off: the cookies were not read: #{inspect(reason)}")
        {:error, {:unavailable, @capability, browser_sentence(reason, @read_sentence)}}
    end
  end

  defp send_collected(sites, expires_at, cookies, opts) do
    started = System.monotonic_time(:millisecond)
    id = "ho-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

    handoff = %{
      handoff_id: id,
      sites: sites,
      expires_at: expires_at,
      count: length(cookies),
      payload: Cookies.encode(cookies)
    }

    result = link(opts).send_handoff(handoff)
    emit_sent(result, length(sites), length(cookies), started)
    sent_result(result, handoff, sites, cookies)
  end

  defp sent_result({:ok, %{cookies: stored, expires_at: expires_at}}, handoff, sites, cookies) do
    {:ok,
     %{
       "handoff_id" => handoff.handoff_id,
       "sites" => Enum.map(sites, &%{"site" => &1, "cookies" => per_site(cookies, &1)}),
       "cookies_sent" => length(cookies),
       "cookies_stored" => stored,
       "expires_at" => iso(expires_at),
       "sentence" => sent_sentence(length(cookies), stored, expires_at)
     }}
  end

  defp sent_result({:error, failure}, _handoff, _sites, _cookies), do: link_refusal(failure)

  defp per_site(cookies, site), do: Enum.count(cookies, &(&1["site"] == site))

  defp emit_sent({:ok, _stored}, sites, cookies, started),
    do: Handoff.Telemetry.emit(:sent, :ok, %{sites: sites, cookies: cookies}, started)

  defp emit_sent({:error, failure}, sites, cookies, started),
    do:
      Handoff.Telemetry.emit(
        :sent,
        {:failed, failure},
        %{sites: sites, cookies: cookies},
        started
      )

  defp wipe_sites(params) do
    case Map.get(params, "sites") do
      nil -> {:ok, :all}
      names when is_list(names) -> parse_wipe_sites(names)
      _invalid -> {:error, {:invalid_params, "sites", @no_sites_sentence}}
    end
  end

  # A wipe names sites the owner handed off, identity providers included, so
  # the flag a hand-off needs is not asked of it.
  defp parse_wipe_sites(names) do
    case Handoff.sites(names, true) do
      {:ok, sites} -> {:ok, sites}
      {:error, reason} -> {:error, {:invalid_params, "sites", site_sentence(reason)}}
    end
  end

  defp send_wipe(sites, opts) do
    wire_sites = if sites == :all, do: nil, else: sites

    case link(opts).send_wipe(wire_sites) do
      {:ok, %{cookies: count}} ->
        {:ok,
         %{"sites" => wire_sites, "cookies" => count, "sentence" => wipe_sentence(sites, count)}}

      {:error, :primary_timeout} ->
        {:error, {:unavailable, @capability, @wipe_timeout_sentence}}

      {:error, failure} ->
        link_refusal(failure)
    end
  end

  defp wipe_here(sites, opts) do
    case Handoff.wipe(sites, opts) do
      {:ok, %{cookies: count}} ->
        {:ok,
         %{
           "sites" => if(sites == :all, do: nil, else: sites),
           "cookies" => count,
           "sentence" => wipe_sentence(sites, count)
         }}

      {:error, {:ledger_unreadable, _reason} = reason} ->
        ledger_refusal(reason)

      {:error, {:file, _path, _reason} = reason} ->
        ledger_refusal(reason)

      {:error, reason} ->
        Logger.error("browser hand-off: the wipe did not complete: #{inspect(reason)}")
        {:error, {:unavailable, @capability, browser_sentence(reason, @store_sentence)}}
    end
  end

  defp row(entry, now) do
    %{
      "handoff_id" => entry.handoff_id,
      "from" => entry.from,
      "sites" => entry.sites,
      "cookies" => length(entry.cookies),
      "stored_at" => iso(entry.stored_at),
      "expires_at" => iso(entry.expires_at),
      "expired" => DateTime.compare(entry.expires_at, now) != :gt
    }
  end

  defp ledger_refusal(reason) do
    Logger.error("browser hand-off: the ledger: #{inspect(reason)}")
    {:error, {:unavailable, @capability, @ledger_sentence}}
  end

  defp link_refusal({:primary_unreachable, sentence}),
    do: {:error, {:primary_unreachable, sentence}}

  defp link_refusal({:primary_refused, sentence}),
    do: {:error, {:unavailable, @capability, sentence}}

  defp link_refusal(:primary_timeout),
    do: {:error, {:unavailable, @capability, @timeout_sentence}}

  # Chrome's own failures keep the launcher's sentence; the rest name the step.
  defp browser_sentence(reason, fallback \\ @read_sentence)
  defp browser_sentence(:profile_not_managed, _fallback), do: @profile_sentence

  defp browser_sentence(%BrowserError{} = error, _fallback),
    do: ChromeLauncher.sentence({:error, error})

  defp browser_sentence(_reason, fallback), do: fallback

  defp site_sentence(:no_sites), do: @no_sites_sentence
  defp site_sentence({:too_many_sites, _count}), do: @too_many_sentence

  defp site_sentence({:invalid_site, name}),
    do:
      "#{name} is not a site. Name a host such as example.com, with no scheme, port, path or " <>
        "wildcard."

  defp site_sentence({:public_suffix, site}),
    do: "#{site} covers every site registered under it. Name the site itself."

  defp site_sentence({:identity_provider, site}),
    do:
      "#{site} signs you in to other sites, so it moves only when you allow identity " <>
        "providers in the hand-off."

  defp signin_sentence,
    do:
      "Chrome is open on the Fermix profile. Sign in there, then hand those sites to " <>
        "the server."

  defp sent_sentence(sent, stored, expires_at),
    do:
      "The server stored #{stored} of the #{sent} cookies, until " <>
        "#{Calendar.strftime(expires_at, "%Y-%m-%d %H:%M UTC")}."

  defp wipe_sentence(:all, count), do: "Every hand-off is wiped: #{count} cookies deleted."

  defp wipe_sentence(sites, count),
    do: "The hand-offs of #{Enum.join(sites, ", ")} are wiped: #{count} cookies deleted."

  defp list_sentence([]), do: "No hand-off is stored here."
  defp list_sentence([_one]), do: "One hand-off is stored here."
  defp list_sentence(rows), do: "#{length(rows)} hand-offs are stored here."

  defp link(opts), do: Keyword.get_lazy(opts, :link, &Link.impl/0)
  defp role(opts), do: Keyword.get_lazy(opts, :engine_role, &Role.recorded/0)
  defp iso(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
