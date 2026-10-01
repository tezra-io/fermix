defmodule FermixCore.Net.Egress do
  @moduledoc """
  How an outbound HTTP connection leaves this machine: straight to its
  destination, or through the HTTP proxy `[fermix_core.network]` names.

  One resolver, so no connector decides for itself. `route/2` is the only place
  the rule lives:

    * no `proxy` configured: every destination is direct;
    * `localhost` and an address literal on this machine or its own networks
      (loopback, RFC 1918, link-local, unique-local, carrier-grade NAT) are
      direct by construction: a proxy is not the path to them, and the sidecars,
      a local Ollama and Chrome's DevTools port all live there. Nothing else is:
      a reserved or transition range that can reach the internet goes to the
      proxy like any public address, and so does any other name, `.localhost`
      names included, because nothing guarantees where a name resolves;
    * a `proxy_bypass` entry (an exact host, or a suffix written with a leading
      dot) is direct;
    * everything else goes to the proxy.

  There is no third outcome. A proxied request whose proxy is down fails; it is
  never retried direct (Rule #12), because on a host that must leave through a
  proxy a direct dial is exactly what the operator ruled out.

  ## Where the setting comes from

  `config.toml` owns it. Fermix does not read `HTTP_PROXY`, `HTTPS_PROXY` or
  `NO_PROXY`: a shell export never reaches a launchd or systemd service, so an
  environment-driven proxy would hold in the terminal and not in the daemon.

      [fermix_core.network]
      proxy = "http://proxy.corp.example:3128"
      proxy_bypass = ["ollama.internal", ".corp.example"]

  Only an unauthenticated `http://host:port` proxy is accepted, the host a name
  or an IPv4 address. A URL carrying credentials, a path, another scheme or no
  port is refused at load, and the refusal never prints the value.

  The section is read once. `activate/0` records the egress under `:egress`
  where the outbound pools are started, and `active/0` returns that record for
  the life of the process (recording it on first use in a process that started
  no pools), so a setting saved while the daemon runs cannot leave half the
  connectors on the new proxy and the pools on the old one. The restart banner
  is what says a saved change is waiting.

  ## What it covers

  Every `Req` request: the shared pool through `FermixCore.Net.HttpClient`
  (`attach/3` with `:pooled`) and each site that owns its own connect options
  (`:direct`). Routing happens at the adapter, once per hop, so a redirect or a
  retry is routed for the URL it is actually about to dial.

  An HTTPS destination is reached with `CONNECT`; TLS runs end to end inside the
  tunnel and the caller's own TLS options verify the origin, so the proxy never
  sees plaintext and cannot stand in for the peer. A request pinned to a
  validated address (`web_fetch`, link previews) tunnels to that address: the
  proxy is handed the IP the guard approved, never a name to resolve again.

  Plain HTTP has no tunnel: the proxy reads the whole request, `Host` header
  included. A pinned plain-HTTP request therefore cannot keep its pin through a
  proxy (the proxy either rewrites `Host` to the address or resolves the name
  itself, behind the guard), so that one hop is refused rather than sent.

  A transport that cannot tunnel (the WebSocket clients, the pinned remote MCP
  connector, the APNs socket) asks `ensure_direct/2` and refuses to start on a
  proxied route rather than dial around the proxy.

  ## When the proxy fails

  A failed proxy hop comes back as a `%Req.TransportError{}` whose reason is one
  of four atoms, so every consumer that already matches transport reasons keeps
  working and the error's own `message/1` can still print it:

    * `:proxy_unreachable` — it could not be reached, did not answer in time, or
      answered 5xx. The one transient kind: worth another try on the same route.
    * `:proxy_auth_required` — it answered 407. Fermix sends no proxy sign-in.
    * `:proxy_refused` — it refused the tunnel, or the tunnel could not be set up.
    * `:proxy_needs_https` — the pinned plain-HTTP hop this module will not send.

  No other provider is tried for any of them: every route shares the proxy.
  """

  require Logger

  import Bitwise

  defstruct proxy: nil, bypass: []

  @type proxy :: %{host: String.t(), port: :inet.port_number()}
  @type t :: %__MODULE__{proxy: proxy() | nil, bypass: [String.t()]}
  @type route :: :direct | {:proxy, proxy()}
  @type mode :: :pooled | :direct
  @type proxy_failure ::
          :proxy_unreachable | :proxy_auth_required | :proxy_refused | :proxy_needs_https

  @proxy_failures [:proxy_unreachable, :proxy_auth_required, :proxy_refused, :proxy_needs_https]

  @config_keys ~w(proxy proxy_bypass)
  @direct_pool FermixCore.Finch
  @proxied_pool FermixCore.Finch.Proxied
  @step :fermix_egress

  # The connect timeout Finch gives a pool that sets none (its
  # `@default_connect_timeout`), so "unset" means the same bound proxied as direct.
  @default_connect_budget_ms 5_000

  # A proxied hop opens exactly one TCP connection, to the proxy, so a
  # connect-level failure on such a hop is the proxy's. Timeouts and closes are
  # left alone: they also happen inside the tunnel, where the origin owns them,
  # and nothing at this level can tell the two apart.
  @proxy_hop_reasons [:econnrefused, :nxdomain, :ehostunreach, :enetunreach, :ehostdown]

  # No brackets: Mint dials the proxy over IPv4, so an IPv6 literal would be
  # accepted here and then fail every request.
  @proxy_shape ~r|\Ahttp://[^/?#@\s\[\]]+:\d{1,5}/?\z|
  @host_name ~r/\A[a-z0-9_]([a-z0-9_-]*[a-z0-9_])?(\.[a-z0-9_]([a-z0-9_-]*[a-z0-9_])?)*\z/

  @proxy_error "[fermix_core.network] proxy must be an http://host:port URL, the host a " <>
                 "name or an IPv4 address, with no credentials, path or query " <>
                 "(the value is not shown)"

  @doc """
  Validates the `[fermix_core.network]` section and returns it as the keyword
  the application environment holds.

  Accepts the TOML map and the keyword it produced, so it is idempotent: what a
  save writes back is what the next load reads. Raises `ArgumentError` naming
  the section and key on anything it cannot use, including an unknown key, so a
  misspelt `proxy` stops the daemon instead of leaving it dialing direct.
  """
  @spec normalize(map() | keyword() | nil) :: keyword()
  def normalize(nil), do: []

  def normalize(config) when is_map(config) or is_list(config) do
    entries = section_entries(config)
    :ok = refuse_unknown_keys(entries)

    proxy = normalize_proxy(Map.get(entries, "proxy"))
    # Kept even with no proxy, where it has no effect: an operator who comments
    # `proxy` out for an afternoon must not find the daemon refusing to start.
    bypass = normalize_bypass(Map.get(entries, "proxy_bypass"))

    [] |> put_present(:proxy, proxy) |> put_present(:proxy_bypass, bypass)
  end

  @doc "The egress a `[fermix_core.network]` section describes."
  @spec new(map() | keyword() | nil) :: t()
  def new(config) do
    normalized = normalize(config)

    %__MODULE__{
      proxy: parse_proxy(Keyword.get(normalized, :proxy)),
      bypass: Keyword.get(normalized, :proxy_bypass, [])
    }
  end

  @doc """
  Reads the section and records it as the egress this process runs on. Called
  where the outbound pools are started, before anything dials.
  """
  @spec activate() :: t()
  def activate do
    egress = new(Application.get_env(:fermix_core, :network, []))
    Application.put_env(:fermix_core, :egress, egress)
    egress
  end

  @doc """
  The egress this process runs on. One source: the record `activate/0` made. A
  process that started no pools (a tree-less CLI verb) makes that record on its
  first use, so every later connector in it reads the same answer.
  """
  @spec active() :: t()
  def active do
    case Application.get_env(:fermix_core, :egress) do
      %__MODULE__{} = egress -> egress
      nil -> activate()
    end
  end

  @doc "The shared pool direct destinations use."
  @spec direct_pool() :: module()
  def direct_pool, do: @direct_pool

  @doc "The pool proxied destinations use. It exists only when a proxy is configured."
  @spec proxied_pool() :: module()
  def proxied_pool, do: @proxied_pool

  @doc "The proxy as the operator wrote it, or `nil` when there is none."
  @spec describe(t()) :: String.t() | nil
  def describe(%__MODULE__{proxy: nil}), do: nil
  def describe(%__MODULE__{proxy: proxy}), do: "http://#{proxy.host}:#{proxy.port}"

  @doc "Whether `reason` is one of the four reasons a failed proxy hop carries."
  @spec proxy_failure?(term()) :: boolean()
  def proxy_failure?(reason), do: reason in @proxy_failures

  @doc """
  One clause for an operator, from the reason a failed proxy hop carries. Never
  the proxy address: the settings name that.
  """
  @spec describe_failure(proxy_failure()) :: String.t()
  def describe_failure(:proxy_unreachable),
    do: "the proxy could not be reached or did not answer in time"

  def describe_failure(:proxy_auth_required),
    do: "the proxy answered HTTP 407 and wants a sign-in, which Fermix does not send"

  def describe_failure(:proxy_refused), do: "the proxy refused to open the connection"

  def describe_failure(:proxy_needs_https),
    do: "a plain http:// page cannot be fetched through the proxy; its https:// address can"

  @doc "Which way a connection to `destination` leaves."
  @spec route(t(), String.t() | URI.t()) :: route()
  def route(%__MODULE__{proxy: nil}, _destination), do: :direct
  def route(%__MODULE__{} = egress, %URI{host: host}), do: route_host(egress, host)
  def route(%__MODULE__{} = egress, url) when is_binary(url), do: route(egress, URI.parse(url))

  @doc """
  `:ok` when `url` is dialed directly, `{:error, :proxy_unsupported_transport}`
  when it would have to go through the proxy. For a transport that cannot
  tunnel: it refuses the proxied route instead of dialing around the proxy.
  """
  @spec ensure_direct(String.t(), t()) :: :ok | {:error, :proxy_unsupported_transport}
  def ensure_direct(url, %__MODULE__{} = egress \\ active()) when is_binary(url) do
    case route(egress, url) do
      :direct -> :ok
      {:proxy, _proxy} -> {:error, :proxy_unsupported_transport}
    end
  end

  @doc """
  The host and port a reachability probe for `host:port` should dial: the proxy
  when that is where the request will go, the destination otherwise.
  """
  @spec readiness_target(t(), String.t(), :inet.port_number()) ::
          {String.t(), :inet.port_number()}
  def readiness_target(%__MODULE__{} = egress, host, port)
      when is_binary(host) and is_integer(port) do
    case route_host(egress, host) do
      :direct -> {host, port}
      {:proxy, proxy} -> {proxy.host, proxy.port}
    end
  end

  @doc """
  The `Req` `:connect_options` for a request to `url`, built from the options
  the caller already had.

  A direct route returns `base` untouched. A proxied HTTPS route makes three
  timed steps where a direct one makes one, so the caller's connect budget is
  shared between them: a fifth for the TCP connect to the proxy (a neighbour on
  the network), two fifths for the `CONNECT` exchange (the proxy resolves and
  dials the origin inside it) and two fifths for the TLS handshake with the
  origin. Going through a proxy therefore never lets a connect outlive the
  bound its caller chose. Everything else in `base`, the origin's TLS options
  above all, is kept.
  """
  @spec connect_options(t(), String.t() | URI.t(), keyword()) :: keyword()
  def connect_options(%__MODULE__{} = egress, url, base) when is_list(base) do
    case route(egress, url) do
      :direct -> base
      {:proxy, proxy} -> proxied_options(base, proxy, scheme(url))
    end
  end

  @doc """
  The pool table for proxied destinations: `pools` with the proxy added to every
  entry, each entry's idle caps, counts and connect budget kept. `nil` when no
  proxy is configured, so no second pool is started.
  """
  @spec proxied_pools(t(), map()) :: map() | nil
  def proxied_pools(%__MODULE__{proxy: nil}, _pools), do: nil

  def proxied_pools(%__MODULE__{proxy: proxy}, pools) when is_map(pools) do
    Map.new(pools, fn {origin, options} ->
      conn_opts = options |> Keyword.get(:conn_opts, []) |> tunnel_options(proxy)
      {origin, Keyword.put(options, :conn_opts, conn_opts)}
    end)
  end

  @doc """
  Routes `request` at its adapter, once per hop.

  `:pooled` names the shared pool the hop uses (`direct_pool/0` or
  `proxied_pool/0`); `:direct` rewrites the request's own `:connect_options`.
  A redirect or a retry re-enters the adapter and is routed again for the URL
  it is about to dial, so a hop into a bypassed host drops the proxy and a hop
  out of one picks it up.

  On a proxied hop a failure of the proxy itself comes back as a
  `%Req.TransportError{}` carrying one of the `t:proxy_failure/0` reasons, so
  callers can tell "the proxy refused or could not be reached" from a failure of
  the origin.
  """
  @spec attach(Req.Request.t(), mode(), t()) :: Req.Request.t()
  def attach(%Req.Request{} = request, mode, %__MODULE__{} = egress \\ active())
      when mode in [:pooled, :direct] do
    if Keyword.has_key?(request.request_steps, @step) do
      request
    else
      Req.Request.append_request_steps(request, [{@step, &route_at_adapter(&1, mode, egress)}])
    end
  end

  # Runs last among the request steps, so the adapter it wraps is the final one
  # (a test's `plug:` included) and the connect options are the caller's own.
  defp route_at_adapter(request, mode, egress) do
    inner = request.adapter
    base = Map.get(request.options, :connect_options)

    %{request | adapter: &run_hop(&1, inner, mode, egress, base)}
  end

  defp run_hop(hop, inner, mode, egress, base) do
    route = route(egress, hop.url)

    if unpinnable?(hop, route) do
      {hop, %Req.TransportError{reason: :proxy_needs_https}}
    else
      hop
      |> put_route(mode, route, egress, base)
      |> run_adapter(inner)
      |> name_proxy_failure(route)
    end
  end

  # A pinned request names its host in `Host` while the URL carries the address
  # the guard validated. Over plain HTTP a proxy reads that header: it either
  # overwrites it with the address (the wrong virtual host) or resolves the name
  # itself, behind the guard. Neither is the request that was validated.
  defp unpinnable?(%Req.Request{url: %URI{scheme: "http", host: host}} = hop, {:proxy, _proxy})
       when is_binary(host) do
    hop
    |> Req.Request.get_header("host")
    |> Enum.any?(&(String.downcase(&1) != String.downcase(host)))
  end

  defp unpinnable?(_hop, _route), do: false

  defp put_route(hop, :pooled, :direct, _egress, _base), do: put_option(hop, :finch, @direct_pool)

  defp put_route(hop, :pooled, {:proxy, _proxy}, _egress, _base),
    do: put_option(hop, :finch, @proxied_pool)

  defp put_route(hop, :direct, :direct, _egress, nil),
    do: %{hop | options: Map.delete(hop.options, :connect_options)}

  defp put_route(hop, :direct, :direct, _egress, base),
    do: put_option(hop, :connect_options, base)

  defp put_route(hop, :direct, {:proxy, _proxy}, egress, base),
    do: put_option(hop, :connect_options, connect_options(egress, hop.url, base || []))

  defp put_option(hop, key, value), do: %{hop | options: Map.put(hop.options, key, value)}

  defp run_adapter(hop, inner) when is_function(inner, 1), do: inner.(hop)
  defp run_adapter(hop, {module, function, args}), do: apply(module, function, [hop | args])

  # Req normalizes Mint's HTTP/1 and HTTP/2 errors and passes the tunnel's own
  # through untouched, so a refused `CONNECT` would otherwise reach callers as
  # a raw `%Mint.HTTPError{}` none of them classify.
  defp name_proxy_failure(
         {request, %Mint.HTTPError{module: Mint.TunnelProxy, reason: {:proxy, detail}}},
         {:proxy, _proxy}
       ) do
    proxy_failed(request, tunnel_failure(detail), detail)
  end

  defp name_proxy_failure({request, %Req.TransportError{reason: reason}}, {:proxy, _proxy})
       when reason in @proxy_hop_reasons,
       do: proxy_failed(request, :proxy_unreachable, reason)

  defp name_proxy_failure(result, _route), do: result

  defp tunnel_failure(:tunnel_timeout), do: :proxy_unreachable
  defp tunnel_failure({:unexpected_status, 407}), do: :proxy_auth_required
  # A gateway error from the proxy is its report that it could not reach the
  # origin just now, not a decision about this request.
  defp tunnel_failure({:unexpected_status, status}) when status in 500..599,
    do: :proxy_unreachable

  defp tunnel_failure(_refusal_or_setup_failure), do: :proxy_refused

  # The detail (a status, a socket reason) is what an operator needs and the
  # reason atom cannot carry. Host only: a URL path can hold a token.
  defp proxy_failed(request, failure, detail) do
    Logger.warning(
      "Outbound proxy failed for #{request.url.host} (#{failure}): #{inspect(detail)}"
    )

    {request, %Req.TransportError{reason: failure}}
  end

  defp proxied_options(base, proxy, "http"),
    do: Keyword.put(base, :proxy, {:http, proxy.host, proxy.port, []})

  defp proxied_options(base, proxy, _tunnelled_scheme), do: tunnel_options(base, proxy)

  defp tunnel_options(base, proxy) do
    transport = Keyword.get(base, :transport_opts, [])

    budget =
      Keyword.get(transport, :timeout) || Keyword.get(base, :timeout) ||
        @default_connect_budget_ms

    {origin_tls, proxy_opts} = phase_budgets(budget)

    base
    |> Keyword.delete(:timeout)
    |> Keyword.put(:transport_opts, Keyword.put(transport, :timeout, origin_tls))
    |> Keyword.put(:proxy, {:http, proxy.host, proxy.port, proxy_opts})
  end

  # {timeout for the origin's TLS handshake, the proxy's own connect options}.
  defp phase_budgets(budget_ms) when is_integer(budget_ms) and budget_ms > 0 do
    fifth = max(div(budget_ms, 5), 1)
    {fifth * 2, [transport_opts: [timeout: fifth], tunnel_timeout: fifth * 2]}
  end

  # A caller that asked for no connect bound keeps none on the two socket
  # steps; the CONNECT exchange keeps Mint's own finite wait.
  defp phase_budgets(:infinity), do: {:infinity, [transport_opts: [timeout: :infinity]]}

  defp scheme(%URI{scheme: scheme}), do: scheme
  defp scheme(url) when is_binary(url), do: URI.parse(url).scheme

  defp route_host(%__MODULE__{proxy: nil}, _host), do: :direct

  defp route_host(%__MODULE__{proxy: proxy, bypass: bypass}, host)
       when is_binary(host) and host != "" do
    host = host |> String.downcase() |> String.trim_trailing(".")
    if local?(host) or bypassed?(bypass, host), do: :direct, else: {:proxy, proxy}
  end

  # No host, so nothing to dial and nothing to hand a proxy.
  defp route_host(%__MODULE__{}, _host), do: :direct

  defp local?("localhost"), do: true

  defp local?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> local_address?(ip)
      {:error, :einval} -> false
    end
  end

  # Deliberately narrower than `Net.Guard`'s "not a public web target": that
  # list also holds ranges that route to the internet (NAT64, 6to4, Teredo),
  # and those must not slip past the proxy.
  defp local_address?({0, _b, _c, _d}), do: true
  defp local_address?({10, _b, _c, _d}), do: true
  defp local_address?({127, _b, _c, _d}), do: true
  defp local_address?({169, 254, _c, _d}), do: true
  defp local_address?({192, 168, _c, _d}), do: true
  defp local_address?({172, b, _c, _d}) when b in 16..31, do: true
  defp local_address?({100, b, _c, _d}) when b in 64..127, do: true
  defp local_address?({_a, _b, _c, _d}), do: false

  # `::` and `::1`.
  defp local_address?({0, 0, 0, 0, 0, 0, 0, last}) when last in [0, 1], do: true

  # IPv4-mapped: the embedded address decides.
  defp local_address?({0, 0, 0, 0, 0, 0xFFFF, high, low}),
    do: local_address?({high >>> 8, high &&& 255, low >>> 8, low &&& 255})

  # fc00::/7 unique-local and fe80::/10 link-local.
  defp local_address?({first, _b, _c, _d, _e, _f, _g, _h}),
    do: (first &&& 0xFE00) == 0xFC00 or (first &&& 0xFFC0) == 0xFE80

  defp bypassed?(entries, host) do
    Enum.any?(entries, fn
      "." <> _name = suffix -> String.ends_with?(host, suffix)
      exact -> host == exact
    end)
  end

  defp section_entries(config) when is_map(config),
    do: Map.new(config, fn {key, value} -> {to_string(key), value} end)

  defp section_entries(config) when is_list(config) do
    if Keyword.keyword?(config) do
      Map.new(config, fn {key, value} -> {Atom.to_string(key), value} end)
    else
      raise ArgumentError, "[fermix_core.network] must be a table of settings"
    end
  end

  defp refuse_unknown_keys(entries) do
    case entries |> Map.keys() |> Enum.reject(&(&1 in @config_keys)) |> Enum.sort() do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "config.toml [fermix_core.network] has unknown key(s): " <>
                "#{Enum.join(unknown, ", ")}. Allowed keys: #{Enum.join(@config_keys, ", ")}."
    end
  end

  defp normalize_proxy(nil), do: nil

  defp normalize_proxy(value) when is_binary(value) do
    with true <- Regex.match?(@proxy_shape, value),
         {:ok, %URI{scheme: "http", userinfo: nil, host: host, port: port}} <- URI.new(value),
         true <- is_binary(host) and host != "" and port in 1..65_535 do
      "http://#{String.downcase(host)}:#{port}"
    else
      _unusable -> raise ArgumentError, @proxy_error
    end
  end

  defp normalize_proxy(_other), do: raise(ArgumentError, @proxy_error)

  defp parse_proxy(nil), do: nil

  defp parse_proxy(proxy) when is_binary(proxy) do
    %URI{host: host, port: port} = URI.parse(proxy)
    %{host: host, port: port}
  end

  defp normalize_bypass(nil), do: []

  defp normalize_bypass(entries) when is_list(entries) do
    entries
    |> Enum.with_index(1)
    |> Enum.map(fn {entry, position} -> normalize_bypass_entry(entry, position) end)
  end

  defp normalize_bypass(_other) do
    raise ArgumentError, "[fermix_core.network] proxy_bypass must be a list of hosts"
  end

  # Named by position, never echoed: a URL pasted here by mistake can carry a
  # credential just as a proxy URL can.
  defp normalize_bypass_entry(entry, position) when is_binary(entry) do
    normalized = entry |> String.trim() |> String.downcase()

    if bypass_entry?(normalized) do
      normalized
    else
      raise ArgumentError,
            "[fermix_core.network] proxy_bypass entry #{position} must be a host name, " <>
              "an IP address, or a domain suffix written with a leading dot " <>
              "(the value is not shown)"
    end
  end

  defp normalize_bypass_entry(_entry, position) do
    raise ArgumentError,
          "[fermix_core.network] proxy_bypass entry #{position} must be a string"
  end

  defp bypass_entry?("." <> suffix), do: host_name?(suffix) and not ip_literal?(suffix)
  defp bypass_entry?(entry), do: host_name?(entry) or ip_literal?(entry)

  defp host_name?(value), do: Regex.match?(@host_name, value)

  defp ip_literal?(value), do: match?({:ok, _ip}, :inet.parse_address(String.to_charlist(value)))

  defp put_present(keyword, _key, nil), do: keyword
  defp put_present(keyword, _key, []), do: keyword
  defp put_present(keyword, key, value), do: keyword ++ [{key, value}]
end
