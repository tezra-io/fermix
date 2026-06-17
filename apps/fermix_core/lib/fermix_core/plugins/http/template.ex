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
  """

  @placeholder ~r/\{([a-zA-Z_][a-zA-Z0-9_]*)\}/

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
  declared parameter names (§5.3): `https` only, no placeholder in the URL host
  (SSRF), no placeholder in any header (injection), and every `{placeholder}`
  in url/query/body must name a declared parameter. Returns `:ok` or
  `{:error, reason}` — run before a fetched plugin is activated, so a bad
  template fails at install rather than at first call.
  """
  @spec static_validate(map(), [String.t()]) :: :ok | {:error, term()}
  def static_validate(template, declared_params)
      when is_map(template) and is_list(declared_params) do
    url = Map.get(template, "url", "")

    with :ok <- require_https(url),
         :ok <- static_host(url),
         :ok <- headers_static(Map.get(template, "headers", %{})),
         :ok <- placeholders_declared(template, MapSet.new(declared_params)) do
      :ok
    end
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
