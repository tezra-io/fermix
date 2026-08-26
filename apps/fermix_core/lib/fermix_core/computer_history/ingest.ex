defmodule FermixCore.ComputerHistory.Ingest do
  @moduledoc """
  The one writer of `computer_history_events` (MILESTONE_32 §6.2, §7). Events
  arrive from the capturer as atom-keyed maps; Ingest runs each through the
  fixed pipeline before it touches disk:

      default-deny allowlist  ▸  secure-role suppression  ▸  secret scrubber
        ▸  injection-scan tagging  ▸  batched write

  **Default-deny (§14 inv. 11):** an event in a non-allowlisted app, or a
  browser content/navigation event on a non-allowlisted site, is dropped
  **before** any write — asserted by the store never containing it, not by a
  read-time filter. System/session/gap events (no bundle id) are not app
  content and pass.

  The scrubber runs on every free-form column, and the injection scanner tags
  suspect free-form text with a `scan_flag` so a captured "ignore previous
  instructions…" is marked as data, never executed downstream (§13.3).

  The live capturer's micro-batching (buffer + flush timer) and its
  write-failure gap policy live with the capturer (§7.1); this module is the
  synchronous transform-and-write those feed, so it is fully testable from a
  fake event source with no capture at all.
  """

  require Logger

  alias FermixCore.ComputerHistory.Config
  alias FermixCore.ComputerHistory.Scrubber
  alias FermixCore.Memory.Repo
  alias FermixCore.Prompt.InjectionScan

  # Every free-form string column is scrubbed — titles and labels carry secrets
  # too, so scrubbing only text/url would leave them exposed (§13.1).
  @free_form_columns [:text, :url, :window_title, :page_title, :field_label]

  # Human-readable columns scanned for prompt-injection amplifiers (§13.3). URLs
  # and hosts are not natural-language and are excluded.
  @scan_columns [:window_title, :page_title, :field_label, :text]

  # AX secure roles whose text is suppressed regardless — defense in depth
  # behind the capturer's own secure-role suppression (§13.1).
  @secure_roles ["AXSecureTextField"]

  @type stats :: %{written: non_neg_integer(), dropped: non_neg_integer()}

  @doc """
  Run a batch of raw events through the pipeline and write the survivors.
  Returns `{:ok, %{written, dropped}}` (written excludes idempotent-duplicate
  rows) or the write error. `opts`: `:repo`, `:apps`, `:sites` (each defaults
  to the configured value) for hermetic testing.
  """
  @spec ingest([map()], keyword()) :: {:ok, stats()} | {:error, term()}
  def ingest(events, opts \\ []) when is_list(events) do
    repo = Keyword.get(opts, :repo, Repo)

    if capture_paused?(repo, opts) do
      {:ok, %{written: 0, dropped: length(events)}}
    else
      write_batch(events, repo, opts)
    end
  end

  defp write_batch(events, repo, opts) do
    apps = Keyword.get_lazy(opts, :apps, &Config.apps/0)
    sites = Keyword.get_lazy(opts, :sites, &Config.sites/0)

    {kept, dropped} = Enum.split_with(events, &allowed?(&1, apps, sites))
    processed = Enum.map(kept, &process/1)

    case Repo.computer_history_insert_events(processed, server: repo) do
      {:ok, written} ->
        {:ok, %{written: written, dropped: length(dropped)}}

      {:error, reason} = error ->
        Logger.error("computer_history ingest write failed: #{inspect(reason)}")
        error
    end
  end

  # --- pause horizon (§7.3) ------------------------------------------------

  # `/history pause` is enforced HERE, at the single writer: an event arriving
  # while `now < pause_until` never reaches the spool, and the horizon passing
  # resumes capture with no timer to arm (each batch re-reads the persisted
  # state, so the pause also survives a mid-pause daemon restart). An
  # unparseable horizon fails CLOSED — this is a privacy control, so a corrupt
  # value keeps capture off, error-logged, with the raw value visible in
  # `/history status` for repair.
  defp capture_paused?(repo, opts) do
    case pause_horizon(repo) do
      nil -> false
      :unparseable -> true
      {:until, until} -> before_horizon?(Keyword.get(opts, :now), until)
    end
  end

  defp before_horizon?(nil, until), do: DateTime.compare(DateTime.utc_now(), until) == :lt
  defp before_horizon?(%DateTime{} = now, until), do: DateTime.compare(now, until) == :lt

  defp pause_horizon(repo) do
    case Repo.computer_history_ensure_state(server: repo) do
      {:ok, %{pause_until: until}} when is_binary(until) ->
        parse_horizon(until)

      # No horizon set, or a state-read error: not paused. A failing store must
      # not silently pause capture — the insert below stays the loud path.
      _none_or_error ->
        nil
    end
  end

  defp parse_horizon(until) do
    case DateTime.from_iso8601(until) do
      {:ok, horizon, _offset} ->
        {:until, horizon}

      {:error, reason} ->
        Logger.error(
          "computer_history pause_until unparseable (#{inspect(reason)}): " <>
            "#{inspect(until)} — capture stays paused until it is cleared"
        )

        :unparseable
    end
  end

  # --- default-deny allowlist (§14 inv. 11) ------------------------------

  defp allowed?(event, apps, sites), do: app_allowed?(event, apps) and site_allowed?(event, sites)

  # An app-scoped event must have its bundle id on the app allowlist.
  defp app_allowed?(%{bundle_id: bundle}, apps) when is_binary(bundle), do: bundle in apps
  # No bundle id ⇒ a system/session/gap event, not app content ⇒ pass.
  defp app_allowed?(_event, _apps), do: true

  # A browser content/navigation event carrying a host must have that host on
  # the site allowlist.
  defp site_allowed?(%{host: host}, sites) when is_binary(host), do: host_allowed?(host, sites)
  defp site_allowed?(_event, _sites), do: true

  defp host_allowed?(host, sites), do: Enum.any?(sites, &host_matches?(host, &1))

  # `*.example.com` matches the domain and any subdomain; a bare entry is exact.
  defp host_matches?(host, "*." <> domain),
    do: host == domain or String.ends_with?(host, "." <> domain)

  defp host_matches?(host, entry), do: host == entry

  # --- per-event processing ----------------------------------------------

  defp process(event) do
    event
    |> suppress_secure_text()
    |> scrub_free_form()
    |> tag_injection()
  end

  defp suppress_secure_text(%{role: role} = event) when role in @secure_roles,
    do: Map.put(event, :text, nil)

  defp suppress_secure_text(event), do: event

  defp scrub_free_form(event) do
    Enum.reduce(@free_form_columns, event, fn column, acc ->
      case Map.get(acc, column) do
        value when is_binary(value) -> Map.put(acc, column, Scrubber.scrub(value))
        _absent_or_nil -> acc
      end
    end)
  end

  defp tag_injection(event) do
    matches = @scan_columns |> Enum.flat_map(&scan_column(event, &1)) |> Enum.uniq()

    case matches do
      [] -> event
      names -> Map.put(event, :scan_flag, Enum.join(names, ","))
    end
  end

  defp scan_column(event, column) do
    case Map.get(event, column) do
      value when is_binary(value) ->
        case InjectionScan.scan(value) do
          {:ok, _content} -> []
          {:suspect, _content, names} -> names
        end

      _absent_or_nil ->
        []
    end
  end
end
