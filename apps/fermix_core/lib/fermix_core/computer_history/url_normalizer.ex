defmodule FermixCore.ComputerHistory.UrlNormalizer do
  @moduledoc """
  The one place a captured URL is reduced to what history stores: **scheme + host
  + path**, http(s) only (MILESTONE_32.1 §2.4, inv. 27).

  Query strings and fragments are where session ids, bearer tokens and tracking
  parameters live, and the page title already carries the meaning a query would,
  so they are dropped rather than scrubbed — a scrubber can only redact the
  patterns it knows, while dropping the whole component is total. Userinfo
  (`https://user:pass@host/`) and the port go with them: the first is a credential
  and the second is not part of the page's identity.

  Pure and total: `normalize/1` answers `{:ok, %{url, host}}` for a usable http(s)
  URL and `:error` for everything else (another scheme, no host, unparsable). The
  caller decides what an `:error` means — `Ingest` refuses and counts a
  `browser.navigated`, because a navigation without a usable address is not an
  observation, and only nils the column on any other kind.

  **The input contract is ASCII, and the parser stays RFC-3986-strict on purpose.**
  The recorder hands Fermix the `CFURL` serialization, which is already ASCII: an
  internationalized host arrives punycoded (`xn--…`) and a non-ASCII path arrives
  percent-encoded, both of which parse and normalize here. A raw non-ASCII URL is
  therefore not a URL this pipeline can receive — it is a contract violation — so it
  is refused and counted rather than repaired by a lenient second parse. Widening
  the parser would mean two spellings of the same page in the `url` column and a
  silent divergence from whatever the recorder actually saw.
  """

  @schemes ~w(http https)

  @doc """
  Reduce `url` to `scheme://host/path` with a lowercase scheme and host, or
  `:error`. An empty path becomes `/`; the path itself is kept verbatim (it is
  part of the page's identity and is scrubbed downstream like any free-form
  column).
  """
  @spec normalize(String.t()) :: {:ok, %{url: String.t(), host: String.t()}} | :error
  def normalize(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, uri} -> build(uri)
      {:error, _part} -> :error
    end
  end

  defp build(%URI{scheme: scheme, host: host} = uri) when is_binary(scheme) and is_binary(host) do
    scheme = String.downcase(scheme)
    host = String.downcase(host)

    if scheme in @schemes and host != "" do
      {:ok, %{url: scheme <> "://" <> host <> path(uri), host: host}}
    else
      :error
    end
  end

  # No scheme (a bare `example.com/x`), or a scheme with no authority at all
  # (`about:blank`, `mailto:…`, `file:///…` parses to an empty host and is
  # refused above).
  defp build(%URI{}), do: :error

  defp path(%URI{path: path}) when is_binary(path) and path != "", do: path
  defp path(%URI{}), do: "/"
end
