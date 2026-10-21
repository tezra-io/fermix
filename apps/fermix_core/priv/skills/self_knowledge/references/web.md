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

- Two backends, one result shape. The Fermix Mac app searches **Apple Maps** through the `fermix-maps` helper its engine carries, with no key; the Homebrew and Linux builds search **Brave** Place Search. `[fermix_core.tools.place_search] backend = "apple_maps"` or `"brave"` (Mac Settings > Search, **Place search**) picks one on purpose where the build carries both; the Homebrew and Linux builds offer Brave alone and refuse `apple_maps`. There is no fallback between them: a failed search returns its own tag. Doctor's place search row says which backend is in force, why, and whether it is ready.
- Brave is advertised only when a Brave Search API key is configured. It shares that key with `web_search`'s Brave backend (Brave need not be the active web backend); each web and place call is metered separately. Apple Maps is advertised when its helper is present.
- What a place carries depends on the backend: an Apple Maps place has its name, address, phone, kind, coordinates, its own site when HTTPS and Apple's page for it (a `maps.apple.com` link, the one to keep in the answer), but no rating, price or hours; a Brave place adds those where Brave has them. A distance comes only with explicit coordinates. `country` and `language` are Brave's options only.
- Place intent (a business, landmark or address) routes here, not to `web_search` (general research) or `browser` (a live map, a booking, a price check).
- An area the user names goes in `location` (or `latitude`/`longitude`), never left inside `query`.
- "Near me" with no named area: use an area the user already shared (this conversation first, then a coarse remembered one: neighborhood, city or zip) as an ordinary `location`; the tool reads no memory or config itself, and the answer names the area searched. With no area known, ask which one before calling: an anchorless "near me" query refuses with `location_required` from every context.
- Results are transient: nothing is cached or stored beyond the final answer in chat history. Keep each place's returned URL in the answer.
