defmodule FermixCore.Net.Guard do
  @moduledoc """
  Public-web URL guard shared by outbound tools.
  """

  import Bitwise

  @sensitive_headers ~w(authorization cookie set-cookie proxy-authorization x-api-key x-auth-token x-subscription-token)

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
        resolver = Keyword.get(opts, :resolver) || (&default_resolver/1)

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

  defp default_resolver(host) do
    addresses =
      :inet_res.lookup(String.to_charlist(host), :in, :a) ++
        :inet_res.lookup(String.to_charlist(host), :in, :aaaa)

    {:ok, addresses}
  rescue
    error -> {:error, error}
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
    a == 10 or a == 127 or a == 0 or
      (a == 169 and b == 254) or
      (a == 192 and b == 168) or
      (a == 172 and b in 16..31)
  end

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
      (first &&& 0xFFC0) == 0xFE80 -> true
      (first &&& 0xFF00) == 0xFF00 -> true
      true -> false
    end
  end
end
