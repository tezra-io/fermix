defmodule FermixCore.Browser.Policy do
  @moduledoc false

  alias FermixCore.Browser.Config
  alias FermixCore.Browser.Error

  @unsafe_schemes ~w(file ftp data javascript)

  # Suffix blocks, deliberately DNS-free. `.internal` alone kills
  # metadata.google.internal — the highest-value target on the list — without
  # making URL validation depend on a resolver, which would make this suite
  # host-dependent and turn a DNS-less runner red. An operator who genuinely
  # needs one of these names lists it in `allowed_hosts`, which is matched first.
  @internal_suffixes ~w(.internal .local .localhost)

  @spec validate_url(String.t(), Config.t()) :: {:ok, URI.t()} | {:error, Error.t()}
  def validate_url("about:blank", %Config{}), do: {:ok, URI.parse("about:blank")}

  def validate_url(url, %Config{} = config) when is_binary(url) do
    uri = URI.parse(url)

    with :ok <- validate_scheme(uri),
         :ok <- validate_host(uri, config) do
      {:ok, uri}
    end
  rescue
    _error -> blocked(url, "Invalid URL")
  end

  def validate_url(_url, _config), do: blocked("", "url must be a string")

  defp validate_scheme(%URI{scheme: scheme}) when scheme in ["http", "https"], do: :ok
  defp validate_scheme(%URI{scheme: scheme}) when scheme in @unsafe_schemes, do: blocked(scheme)

  defp validate_scheme(%URI{scheme: nil}),
    do: blocked("", "URL must include http or https scheme")

  defp validate_scheme(%URI{scheme: scheme}),
    do: blocked(scheme, "Unsupported URL scheme: #{scheme}")

  defp validate_host(%URI{host: host}, _config) when host in [nil, ""] do
    blocked("", "URL must include a host")
  end

  defp validate_host(%URI{host: host}, %Config{} = config) do
    case normalize_host(host) do
      "" -> blocked(host, "URL must include a host")
      normalized -> classify_host(normalized, config)
    end
  end

  # One canonical spelling, produced once, before anything classifies the host.
  # A trailing dot is the DNS root anchor: `metadata.google.internal.` and
  # `169.254.169.254.` name exactly the hosts their undotted spellings name, and
  # Chrome reaches both — the WHATWG parser drops the empty final label. Left in
  # place it defeated every control here at once: `"x.internal."` does not end
  # with `".internal"`, and `:inet.parse_address/1` rejects the trailing dot
  # outright, so each private literal fell through as an ordinary public name.
  # `allowed_hosts` is normalized against the same function — both sides of a
  # membership test must be spelled the same way.
  defp normalize_host(host) when is_binary(host) do
    host
    |> String.downcase()
    |> String.trim_trailing(".")
  end

  defp classify_host(host, %Config{} = config) when is_binary(host) do
    cond do
      host in Enum.map(config.allowed_hosts, &normalize_host/1) -> :ok
      host == "localhost" -> :ok
      true -> classify_literal_or_name(host, config)
    end
  end

  # An address literal is answered by the address rules and a name by the name
  # rules, never the other way round. Parsing first is what keeps the two
  # loopbacks symmetric: `::1` carries no dot, so under a name-first ordering
  # `internal_hostname?/1` refused it as a single-label name before the loopback
  # clause could speak, and an operator who set their own `allowed_hosts` lost
  # IPv6 loopback while keeping `127.0.0.1`.
  defp classify_literal_or_name(host, %Config{} = config) do
    case parse_ip(host) do
      {:ok, ip} -> validate_ip(host, fold_embedded_ipv4(ip), config)
      :error -> validate_name(host)
    end
  end

  defp validate_name(host) do
    if internal_hostname?(host),
      do: blocked(host, "Blocked internal hostname by browser policy"),
      else: :ok
  end

  # Fold every IPv4-in-IPv6 representation to its embedded IPv4 BEFORE policy
  # checks, otherwise the IPv4-mapped (::ffff:a.b.c.d), IPv4-compatible
  # (::a.b.c.d) and NAT64 (64:ff9b::a.b.c.d) forms of metadata/private hosts
  # slip past every IPv4 rule. Genuine IPv6 — including :: (unspecified) and
  # ::1 (loopback) — is left untouched.
  defp fold_embedded_ipv4({0, 0, 0, 0, 0, 0xFFFF, hi, lo}), do: embedded_ipv4(hi, lo)
  defp fold_embedded_ipv4({0x64, 0xFF9B, 0, 0, 0, 0, hi, lo}), do: embedded_ipv4(hi, lo)
  defp fold_embedded_ipv4({0, 0, 0, 0, 0, 0, 0, 0} = ip), do: ip
  defp fold_embedded_ipv4({0, 0, 0, 0, 0, 0, 0, 1} = ip), do: ip
  defp fold_embedded_ipv4({0, 0, 0, 0, 0, 0, hi, lo}), do: embedded_ipv4(hi, lo)
  defp fold_embedded_ipv4(ip), do: ip

  defp embedded_ipv4(hi, lo) do
    {Bitwise.bsr(hi, 8), Bitwise.band(hi, 0xFF), Bitwise.bsr(lo, 8), Bitwise.band(lo, 0xFF)}
  end

  defp validate_ip(_host, {127, _, _, _}, _config), do: :ok
  defp validate_ip(_host, {0, 0, 0, 0, 0, 0, 0, 1}, _config), do: :ok

  defp validate_ip(host, ip, %Config{allow_private_network: false}) do
    if private_ip?(ip),
      do: blocked(host, "Blocked private network URL by browser policy"),
      else: :ok
  end

  defp validate_ip(_host, _ip, %Config{allow_private_network: true}), do: :ok

  defp parse_ip(host) do
    host
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, ip} -> {:ok, ip}
      {:error, _reason} -> :error
    end
  end

  # The unspecified address is a loopback alias on every stack that accepts it —
  # `http://[::]:11434` reaches a local Ollama — so it is blocked here even
  # though `fold_embedded_ipv4/1` leaves it intact. Genuine `::1` never reaches
  # this function: it is an address literal, so `validate_ip/3` answers it first
  # and allows it — deliberately, and under every `allowed_hosts` setting,
  # because looking at your own dev server is the point of the browser tool.
  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp private_ip?({10, _, _, _}), do: true
  defp private_ip?({172, b, _, _}) when b in 16..31, do: true
  defp private_ip?({192, 168, _, _}), do: true
  defp private_ip?({169, 254, _, _}), do: true
  defp private_ip?({100, b, _, _}) when b in 64..127, do: true
  defp private_ip?({0, _, _, _}), do: true
  defp private_ip?({a, _, _, _}) when a >= 224, do: true
  defp private_ip?({a, _, _, _, _, _, _, _}) when Bitwise.band(a, 0xFE00) == 0xFC00, do: true
  defp private_ip?({a, _, _, _, _, _, _, _}) when Bitwise.band(a, 0xFFC0) == 0xFE80, do: true
  # Deprecated site-local fec0::/10. The 0xFE80 test above misses it entirely.
  defp private_ip?({a, _, _, _, _, _, _, _}) when Bitwise.band(a, 0xFFC0) == 0xFEC0, do: true
  defp private_ip?(_ip), do: false

  defp internal_hostname?(host) do
    not String.contains?(host, ".") or String.ends_with?(host, @internal_suffixes)
  end

  defp blocked(value, message \\ "Blocked URL by browser policy") do
    {:error, Error.new("navigation_blocked", message, %{"value" => value})}
  end
end
