defmodule FermixCore.Browser.Policy do
  @moduledoc false

  alias FermixCore.Browser.Config
  alias FermixCore.Browser.Error

  @unsafe_schemes ~w(file ftp data javascript)

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
    host = String.downcase(host)

    cond do
      host in Enum.map(config.allowed_hosts, &String.downcase/1) ->
        :ok

      host == "localhost" ->
        :ok

      internal_hostname?(host) ->
        blocked(host, "Blocked internal hostname by browser policy")

      true ->
        validate_ip_or_public_host(host, config)
    end
  end

  defp validate_ip_or_public_host(host, config) do
    case parse_ip(host) do
      {:ok, ip} -> validate_ip(host, fold_embedded_ipv4(ip), config)
      :error -> :ok
    end
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

  defp private_ip?({10, _, _, _}), do: true
  defp private_ip?({172, b, _, _}) when b in 16..31, do: true
  defp private_ip?({192, 168, _, _}), do: true
  defp private_ip?({169, 254, _, _}), do: true
  defp private_ip?({100, b, _, _}) when b in 64..127, do: true
  defp private_ip?({0, _, _, _}), do: true
  defp private_ip?({a, _, _, _}) when a >= 224, do: true
  defp private_ip?({a, _, _, _, _, _, _, _}) when Bitwise.band(a, 0xFE00) == 0xFC00, do: true
  defp private_ip?({a, _, _, _, _, _, _, _}) when Bitwise.band(a, 0xFFC0) == 0xFE80, do: true
  defp private_ip?(_ip), do: false

  defp internal_hostname?(host), do: not String.contains?(host, ".")

  defp blocked(value, message \\ "Blocked URL by browser policy") do
    {:error, Error.new("navigation_blocked", message, %{"value" => value})}
  end
end
