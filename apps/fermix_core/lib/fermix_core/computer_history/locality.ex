defmodule FermixCore.ComputerHistory.Locality do
  @moduledoc """
  Pure loopback classifier for provider base URLs (MILESTONE_32 §9.3).

  The Computer History Gate treats a route as local only when the provider
  declares `locality: :local_loopback` AND its *effective* base URL resolves
  to loopback. This module answers the second half: does a base URL point at
  this machine's loopback interface?

  Loopback is strict and narrow — `localhost`, IPv4 `127.0.0.0/8`, and IPv6
  `::1` only. A private-LAN address (`192.168.x.x`, `10.x.x.x`) is *not*
  loopback: it can name another host, so it is remote for this gate. A
  malformed or hostless URL is remote (fail closed) — "unverifiable locality
  is remote." This deliberately does not reuse `Net.Guard`'s broader
  private-IP predicate, which blocks a wider set for a different purpose.
  """

  @doc """
  Whether `base_url` resolves to the loopback interface. `nil`, a non-binary,
  or an unparseable/hostless URL is `false` (remote).
  """
  @spec loopback?(String.t() | nil) :: boolean()
  def loopback?(base_url) when is_binary(base_url) do
    base_url
    |> URI.parse()
    |> Map.get(:host)
    |> loopback_host?()
  end

  def loopback?(_other), do: false

  defp loopback_host?(nil), do: false

  defp loopback_host?(host) when is_binary(host) do
    normalized = host |> String.downcase() |> strip_brackets()

    normalized == "localhost" or normalized == "::1" or ipv4_loopback?(normalized)
  end

  # IPv6 hosts arrive bracketed in a URL authority ("[::1]").
  defp strip_brackets("[" <> rest), do: String.trim_trailing(rest, "]")
  defp strip_brackets(host), do: host

  # 127.0.0.0/8 — any address whose first octet is 127 is loopback.
  defp ipv4_loopback?(host) do
    case :inet.parse_ipv4_address(String.to_charlist(host)) do
      {:ok, {127, _b, _c, _d}} -> true
      _other -> false
    end
  end
end
