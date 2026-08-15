defmodule FermixChannels.Mobile.Discovery do
  @moduledoc """
  Enumerates local addresses that are useful to an already-paired mobile client.

  Discovery is deliberately bounded and dependency-injectable. It enumerates
  interfaces, then performs at most eight reverse-DNS lookups for tailnet IPs
  so resolvable Tailscale MagicDNS names travel with the numeric candidates.
  """

  @type scope :: :lan | :tailnet
  @type candidate :: %{address: String.t(), interface: String.t(), scope: scope()}

  @max_magicdns_lookups 8
  @magicdns_timeout_ms 750
  @hostname_label ~r/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/

  @doc "Returns private-LAN and Tailscale IPv4 candidates for active interfaces."
  @spec discover(keyword()) :: {:ok, [candidate()]} | {:error, term()}
  def discover(opts \\ [])

  def discover(opts) when is_list(opts) do
    getifaddrs = Keyword.get(opts, :getifaddrs, &:inet.getifaddrs/0)
    reverse_lookup = Keyword.get(opts, :reverse_lookup, &:inet.gethostbyaddr/2)
    validate_getifaddrs!(getifaddrs)
    validate_reverse_lookup!(reverse_lookup)

    case getifaddrs.() do
      {:ok, interfaces} -> {:ok, collect_candidates(interfaces, reverse_lookup)}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_getifaddrs_result, other}}
    end
  end

  def discover(_opts), do: raise(ArgumentError, "discovery options must be a keyword list")

  @doc "Classifies an IPv4 address if it is eligible for mobile candidate racing."
  @spec classify(:inet.ip4_address()) :: scope() | nil
  def classify({100, second, _, _}) when second in 64..127, do: :tailnet
  def classify({10, _, _, _}), do: :lan
  def classify({172, second, _, _}) when second in 16..31, do: :lan
  def classify({192, 168, _, _}), do: :lan
  def classify(_address), do: nil

  defp validate_getifaddrs!(fun) when is_function(fun, 0), do: :ok

  defp validate_getifaddrs!(_fun),
    do: raise(ArgumentError, ":getifaddrs must be a 0-arity function")

  defp validate_reverse_lookup!(fun) when is_function(fun, 2), do: :ok

  defp validate_reverse_lookup!(_fun),
    do: raise(ArgumentError, ":reverse_lookup must be a 2-arity function")

  defp collect_candidates(interfaces, reverse_lookup)
       when is_list(interfaces) or is_map(interfaces) do
    candidates = interfaces |> Enum.flat_map(&interface_candidates/1) |> unique_candidates()
    {tailnet, lan} = Enum.split_with(candidates, &(&1.scope == :tailnet))
    magicdns = magicdns_candidates(tailnet, reverse_lookup)

    unique_candidates(magicdns ++ tailnet ++ lan)
  end

  defp collect_candidates(_interfaces, _reverse_lookup), do: []

  defp magicdns_candidates(tailnet, reverse_lookup) do
    tailnet
    |> Enum.take(@max_magicdns_lookups)
    |> Enum.flat_map(&magicdns_candidate(&1, reverse_lookup))
  end

  defp magicdns_candidate(candidate, reverse_lookup) do
    with {:ok, address} <- parse_ipv4(candidate.address),
         {:ok, hostent} <- reverse_lookup.(address, @magicdns_timeout_ms),
         {:ok, hostname} <- magicdns_hostname(hostent) do
      [%{candidate | address: hostname}]
    else
      {:error, _reason} -> []
    end
  end

  defp magicdns_hostname({:hostent, name, _aliases, :inet, 4, _addresses}) do
    hostname = name |> to_string() |> String.trim_trailing(".") |> String.downcase()

    if valid_magicdns_hostname?(hostname), do: {:ok, hostname}, else: {:error, :invalid_hostname}
  end

  defp magicdns_hostname(_hostent), do: {:error, :invalid_hostent}

  defp valid_magicdns_hostname?(hostname) do
    labels = String.split(hostname, ".", trim: true)

    String.ends_with?(hostname, ".ts.net") and byte_size(hostname) <= 253 and
      Enum.all?(labels, &Regex.match?(@hostname_label, &1))
  end

  defp parse_ipv4(address) do
    address |> String.to_charlist() |> :inet.parse_ipv4_address()
  end

  defp unique_candidates(candidates), do: Enum.uniq_by(candidates, & &1.address)

  defp interface_candidates({name, properties}) when is_list(properties) do
    if usable_interface?(properties) do
      properties
      |> Keyword.get_values(:addr)
      |> Enum.flat_map(&candidate(name, &1))
    else
      []
    end
  end

  defp interface_candidates(_interface), do: []

  defp usable_interface?(properties) do
    flags = Keyword.get(properties, :flags, [])
    :up in flags and :loopback not in flags
  end

  defp candidate(name, {a, b, c, d} = address)
       when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255 do
    case classify(address) do
      nil -> []
      scope -> [%{address: address_string(address), interface: to_string(name), scope: scope}]
    end
  end

  defp candidate(_name, _address), do: []

  defp address_string(address) do
    address |> :inet.ntoa() |> IO.iodata_to_binary()
  end
end
