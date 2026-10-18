defmodule FermixCore.Net.Guard do
  @moduledoc """
  Public-web URL guard shared by outbound tools, and the owner policy an
  address the owner typed is checked under.

  `resolve_and_validate/2` is the public policy: only globally routable peers.
  `owner_peers/2` is for an address the owner typed (an MCP server's URL, M74
  E4). The owner's own machine and network are theirs to name, so loopback,
  private ranges and IP literals pass, and only what no server is reached at is
  refused: the link-local and cloud metadata addresses
  `metadata_or_link_local?/1` answers, written as a literal or among any of a
  name's answers. A name is looked up the way every other program on the
  owner's machine looks it up, through the operating system's resolver, so
  the hosts file, `localhost` and mDNS `.local` names resolve as they do there.
  """

  import Bitwise

  @sensitive_headers ~w(authorization cookie set-cookie proxy-authorization x-api-key x-auth-token x-subscription-token)

  # fd00:ec2::254 — inside ULA space, which is otherwise the operator's own.
  # The Linux system unit denies the metadata endpoints themselves
  # (`Fermix.CLI.Service.Templates`): an endpoint added here is added there too.
  @aws_ipv6_metadata {0xFD00, 0x0EC2, 0, 0, 0, 0, 0, 0x0254}

  # One bound for each address family's system lookup.
  @owner_lookup_ms 10_000

  @type resolver :: (String.t() -> {:ok, [:inet.ip_address()]} | {:error, term()})
  @type opts :: [resolver: resolver()]

  @spec validate(String.t(), opts()) :: :ok | {:error, term()}
  def validate(url, opts \\ []) when is_binary(url) do
    case resolve_and_validate(url, opts) do
      {:ok, _ip} -> :ok
      :ok -> :ok
      {:error, _reason} = err -> err
    end
  end

  @spec validate_redirect(String.t(), String.t(), opts()) :: :ok | {:error, term()}
  def validate_redirect(new_url, original, opts \\ [])
      when is_binary(new_url) and is_binary(original) do
    original
    |> URI.merge(new_url)
    |> URI.to_string()
    |> validate(opts)
  end

  @doc """
  Resolve and validate a URL, returning the validated peer IP for
  pin-on-connect callers.

  For URLs whose host is already an IP literal, returns `:ok` (no IP
  is "validated" beyond the public-IP check already done in `validate/2`).
  For URLs that resolve via DNS, returns `{:ok, ip}` — the first
  resolved IPv4 / IPv6 address that passed the public-IP check.
  Callers should connect to this IP while preserving Host/SNI, which
  closes the DNS-rebinding gap between validation and connect time.

  Audit F-04: prior `Guard.validate/2` resolved DNS once at preflight,
  then Req re-resolved at connect; this entry point hands the validated
  IP to the caller so the connect is pinned to it.
  """
  @spec resolve_and_validate(String.t(), opts()) ::
          :ok | {:ok, :inet.ip_address()} | {:error, term()}
  def resolve_and_validate(url, opts \\ []) when is_binary(url) do
    with :ok <- validate_text(url),
         %URI{} = uri <- URI.parse(url),
         :ok <- validate_scheme(uri.scheme),
         {:ok, host} <- fetch_host(uri),
         :ok <- validate_host(host),
         {:ok, validated_ip_or_skip} <- resolve_validated_ip(host, opts) do
      case validated_ip_or_skip do
        :ip_literal -> :ok
        ip -> {:ok, ip}
      end
    end
  end

  @doc """
  Every peer an address the owner typed may be dialled at, in order: an IP
  literal itself, or each answer the operating system's resolver gives for a
  name (IPv6 first, then IPv4). Any answer that is link-local or a metadata
  address refuses the whole set. `:resolver` replaces the system lookup.
  """
  @spec owner_peers(String.t(), opts()) :: {:ok, [:inet.ip_address(), ...]} | {:error, term()}
  def owner_peers(url, opts \\ []) when is_binary(url) do
    with :ok <- validate_text(url),
         %URI{} = uri <- URI.parse(url),
         :ok <- validate_scheme(uri.scheme),
         {:ok, host} <- fetch_host(uri) do
      case parse_ip(host) do
        {:ok, ip} -> owner_literal(ip)
        {:error, :einval} -> owner_lookup(host, Keyword.get(opts, :resolver) || (&os_resolve/1))
      end
    end
  end

  @doc """
  Whether `host` names this machine: a `localhost` name (RFC 6761) or a
  loopback literal (127.0.0.0/8, `::1`, or an IPv4-mapped loopback address).
  """
  @spec loopback_host?(String.t()) :: boolean()
  def loopback_host?(host) when is_binary(host) do
    host = String.downcase(host)

    case parse_ip(host) do
      {:ok, ip} -> loopback_ip?(ip)
      {:error, :einval} -> host == "localhost" or String.ends_with?(host, ".localhost")
    end
  end

  defp loopback_ip?({127, _b, _c, _d}), do: true
  defp loopback_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback_ip?({0, 0, 0, 0, 0, 65_535, high, _low}), do: high >>> 8 == 127
  defp loopback_ip?(_ip), do: false

  defp owner_lookup(host, resolver) do
    case resolver.(host) do
      {:ok, []} -> {:error, {:dns_resolution_failed, :nxdomain}}
      {:ok, ips} -> ips |> Enum.uniq() |> owner_answers()
      {:error, reason} -> {:error, {:dns_resolution_failed, reason}}
    end
  end

  defp owner_literal(ip) do
    if metadata_or_link_local?(ip),
      do: {:error, {:blocked_host, :link_local_address}},
      else: {:ok, [ip]}
  end

  defp owner_answers(ips) do
    case Enum.find(ips, &metadata_or_link_local?/1) do
      nil -> {:ok, ips}
      ip -> {:error, {:resolved_to_link_local_address, ip}}
    end
  end

  # The native lookup: the hosts file, mDNS and the system's DNS, as every
  # other program on this machine sees them. One family answering is a name
  # that resolves; neither is the IPv4 lookup's failure.
  defp os_resolve(host) do
    name = String.to_charlist(host)

    case {:inet.getaddrs(name, :inet6, @owner_lookup_ms),
          :inet.getaddrs(name, :inet, @owner_lookup_ms)} do
      {{:error, _v6}, {:error, reason}} -> {:error, reason}
      {v6, v4} -> {:ok, family_answers(v6) ++ family_answers(v4)}
    end
  end

  defp family_answers({:ok, ips}), do: ips
  defp family_answers({:error, _absent}), do: []

  @doc """
  The A and AAAA answers for `host`: the lookup `validate/2` makes when it is
  given no `:resolver`, for a caller that judges the answers itself. `timeout`
  bounds each of the two queries.
  """
  @spec resolve(String.t(), timeout()) :: {:ok, [:inet.ip_address()]} | {:error, term()}
  def resolve(host, timeout \\ :infinity) when is_binary(host) do
    name = String.to_charlist(host)

    addresses =
      :inet_res.lookup(name, :in, :a, [], timeout) ++
        :inet_res.lookup(name, :in, :aaaa, [], timeout)

    {:ok, addresses}
  rescue
    # A host that is not UTF-8, or a name with a label `:inet_dns` cannot encode
    # (empty, or longer than 63 bytes): a lookup that failed, for the caller to
    # judge like any other.
    error in [UnicodeConversionError, FunctionClauseError] -> {:error, error}
  end

  @doc """
  Whether `ip` is an address no web server is reached at: link-local
  (169.254.0.0/16 and fe80::/10 — the home of the 169.254.169.254 instance
  metadata endpoint), "this host" (0.0.0.0/8 and `::`), or AWS's IPv6 metadata
  endpoint fd00:ec2::254. An IPv4-mapped address is judged by the IPv4 address
  it carries.

  A narrower question than the public-web check `validate/2` makes, and every
  address it answers `true` for is non-global there too: a caller that lets the
  operator's own network through (RFC 1918, ULA, CGNAT) still refuses these.
  """
  @spec metadata_or_link_local?(:inet.ip_address()) :: boolean()
  def metadata_or_link_local?({a, b, _c, _d}), do: this_host_ipv4?(a) or link_local_ipv4?(a, b)

  def metadata_or_link_local?({0, 0, 0, 0, 0, 65_535, high, low}),
    do: metadata_or_link_local?({high >>> 8, high &&& 255, low >>> 8, low &&& 255})

  def metadata_or_link_local?(@aws_ipv6_metadata), do: true
  def metadata_or_link_local?({0, 0, 0, 0, 0, 0, 0, 0}), do: true

  def metadata_or_link_local?({first, _b, _c, _d, _e, _f, _g, _h}),
    do: link_local_ipv6?(first)

  @spec redact_headers([{String.t(), String.t()}]) :: [{String.t(), String.t()}]
  def redact_headers(headers) when is_list(headers) do
    Enum.map(headers, fn {key, value} ->
      if String.downcase(to_string(key)) in @sensitive_headers do
        {key, "***REDACTED***"}
      else
        {key, value}
      end
    end)
  end

  @spec redact_headers_for_trace(term()) :: [%{name: String.t(), value: String.t()}]
  def redact_headers_for_trace(headers) do
    headers
    |> normalize_headers()
    |> redact_headers()
    |> Enum.map(fn {key, value} -> %{name: key, value: value} end)
  end

  defp validate_text(""), do: {:error, :empty_url}

  defp validate_text(url) do
    if Regex.match?(~r/\s/, url), do: {:error, :url_has_whitespace}, else: :ok
  end

  defp normalize_headers(headers) when is_map(headers) do
    Enum.map(headers, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp normalize_headers(headers) when is_list(headers) do
    Enum.map(headers, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp normalize_headers(_headers), do: []

  defp validate_scheme(scheme) when scheme in ["http", "https"], do: :ok
  defp validate_scheme(_scheme), do: {:error, :scheme_not_http_or_https}

  defp fetch_host(%URI{host: host}) when is_binary(host) and host != "" do
    {:ok, String.downcase(host)}
  end

  defp fetch_host(_uri), do: {:error, {:blocked_host, :empty_host}}

  defp validate_host("localhost"), do: {:error, {:blocked_host, :localhost}}

  defp validate_host(host) do
    cond do
      String.ends_with?(host, ".localhost") -> {:error, {:blocked_host, :localhost}}
      String.ends_with?(host, ".local") -> {:error, {:blocked_host, :local_domain}}
      String.ends_with?(host, ".internal") -> {:error, {:blocked_host, :internal_domain}}
      true -> validate_ip_literal(host)
    end
  end

  defp validate_ip_literal(host) do
    case parse_ip(host) do
      {:ok, ip} -> validate_public_ip(ip, {:blocked_host, :private_address})
      {:error, :einval} -> :ok
    end
  end

  defp resolve_validated_ip(host, opts) do
    case parse_ip(host) do
      {:ok, _ip} ->
        {:ok, :ip_literal}

      {:error, :einval} ->
        resolver = Keyword.get(opts, :resolver) || (&resolve/1)

        case resolver.(host) do
          {:ok, []} -> {:error, {:dns_resolution_failed, :nxdomain}}
          {:ok, ips} -> validate_all_answers(ips)
          {:error, reason} -> {:error, {:dns_resolution_failed, reason}}
        end
    end
  end

  # Every A and AAAA answer must be globally routable: a mixed set means the
  # name can steer a later resolution at a non-global peer, so picking the
  # convenient public answer would hand an attacker the rebind they wanted.
  defp validate_all_answers([first | _rest] = ips) do
    case Enum.find(ips, &private_ip?/1) do
      nil -> {:ok, first}
      ip -> {:error, {:resolved_to_private_address, ip}}
    end
  end

  defp parse_ip(host), do: :inet.parse_address(String.to_charlist(host))

  defp validate_public_ip(ip, reason) do
    if private_ip?(ip), do: {:error, reason}, else: :ok
  end

  defp private_ip?({a, b, c, d}), do: ipv4_non_global?(a, b, c, d)

  defp private_ip?({_a, _b, _c, _d, _e, _f, _g, _h} = ip), do: ipv6_non_global?(ip)

  defp ipv4_non_global?(a, b, c, _d) do
    private_ipv4_prefix?(a, b) or reserved_ipv4_prefix?(a) or shared_ipv4_prefix?(a, b) or
      documentation_ipv4_prefix?(a, b, c) or benchmarking_ipv4_prefix?(a, b) or
      relay_ipv4_prefix?(a, b, c)
  end

  defp private_ipv4_prefix?(a, b) do
    a == 10 or a == 127 or this_host_ipv4?(a) or link_local_ipv4?(a, b) or
      (a == 192 and b == 168) or
      (a == 172 and b in 16..31)
  end

  # 0.0.0.0/8, "this host".
  defp this_host_ipv4?(a), do: a == 0

  # 169.254.0.0/16.
  defp link_local_ipv4?(a, b), do: a == 169 and b == 254

  defp reserved_ipv4_prefix?(a), do: a in 224..239 or a >= 240

  # RFC 6598 carrier-grade NAT: 100.64.0.0/10 addresses a provider's inside
  # network, not a global peer.
  defp shared_ipv4_prefix?(a, b), do: a == 100 and b in 64..127

  # RFC 5737 documentation ranges are routed nowhere, so a resolver handing
  # one back is misconfigured or steering us at a local listener.
  defp documentation_ipv4_prefix?(a, b, c) do
    (a == 192 and b == 0 and c == 2) or
      (a == 198 and b == 51 and c == 100) or
      (a == 203 and b == 0 and c == 113)
  end

  # RFC 2544 benchmarking: 198.18.0.0/15.
  defp benchmarking_ipv4_prefix?(a, b), do: a == 198 and b in 18..19

  # RFC 7526 6to4 relay anycast: 192.88.99.0/24, deprecated and unroutable.
  defp relay_ipv4_prefix?(a, b, c), do: a == 192 and b == 88 and c == 99

  # ::/96 — the unspecified address, loopback, and the deprecated
  # IPv4-compatible form, none of which name a global peer.
  defp ipv6_non_global?({0, 0, 0, 0, 0, 0, _g, _h}), do: true

  # ::ffff:0:0/96 — IPv4-mapped, so the embedded v4 address decides.
  defp ipv6_non_global?({0, 0, 0, 0, 0, 65_535, high, low}) do
    ipv4_non_global?(high >>> 8, high &&& 255, low >>> 8, low &&& 255)
  end

  # Transition ranges — NAT64 64:ff9b::/96, 6to4 2002::/16, Teredo
  # 2001::/32 — carry a v4 destination we would not otherwise screen.
  defp ipv6_non_global?({0x64, 0xFF9B, 0, 0, 0, 0, _g, _h}), do: true
  defp ipv6_non_global?({0x2002, _b, _c, _d, _e, _f, _g, _h}), do: true
  defp ipv6_non_global?({0x2001, 0, _c, _d, _e, _f, _g, _h}), do: true

  defp ipv6_non_global?({first, _b, _c, _d, _e, _f, _g, _h}) do
    cond do
      (first &&& 0xFE00) == 0xFC00 -> true
      link_local_ipv6?(first) -> true
      (first &&& 0xFF00) == 0xFF00 -> true
      true -> false
    end
  end

  # fe80::/10.
  defp link_local_ipv6?(first), do: (first &&& 0xFFC0) == 0xFE80
end
