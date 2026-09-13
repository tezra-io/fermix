defmodule FermixCore.Plugins.Http.Template do
  @moduledoc """
  Interpolates a declarative tool's `request` template against normalized args
  and builds the concrete HTTP request (§5.3) — the firewall that keeps the
  `http` rail code-free but request-target-safe.

  Rules enforced here:

    * `{placeholder}` substitutes a normalized arg into url path / query value /
      body leaf. An absent optional (no default) omits its query key or body
      leaf. URL path placeholders must always resolve (validated upstream).
    * **SSRF guard:** the URL scheme + host are static literals — `https` only,
      and the built URL's scheme/host must equal the template's, so no
      placeholder can redirect the request target.
    * Headers are static (no placeholders — header-injection surface). The
      `Authorization` header is injected by the runtime, never from the template.

  ## The request target: `url` or `regional_urls`

  A `request` names its target in exactly one of two ways, and declaring both or
  neither is an install-time error (`:regional_urls_and_url` / `:missing_url`):

    * `url` — one complete `https` URL template.
    * `regional_urls` — a non-empty map of region label (`[a-z]{2,8}`) to one
      complete `https` URL template, for a provider whose account lives in one
      of several fixed regional hosts (the Tesla Fleet API). Every listed URL
      passes the same static checks as a `url`, and placeholders are collected
      from all of them.

  A regional request is not callable as it stands: `resolve_region/2` replaces
  the map with the single `url` recorded for the account's region, and `build/3`
  refuses a request that still carries the map (`:region_unresolved`). The region
  is read from the plugin's own stored grant, never from a model argument, and
  there is no default region — inventing a host is the fallback this module
  exists to prevent.
  """

  @placeholder ~r/\{([a-zA-Z_][a-zA-Z0-9_]*)\}/

  # A region label is an opaque key into the manifest's own signed map, not a
  # host fragment: it never reaches a URL, so the shape is kept deliberately
  # narrow (`na`, `eu`, `cn`).
  @region_label ~r/^[a-z]{2,8}$/

  @type request :: %{
          method: atom(),
          url: String.t(),
          query: [{String.t(), String.t()}],
          headers: [{String.t(), String.t()}],
          body: map() | nil,
          success: [integer()]
        }

  @doc """
  Static install-time validation of a `request` template against the tool's
  declared parameter names (§5.3): exactly one request target (`url` or
  `regional_urls`), `https` only, no placeholder in any URL host (SSRF), no
  placeholder in any header (injection), and every `{placeholder}` in
  url/regional_urls/query/body must name a declared parameter. Returns `:ok` or
  `{:error, reason}` — run before a fetched plugin is activated, so a bad
  template fails at install rather than at first call.
  """
  @spec static_validate(map(), [String.t()]) :: :ok | {:error, term()}
  def static_validate(template, declared_params)
      when is_map(template) and is_list(declared_params) do
    with {:ok, urls} <- target_urls(template),
         :ok <- static_urls(urls),
         :ok <- headers_static(Map.get(template, "headers", %{})),
         :ok <- placeholders_declared(template, MapSet.new(declared_params)) do
      :ok
    end
  end

  @doc """
  Whether a `request` selects its host per region (`regional_urls`) instead of
  naming one static `url`.

  Keyed on the same condition `resolve_region/2` matches on, so the predicate and
  the resolver can never disagree about what is regional: a `regional_urls` that
  is not a map is refused at install, and one that somehow reached here is left
  for `build/3` to refuse as `:region_unresolved` rather than crashing the call.
  """
  @spec regional?(map()) :: boolean()
  def regional?(request) when is_map(request),
    do: is_map(Map.get(request, "regional_urls"))

  @doc """
  Replace a regional request's `regional_urls` map with the single `url`
  recorded for `region`, yielding a request `build/3` can interpolate.

  `region` comes from the plugin's own stored grant. A `nil` region is
  `:region_unknown` and a region the manifest has no endpoint for is
  `{:region_not_supported, region, supported}` — neither falls back to another
  host.
  """
  @spec resolve_region(map(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def resolve_region(%{"regional_urls" => urls} = request, region)
      when is_map(urls) and is_binary(region) do
    case Map.fetch(urls, region) do
      {:ok, url} -> {:ok, request |> Map.delete("regional_urls") |> Map.put("url", url)}
      :error -> {:error, {:region_not_supported, region, Enum.sort(Map.keys(urls))}}
    end
  end

  def resolve_region(%{"regional_urls" => urls}, nil) when is_map(urls),
    do: {:error, :region_unknown}

  # `url` and `regional_urls` are the two spellings of one request target, so
  # exactly one must be present: both is ambiguous, neither leaves nothing to
  # call. Regional entries are returned in region order so the first refusal is
  # the same one on every machine.
  defp target_urls(%{"url" => _url, "regional_urls" => _urls}),
    do: {:error, :regional_urls_and_url}

  defp target_urls(%{"regional_urls" => urls}) when is_map(urls) and map_size(urls) > 0 do
    case Enum.find(Map.keys(urls), &(not region_label?(&1))) do
      nil -> {:ok, urls |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))}
      label -> {:error, {:invalid_region_label, label}}
    end
  end

  defp target_urls(%{"regional_urls" => urls}), do: {:error, {:invalid_regional_urls, urls}}
  defp target_urls(%{"url" => url}), do: {:ok, [url]}
  defp target_urls(_template), do: {:error, :missing_url}

  defp region_label?(label) when is_binary(label), do: Regex.match?(@region_label, label)
  defp region_label?(_label), do: false

  defp static_urls(urls) do
    Enum.reduce_while(urls, :ok, fn url, :ok ->
      case static_url(url) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp static_url(url) do
    with :ok <- require_https(url), do: static_host(url)
  end

  # Parse with URI so this check sees the same host the runtime request will
  # hit — a naive string split reads `user@evil.com` as host `user`. Userinfo
  # is rejected outright; the authority is scanned whole because URI.parse
  # silently drops an invalid `{port}` while `.authority` retains the raw text.
  defp static_host(url) do
    uri = URI.parse(url)

    cond do
      uri.userinfo != nil -> {:error, {:userinfo_in_url, url}}
      uri.host in [nil, ""] -> {:error, {:invalid_url_host, url}}
      String.contains?(uri.authority || "", "{") -> {:error, {:placeholder_in_host, url}}
      true -> :ok
    end
  end

  defp headers_static(headers) when is_map(headers) do
    case Enum.find(headers, fn {_k, v} -> Regex.match?(@placeholder, to_string(v)) end) do
      nil -> :ok
      {key, _} -> {:error, {:placeholder_in_header, key}}
    end
  end

  defp placeholders_declared(template, declared) do
    template
    |> template_placeholders()
    |> Enum.find(&(not MapSet.member?(declared, &1)))
    |> case do
      nil -> :ok
      undeclared -> {:error, {:undeclared_placeholder, undeclared}}
    end
  end

  defp template_placeholders(template) do
    [
      Map.get(template, "url", ""),
      Map.get(template, "regional_urls", %{}),
      Map.get(template, "query", %{}),
      Map.get(template, "body", %{})
    ]
    |> Enum.flat_map(&collect_placeholders/1)
    |> Enum.uniq()
  end

  defp collect_placeholders(value) when is_binary(value),
    do: Regex.scan(@placeholder, value) |> Enum.map(fn [_, name] -> name end)

  defp collect_placeholders(value) when is_map(value),
    do: value |> Map.values() |> Enum.flat_map(&collect_placeholders/1)

  defp collect_placeholders(value) when is_list(value),
    do: Enum.flat_map(value, &collect_placeholders/1)

  defp collect_placeholders(_value), do: []

  @doc """
  Build the concrete request from a `request` template map (string keys) and
  `params` (normalized + defaulted). `auth_header` is `{name, value} | nil`,
  injected by the runtime. Returns `{:ok, request}` or `{:error, reason}`.
  """
  @spec build(map(), map(), {String.t(), String.t()} | nil) :: {:ok, request()} | {:error, term()}
  def build(template, params, auth_header) when is_map(template) and is_map(params) do
    with {:ok, method} <- method(template),
         {:ok, url} <- build_url(template, params),
         {:ok, query} <- build_query(Map.get(template, "query", %{}), params),
         {:ok, headers} <- build_headers(Map.get(template, "headers", %{}), auth_header) do
      {:ok,
       %{
         method: method,
         url: url,
         query: query,
         headers: headers,
         body: build_body(Map.get(template, "body"), params),
         success: Map.get(template, "success", [200])
       }}
    end
  end

  defp method(template) do
    case template |> Map.get("method", "GET") |> String.upcase() do
      m when m in ~w(GET POST PUT PATCH DELETE) ->
        {:ok, m |> String.downcase() |> String.to_atom()}

      other ->
        {:error, {:invalid_method, other}}
    end
  end

  # A regional request's region is resolved before it reaches the builder
  # (`resolve_region/2`); one that still carries the map has no target, and
  # inventing one is the fallback this module refuses.
  defp build_url(%{"regional_urls" => _urls}, _params), do: {:error, :region_unresolved}

  # Interpolate path placeholders, then assert the result's scheme+host still
  # equal the template's literals (SSRF guard).
  defp build_url(template, params) do
    raw = Map.get(template, "url", "")

    with :ok <- require_https(raw),
         {:ok, interpolated} <- interpolate_url(raw, params),
         :ok <- same_origin(raw, interpolated) do
      {:ok, interpolated}
    end
  end

  defp require_https(url) do
    if String.starts_with?(url, "https://"), do: :ok, else: {:error, {:non_https_url, url}}
  end

  defp interpolate_url(url, params) do
    Regex.replace(@placeholder, url, fn _, key ->
      case Map.fetch(params, key) do
        {:ok, value} -> URI.encode_www_form(to_string(value))
        :error -> "\x00MISSING\x00"
      end
    end)
    |> case do
      result ->
        if String.contains?(result, "\x00MISSING\x00"),
          do: {:error, :url_missing_param},
          else: {:ok, result}
    end
  end

  defp same_origin(template_url, built_url) do
    t = URI.parse(template_url)
    b = URI.parse(built_url)

    if {t.scheme, t.host, t.port} == {b.scheme, b.host, b.port} and t.scheme == "https" do
      :ok
    else
      {:error, {:url_origin_changed, template_url, built_url}}
    end
  end

  defp build_query(query_template, params) when is_map(query_template) do
    pairs =
      Enum.flat_map(query_template, fn {key, value_template} ->
        case interpolate_scalar(value_template, params) do
          {:ok, value} -> [{key, value}]
          :omit -> []
        end
      end)

    {:ok, pairs}
  end

  # Headers must be static — a placeholder in a header value is a build error.
  defp build_headers(header_template, auth_header) when is_map(header_template) do
    case Enum.find(header_template, fn {_k, v} -> Regex.match?(@placeholder, to_string(v)) end) do
      nil ->
        {:ok,
         with_auth(Enum.map(header_template, fn {k, v} -> {k, to_string(v)} end), auth_header)}

      {key, _} ->
        {:error, {:placeholder_in_header, key}}
    end
  end

  defp with_auth(headers, nil), do: headers
  defp with_auth(headers, {name, value}), do: [{name, value} | headers]

  # Body leaves interpolate JSON-typed (an array param stays an array); an
  # absent optional leaf is omitted, recursively — a nested object or list whose
  # leaves all omit is itself omitted (matching the old `drop_blank` behavior).
  defp build_body(nil, _params), do: nil

  defp build_body(body_template, params) when is_map(body_template) do
    case interpolate_typed(body_template, params) do
      {:ok, map} -> map
      :omit -> %{}
    end
  end

  # A scalar query value: "{x}" -> the param stringified; literal -> itself;
  # absent param -> :omit.
  defp interpolate_scalar(template, params) when is_binary(template) do
    case full_placeholder(template) do
      {:ok, key} -> fetch_or_omit(params, key, &to_string/1)
      :no -> {:ok, substitute(template, params)}
    end
  end

  defp interpolate_scalar(template, _params), do: {:ok, to_string(template)}

  # A body leaf: a bare "{x}" yields the param's JSON-native value (array stays
  # array); a string with embedded placeholders is substituted as a string.
  # Nested objects/lists recurse; an emptied nested structure omits.
  defp interpolate_typed(template, params) when is_binary(template) do
    case full_placeholder(template) do
      {:ok, key} -> fetch_or_omit(params, key, & &1)
      :no -> {:ok, substitute(template, params)}
    end
  end

  defp interpolate_typed(template, params) when is_map(template) do
    template
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      case interpolate_typed(value, params) do
        {:ok, shaped} -> Map.put(acc, key, shaped)
        :omit -> acc
      end
    end)
    |> omit_if_emptied(template)
  end

  defp interpolate_typed(template, params) when is_list(template) do
    template
    |> Enum.flat_map(fn value ->
      case interpolate_typed(value, params) do
        {:ok, shaped} -> [shaped]
        :omit -> []
      end
    end)
    |> omit_if_emptied(template)
  end

  defp interpolate_typed(template, _params), do: {:ok, template}

  # An interpolated structure that emptied out (all leaves omitted) is itself
  # omitted — but a template that was already empty stays empty.
  defp omit_if_emptied(result, original) when result in [%{}, []] and original not in [%{}, []],
    do: :omit

  defp omit_if_emptied(result, _original), do: {:ok, result}

  defp fetch_or_omit(params, key, transform) do
    case Map.fetch(params, key) do
      {:ok, value} -> {:ok, transform.(value)}
      :error -> :omit
    end
  end

  # "{x}" exactly (whole string is one placeholder) -> {:ok, "x"}.
  defp full_placeholder(string) do
    case Regex.run(~r/^\{([a-zA-Z_][a-zA-Z0-9_]*)\}$/, string) do
      [_, key] -> {:ok, key}
      nil -> :no
    end
  end

  # Substitute placeholders inside a larger string; absent params become "".
  defp substitute(string, params) do
    Regex.replace(@placeholder, string, fn _, key ->
      params |> Map.get(key, "") |> to_string()
    end)
  end
end
