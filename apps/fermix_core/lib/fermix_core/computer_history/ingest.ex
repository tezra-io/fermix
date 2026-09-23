defmodule FermixCore.ComputerHistory.Ingest do
  @moduledoc """
  The one writer of `computer_history_events` (MILESTONE_32 §6.2, §7). Events
  arrive from the capturer as atom-keyed maps; Ingest runs each through the
  fixed pipeline before it touches disk:

      default-deny allowlist  ▸  private gate + URL normalization  ▸  title
        normalization  ▸  secure-role suppression  ▸  secret scrubber  ▸
        injection-scan tagging  ▸  consecutive-repeat collapse  ▸  batched write

  **Default-deny (§14 inv. 11):** consent is **per app**. An event whose bundle id
  is not on the allowlist is dropped **before** any write — asserted by the store
  never containing it, not by a read-time filter. Only the metadata-only kinds of
  the §8.4 taxonomy (`@appless_kinds`) may arrive with no bundle id; any other
  app-less event names no app to check against the allowlist, so it is dropped
  too. There is no per-site filter: allowlisting a browser means "record where I
  go in that browser" (MILESTONE_32.1 §2.1), so every site visited inside it is
  recorded.

  **The private-browsing gate (§2.2, inv. 26) is re-enforced here**, at the write
  boundary, even though the recorder already applies it — the same belt-and-braces
  discipline as inv. 19. `private_state` is reduced to the three-value enum
  (`"private"`, `"not_private"`, `"unknown"`). A `browser.navigated` is admitted
  **only** on `"not_private"` or `"unknown"`: `"private"` is refused, and so is a
  verdict outside the enum or an absent one — downgrading that to `"unknown"` would
  admit a private page on a misspelling. A browser text event without a positive
  `"not_private"` signal keeps its row (and its `char_len`) but loses its `text` and
  is marked `content_withheld`. Text kinds DO take the `"unknown"` downgrade, because
  for them unknown means withhold.

  On top of those two kind-specific gates there is one **kind-independent** rule:
  any event whose `private_state` is `"private"` keeps no site identity at all —
  `text`, `url`, `host`, `page_title`, `window_title` and `field_label` are all
  nil'd, on `focus.changed` and `window.title_changed` as much as on a content kind,
  because every one of those columns names the page and the renderer prints them.
  `char_len` survives, because a count is not content.

  **URLs are stored as scheme + host + path** (§2.4, inv. 27) via `UrlNormalizer`,
  and when a URL is present the `host` column is derived from it (a frame host that
  disagrees with its own URL is a recorder bug, and `host` feeds the sitting's
  `sites` artifact). A URL that does not normalize refuses a `browser.navigated` —
  which is nothing but its address — and only nils the column on every other kind.

  Refusals are counted **by kind** (`:private`, `:state`, `:url`) beside the
  allowlist `dropped` count: they are three different operator problems, and one
  total would hide which one happened.

  The scrubber runs on every free-form column, and the injection scanner tags
  suspect free-form text with a `scan_flag` so a captured "ignore previous
  instructions…" is marked as data, never executed downstream (§13.3).

  **Title noise:** a window title arrives with whatever status glyphs the app
  paints into it — a spinner frame (`⠙ fermix — fermix`) changes the title on
  every animation tick, and one Braille glyph is enough to defeat every
  downstream dedupe, which is how a live spool became 99% spinner frames.
  `normalize_title/1` strips the LEADING run of status glyphs from
  `window_title`/`page_title`, and a `window.title_changed` whose app and
  normalized title repeat the previous kept event of the same type is dropped and
  counted as `collapsed`. Within-batch only: debouncing the source is the
  recorder's job, and a cross-batch cursor here would be a second, drifting
  memory of the last title.

  The live capturer's micro-batching (buffer + flush timer) and its
  write-failure gap policy live with the capturer (§7.1); this module is the
  synchronous transform-and-write those feed, so it is fully testable from a
  fake event source with no capture at all.
  """

  require Logger

  alias FermixCore.ComputerHistory.Config
  alias FermixCore.ComputerHistory.Scrubber
  alias FermixCore.ComputerHistory.UrlNormalizer
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

  # The §8.4 event kinds that are metadata about the machine, not about an app,
  # and so legitimately carry no bundle id. This list is the single source of
  # truth for the app-allowlist exemption: every other kind — the content kinds
  # (`field.value`, `selection.changed`, `browser.navigated`) and the app kinds
  # (`app.*`, `window.*`, `focus.changed`) — must name its app to be checked.
  @appless_kinds ~w(
    observer.gap
    system.sleep
    system.wake
    session.locked
    session.unlocked
    user.switched
  )

  # The status-glyph run a title can be prefixed with: plain spaces, the Braille
  # block every terminal spinner animates through, and the enumerated circle/bullet
  # frames apps use for "unsaved", "loading" or "running". Deliberately NOT the
  # whole `\p{S}`/`\p{Z}` properties: those swallow the leading `~`, `$`, `€`, `±`,
  # `<`, `` ` ``, `©`, `+` and `→` of ordinary titles (`~/projects/fermix — zsh`
  # became `/projects/fermix — zsh`), and a stripper that edits real titles is
  # worse than the noise it removes. Leading only — a glyph inside a title is part
  # of the title.
  @leading_glyphs ~r/^[\p{Zs}\x{2800}-\x{28FF}•●○◐◓◑◒◴◵◶◷⣿]+/u

  # The one event kind whose consecutive repeats are animation frames rather than
  # activity. Every other kind is written as observed.
  @collapsible_kind "window.title_changed"

  @title_columns [:window_title, :page_title]

  # The §2.2 private-window enum. On a TEXT kind any other value normalizes to
  # "unknown": the gate needs a POSITIVE not-private signal, so an unrecognized
  # spelling must never be able to read as `not_private`. A navigation gets no
  # such downgrade — see `admit_state/1`.
  @private_states ~w(private not_private unknown)

  # The states that admit a navigation: the owner consented to this browser, so an
  # address is recorded when the window is known non-private AND when the recorder
  # could not classify it. Nothing else.
  @navigable_states ~w(not_private unknown)

  # Refusal kinds, fixed so a caller can pattern-match the shape and so a new kind
  # has to be named here rather than folded into an existing count.
  @refusal_kinds [:private, :state, :url]

  # The content kinds that carry typed/selected text inside a browser. Written as
  # the whole surface rather than the one kind the recorder emits today: a kind
  # added later joins the gate instead of quietly bypassing it.
  @browser_text_kinds ~w(field.value selection.changed)

  @navigation_kind "browser.navigated"

  # What a row from a private window may NOT carry, on any kind: the address, the
  # host, and every free-form column that names the page or the field.
  @private_identity_columns [:text, :url, :host, :page_title, :window_title, :field_label]

  @type refusals :: %{
          private: non_neg_integer(),
          state: non_neg_integer(),
          url: non_neg_integer()
        }

  @type stats :: %{
          written: non_neg_integer(),
          dropped: non_neg_integer(),
          collapsed: non_neg_integer(),
          refused: refusals()
        }

  @doc """
  Run a batch of raw events through the pipeline and write the survivors.
  Returns `{:ok, %{written, dropped, collapsed, refused}}` or the write error.
  `written` excludes idempotent-duplicate rows; `dropped` is the **allowlist**
  count only; `collapsed` counts repeated title frames dropped inside this batch;
  `refused` breaks the admission refusals out by kind (`:private` — a private
  window, `:state` — a navigation whose private-window verdict this gate does not
  recognize, `:url` — a navigation address that is not a usable http(s) page).
  They stay distinct because they are three different operator problems and one
  total would hide which. `opts`: `:repo`, `:apps` (each defaults to the
  configured value) for hermetic testing.
  """
  @spec ingest([map()], keyword()) :: {:ok, stats()} | {:error, term()}
  def ingest(events, opts \\ []) when is_list(events) do
    repo = Keyword.get(opts, :repo, Repo)

    if capture_paused?(repo, opts) do
      {:ok, %{written: 0, dropped: length(events), collapsed: 0, refused: no_refusals()}}
    else
      write_batch(events, repo, opts)
    end
  end

  defp write_batch(events, repo, opts) do
    apps = Keyword.get_lazy(opts, :apps, &Config.apps/0)

    {allowed, denied} = Enum.split_with(events, &allowed?(&1, apps))
    {admitted, refused} = admit(allowed)
    {processed, collapsed} = admitted |> Enum.map(&process/1) |> collapse_title_frames()

    case Repo.computer_history_insert_events(processed, server: repo) do
      {:ok, written} ->
        {:ok,
         %{
           written: written,
           dropped: length(denied),
           collapsed: collapsed,
           refused: refused
         }}

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

  # An app-scoped event must have its bundle id on the app allowlist.
  defp allowed?(%{bundle_id: bundle}, apps) when is_binary(bundle), do: bundle in apps
  # No bundle id ⇒ only a metadata-only kind passes. A content or app event with
  # no app is malformed: it can never be attributed to an allowlisted app, so it
  # is dropped rather than written on an exemption meant for machine metadata.
  defp allowed?(event, _apps), do: Map.get(event, :type) in @appless_kinds

  # --- private gate + URL normalization (inv. 26, inv. 27) ----------------

  # Admission is the second half of the write boundary: the allowlist answers
  # "may this app be recorded", this answers "is this event something history is
  # allowed to hold". Refusals are counted per kind, never silent.
  defp admit(events) do
    {kept, refused} = Enum.reduce(events, {[], no_refusals()}, &admit_step/2)
    {Enum.reverse(kept), refused}
  end

  defp admit_step(event, {kept, refused}) do
    case admit_event(event) do
      {:ok, admitted} -> {[admitted | kept], refused}
      {:refused, kind} -> {kept, Map.update!(refused, kind, &(&1 + 1))}
    end
  end

  defp no_refusals, do: Map.new(@refusal_kinds, &{&1, 0})

  defp admit_event(event) do
    event = downcase_host(event)

    with {:ok, event} <- admit_state(event),
         {:ok, event} <- admit_url(event) do
      {:ok, event |> gate_browser_text() |> strip_private_identity()}
    end
  end

  # inv. 26 for navigations. A private window's address is the one thing the owner
  # asked not to be recorded, so `"private"` is refused. So is a verdict outside
  # the enum, INCLUDING an absent one: downgrading it to `"unknown"` (which the
  # text kinds do, because for them it means withhold) would admit a private page
  # on a misspelling, so a navigation needs a verdict this gate recognizes.
  defp admit_state(%{type: @navigation_kind} = event) do
    case Map.get(event, :private_state) do
      state when state in @navigable_states -> {:ok, event}
      "private" -> {:refused, :private}
      _unrecognized_or_absent -> {:refused, :state}
    end
  end

  defp admit_state(event), do: {:ok, normalize_private_state(event)}

  defp normalize_private_state(%{private_state: state} = event)
       when is_binary(state) and state in @private_states,
       do: event

  defp normalize_private_state(%{private_state: nil} = event), do: event

  defp normalize_private_state(%{private_state: _unrecognized} = event),
    do: Map.put(event, :private_state, "unknown")

  defp normalize_private_state(event), do: event

  # An empty host is absent, not a host (the same reading `admit_url/1` gives an
  # empty URL) — a blank column must never look like a site the owner visited.
  defp downcase_host(%{host: host} = event) when is_binary(host) and host != "",
    do: Map.put(event, :host, String.downcase(host))

  defp downcase_host(%{host: host} = event) when is_binary(host),
    do: Map.put(event, :host, nil)

  defp downcase_host(event), do: event

  # inv. 27: what is stored is scheme + host + path.
  defp admit_url(%{url: url} = event) when is_binary(url) and url != "",
    do: normalized_url(event, url)

  defp admit_url(%{url: url} = event) when is_binary(url), do: {:ok, Map.put(event, :url, nil)}
  defp admit_url(event), do: {:ok, event}

  # The URL is the evidence for the page, so when one is present its host is
  # stored — `host` feeds the sitting's `sites` artifact, and a frame host that
  # disagrees with its own URL is a recorder bug, not a second opinion.
  defp normalized_url(event, url) do
    case UrlNormalizer.normalize(url) do
      {:ok, %{url: normalized, host: host}} ->
        {:ok, event |> Map.put(:url, normalized) |> Map.put(:host, host)}

      :error ->
        unusable_url(event)
    end
  end

  # A navigation IS its address: without a usable one it is not an observation, so
  # it is refused and counted. Every other kind carries a URL as context, so an
  # unusable one costs the column and keeps the row.
  defp unusable_url(%{type: @navigation_kind}), do: {:refused, :url}
  defp unusable_url(event), do: {:ok, Map.put(event, :url, nil)}

  # inv. 26 for typed/selected text: it needs a POSITIVE "not_private" signal.
  # Without one the row survives as the honest record that something was typed
  # there — with no text, marked withheld, keeping `char_len`.
  defp gate_browser_text(%{type: type} = event) when type in @browser_text_kinds,
    do: apply_text_gate(event, browser_window_state(event))

  defp gate_browser_text(event), do: event

  # `nil` when the event names no browser window at all (a native app's field).
  # EITHER a browser id or a private-window verdict is enough to know the text came
  # from one: a frame carrying a verdict but no browser id is the more hostile
  # shape, not the safer one, and keying on the id alone let it through.
  defp browser_window_state(event) do
    state = Map.get(event, :private_state)

    cond do
      is_binary(Map.get(event, :browser_id)) -> state || "unknown"
      not is_nil(state) -> state
      true -> nil
    end
  end

  defp apply_text_gate(event, nil), do: event
  defp apply_text_gate(event, "not_private"), do: event
  defp apply_text_gate(event, _private_or_unclassified), do: withhold_text(event)

  defp withhold_text(event), do: Map.merge(event, %{text: nil, content_withheld: true})

  # inv. 26, the LAST word on what a private row may carry, and deliberately
  # kind-independent: the navigation gate refuses a private address and the text
  # gate withholds private text, but a window title, a page title and a field label
  # name the page just as surely — and the renderer prints all of them. Scoped to
  # the content kinds, this rule let `focus.changed` and `window.title_changed`
  # smuggle a private page through a door the other two gates had shut. `char_len`
  # survives (a count is not content) and so does the `content_withheld` mark the
  # text gate set, which is what keeps "typed nothing" distinguishable from
  # "not observable".
  defp strip_private_identity(%{private_state: "private"} = event),
    do: Enum.reduce(@private_identity_columns, event, &Map.put(&2, &1, nil))

  defp strip_private_identity(event), do: event

  # --- per-event processing ----------------------------------------------

  defp process(event) do
    event
    |> normalize_titles()
    |> suppress_secure_text()
    |> scrub_free_form()
    |> tag_injection()
  end

  defp normalize_titles(event) do
    Enum.reduce(@title_columns, event, fn column, acc ->
      case Map.get(acc, column) do
        value when is_binary(value) -> Map.put(acc, column, normalize_title(value))
        _absent_or_nil -> acc
      end
    end)
  end

  # A title that is nothing but status glyphs names no document, so it becomes
  # nil rather than a row of decoration the summarizer has to reason about.
  defp normalize_title(value) do
    case value |> String.replace(@leading_glyphs, "") |> String.trim() do
      "" -> nil
      normalized -> normalized
    end
  end

  # --- consecutive-repeat collapse ---------------------------------------

  defp collapse_title_frames(events) do
    {kept, _previous, collapsed} = Enum.reduce(events, {[], nil, 0}, &collapse_step/2)
    {Enum.reverse(kept), collapsed}
  end

  defp collapse_step(event, {kept, previous, collapsed}) do
    if repeated_title?(event, previous),
      do: {kept, previous, collapsed + 1},
      else: {[event | kept], event, collapsed}
  end

  # Compared against the previous KEPT event, and only when both are title
  # changes: an intervening focus change or app switch makes the next identical
  # title a real re-entry, not another frame of the same animation.
  defp repeated_title?(%{type: @collapsible_kind} = event, %{type: @collapsible_kind} = previous),
    do: title_identity(event) == title_identity(previous)

  defp repeated_title?(_event, _previous), do: false

  defp title_identity(event), do: {Map.get(event, :bundle_id), Map.get(event, :window_title)}

  defp suppress_secure_text(%{role: role} = event) when role in @secure_roles,
    do: Map.put(event, :text, nil)

  defp suppress_secure_text(event), do: event

  defp scrub_free_form(event) do
    Enum.reduce(@free_form_columns, event, fn column, acc ->
      case Map.get(acc, column) do
        value when is_binary(value) -> Map.put(acc, column, scrub_column(column, value))
        _absent_or_nil -> acc
      end
    end)
  end

  # The url column is a normalised address (query already stripped), so it is
  # scrubbed of named secrets but NOT run through the opaque-entropy heuristics
  # that would eat a legitimate path (`Scrubber.scrub_url/1`). Every other free-form
  # column is natural language and gets the full scrub.
  defp scrub_column(:url, value), do: Scrubber.scrub_url(value)
  defp scrub_column(_column, value), do: Scrubber.scrub(value)

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
