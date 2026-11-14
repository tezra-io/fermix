# Web search, page fetch and place search

## Which tool

| Need | Tool |
|---|---|
| A fact with no known URL: anything current or changed since training, or a plain lookup (a confident memory of a mutable fact is still a reason to search) | `web_search` |
| One known, server-rendered URL | `web_fetch` (readable text, or the JSON verbatim when the endpoint serves JSON) |
| JavaScript, dynamic or interactive pages; data only a driven page shows | `browser` (see the `browser` reference) |
| Businesses, landmarks, addresses, hours, ratings, distance | `place_search` |

Never shell-scrape a JavaScript site.

## `web_search` backends

The default backend is keyless DuckDuckGo. Others (Brave, Exa, Tavily, Firecrawl and more) take a key: Mac Settings > Search (**Web search** and its key), or `[fermix_core.tools.web_search]`. When a configured non-DuckDuckGo backend hard-fails (auth, credits or HTTP 402, transport, rate limit), `web_search` degrades once to DuckDuckGo, loudly: a warning log plus `degraded`, `primary_backend` and `fallback_reason` in the trace. Empty results and bad queries do not degrade.

## `place_search`

- Three backends, one result shape, one per home, never chosen per call. In order: `[fermix_core.tools.place_search] backend` when it is set (`"apple_maps"`, `"computer"` or `"brave"`; Settings > Search, **Place search**); else **Apple Maps** through the `fermix-maps` helper the Fermix Mac app's engine carries, with no key; else **Apple Maps on a Mac of the home** (`computer`), where a server has a linked computer whose latest offers list Apple Maps (`places`) on, which every Mac running the Fermix app offers unless it is switched off at that Mac (its This computer settings, **Apple Maps**); else **Brave** Place Search. A build without the helper (Homebrew, Linux) offers `computer` and Brave and refuses `apple_maps`. There is no fallback between them: a failed search returns its own tag. Doctor's place search row says which backend is in force, why, and whether it is ready.
- On `computer`, each search is one request to the connected Mac seen most recently that offers Apple Maps, run there with that Mac's own Apple Maps, bounded at 15 s and never past what a trip's lookups have left. Each way it can fail is its own tag, naming the Mac, and none is ever sent to Brave: `computer_away` (no such Mac online, answered at once, nothing waits for a Mac to wake: say the owner's Mac is not online and search again once it is), `computer_off` (Apple Maps switched off at that Mac: only someone there can switch it on), `computer_refused` (that Mac refused it otherwise, in its own words), `computer_busy` (try again in a moment), `computer_timed_out` (it did not answer in time), and Apple Maps' own tags as a search here gives them. The Fermix app carries Apple Maps however it was installed, the Homebrew cask included; only the standalone Homebrew formula on a Mac, and a Linux computer, do not offer it ("Looking places up in Apple Maps needs the Fermix app on a Mac.").
- Brave is advertised only when a Brave Search API key is configured. It shares that key with `web_search`'s Brave backend (Brave need not be the active web backend); each web and place call is metered separately. Apple Maps is advertised when its helper is present, and Apple Maps on a Mac while a computer of the home offers it, online or not.
- On Brave, a home's place searches (`place_search` and a trip's lookups) go to Brave one at a time, each sent when Brave's last answer allows it: when a window resets within 2 s, the next search waits for it. A search Brave refuses as rate limited is sent once more after that wait, and a second refusal is `rate_limited`. When a window is spent for longer, such as the month's quota, nothing more is sent until it resets, and the search answers `rate_limited` saying how long; do not search again before then. A search whose turn does not come in time is `deadline`: the place search is busy, so try again shortly. A Brave Search API key whose plan does not include place search is `plan_excludes_place_search`: searching again cannot help, so tell the owner to add place search to that key's plan, and take a place's link only from the owner or a web search, never a made-up one.
- What a place carries depends on the backend: an Apple Maps place, here or from a Mac of the home, has its name, address, phone, kind, coordinates, its own site when HTTPS and Apple's page for it (a `maps.apple.com` link, the one to keep in the answer), but no rating, price or hours; a Brave place adds those where Brave has them. A distance comes only with explicit coordinates. `country` and `language` are Brave's options only.
- Place intent (a business, landmark or address) routes here, not to `web_search` (general research) or `browser` (a live map, a booking, a price check).
- An area the user names goes in `location` (or `latitude`/`longitude`), never left inside `query`.
- "Near me" with no named area: use an area the user already shared (this conversation first, then a coarse remembered one: neighborhood, city or zip) as an ordinary `location`; the tool reads no memory or config itself, and the answer names the area searched. With no area known, ask which one before calling: an anchorless "near me" query refuses with `location_required` from every context.
- Results are transient: nothing is cached or stored beyond the final answer in chat history. Keep each place's returned URL in the answer.
