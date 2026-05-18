defmodule FermixCore.Net.Guard do
  @moduledoc """
  Public-web URL guard shared by outbound tools.
  """

  import Bitwise

  @sensitive_headers ~w(authorization cookie set-cookie proxy-authorization x-api-key x-auth-token)

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
          {:ok, ips} -> first_validated_ip(ips)
          {:error, reason} -> {:error, {:dns_resolution_failed, reason}}
        end
    end
  end

  defp first_validated_ip(ips) do
    Enum.reduce_while(ips, {:error, {:dns_resolution_failed, :no_public_ip}}, fn ip, _acc ->
      case validate_public_ip(ip, {:resolved_to_private_address, ip}) do
        :ok -> {:halt, {:ok, ip}}
        {:error, _reason} = err -> {:halt, err}
      end
    end)
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

  defp private_ip?({a, b, _c, _d}) do
    private_ipv4_prefix?(a, b) or reserved_ipv4_prefix?(a)
  end

  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  defp private_ip?({0, 0, 0, 0, 0, 65_535, high, low}) do
    private_ip?({high >>> 8, high &&& 255, low >>> 8, low &&& 255})
  end

  defp private_ip?({first, _b, _c, _d, _e, _f, _g, _h}) do
    cond do
      (first &&& 0xFE00) == 0xFC00 -> true
      (first &&& 0xFFC0) == 0xFE80 -> true
      (first &&& 0xFF00) == 0xFF00 -> true
      true -> false
    end
  end

  defp private_ipv4_prefix?(a, b) do
    a == 10 or a == 127 or a == 0 or
      (a == 169 and b == 254) or
      (a == 192 and b == 168) or
      (a == 172 and b in 16..31)
  end

  defp reserved_ipv4_prefix?(a), do: a in 224..239 or a >= 240
end
