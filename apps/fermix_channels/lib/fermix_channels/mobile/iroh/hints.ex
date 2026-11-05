defmodule FermixChannels.Mobile.Iroh.Hints do
  @moduledoc """
  Direct address hints (M75 Always On, *Connectivity: iroh only*): where a
  desktop may dial its Always On server without Fermix's relay.

  **The fixed port.** An Always On server's listening endpoint binds UDP
  4033 (`bind_port/1`), as a candidate and as the primary, so an address
  recorded at enrollment still holds after the server restarts. The server
  is the machine `fermix home enroll` made a candidate
  (`FermixCore.Home.Candidate.server?/1`), a mark that stays on the machine
  through the move, whose activation replaces the home's settings with the
  moved ones. Every other engine (a Mac, a primary that serves phones, a
  desktop, a computer a home moves back to) binds whatever port iroh picks.

  **The hints** are the server's Tailscale addresses at that port
  (`tailnet/2`): IPv4 in `100.64.0.0/10` and IPv6 in `fd7a:115c:a1e0::/48`, on
  interfaces that are up and not a loopback, at most 8 (the most a `dial`
  takes), IPv4 first. Read when they are given, never cached, since Tailscale
  may be set up after enrollment. No public address: dialing one needs an open
  inbound port, and iroh's relay-assisted hole punching finds public paths by
  itself. No hints is the normal case for a server without Tailscale.

  The server's listening helper answers them (`Iroh.Helper.hints/1`): in its
  `enroll_request` and in every desktop session's `hello_ack`. A desktop keeps
  the latest in its link (`FermixCore.Home.DesktopLink`) and dials with them.
  A hint that fails changes nothing: iroh tries the relay as well.
  """

  require Logger

  alias FermixCore.Home.Candidate

  @server_port 4033
  @max_hints 8

  @typedoc "A `getifaddrs/0` stand-in: `:inet.getifaddrs/0` or a test's."
  @type interfaces :: (-> {:ok, list()} | {:error, term()})

  @doc "The UDP port an Always On server's iroh endpoint binds."
  @spec server_port() :: 1..65_535
  def server_port, do: @server_port

  @doc """
  The fixed UDP port this machine's listening endpoint binds for the home at
  `home`: 4033 on an Always On server, `nil` (iroh's own port) everywhere
  else.
  """
  @spec bind_port(Path.t()) :: 1..65_535 | nil
  def bind_port(home) when is_binary(home) and home != "" do
    if Candidate.server?(home), do: @server_port
  end

  @doc """
  This machine's Tailscale addresses at `port`, each `ip:port` (IPv6 in
  brackets), from `interfaces` read now. Interfaces that cannot be listed give
  none, and the log says why.
  """
  @spec tailnet(interfaces(), 1..65_535) :: [String.t()]
  def tailnet(interfaces, port)
      when is_function(interfaces, 0) and is_integer(port) and port in 1..65_535 do
    case interfaces.() do
      {:ok, list} when is_list(list) ->
        list |> addresses() |> Enum.map(&hint(&1, port)) |> Enum.take(@max_hints)

      {:error, reason} ->
        Logger.warning(
          "iroh: no address hints: the interfaces could not be listed: #{inspect(reason)}"
        )

        []
    end
  end

  defp addresses(interfaces) do
    found = interfaces |> Enum.flat_map(&interface_addresses/1) |> Enum.uniq()
    {ipv4, ipv6} = Enum.split_with(found, &(tuple_size(&1) == 4))
    ipv4 ++ ipv6
  end

  defp interface_addresses({_name, properties}) when is_list(properties) do
    flags = Keyword.get(properties, :flags, [])

    if :up in flags and :loopback not in flags,
      do: properties |> Keyword.get_values(:addr) |> Enum.filter(&tailnet?/1),
      else: []
  end

  defp interface_addresses(_interface), do: []

  defp tailnet?({100, second, _c, _d}) when second in 64..127, do: true
  defp tailnet?({0xFD7A, 0x115C, 0xA1E0, _d, _e, _f, _g, _h}), do: true
  defp tailnet?(_address), do: false

  defp hint({_a, _b, _c, _d} = address, port), do: "#{:inet.ntoa(address)}:#{port}"
  defp hint(address, port), do: "[#{:inet.ntoa(address)}]:#{port}"
end
