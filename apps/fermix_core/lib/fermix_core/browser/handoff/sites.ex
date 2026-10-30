defmodule FermixCore.Browser.Handoff.Sites do
  @moduledoc """
  The sites a browser hand-off names (M75 D18, B10).

  A site is a host, named exactly: it covers that host and its subdomains,
  never a wildcard. `github.com` covers `github.com` and `gist.github.com`,
  and a cookie belongs to the most specific site that covers its domain.

  A site must be a DNS name of at least two labels, with no scheme, port,
  path, wildcard or address. A site that is a public suffix Fermix knows
  (`co.uk`, `github.io`, …) is refused: it would cover every site under it.

  **Identity providers.** A site that covers an identity provider's sign-in
  host, or is covered by one, moves the session that signs the owner in to
  everything else: `accounts.google.com`, `login.microsoftonline.com`,
  `appleid.apple.com`, `login.live.com`, `github.com` (whose sign-in is
  `github.com/login`), and the Okta and Auth0 hosts. Such a site is refused
  unless the owner names it and passes `--allow-identity-provider`; the flag
  covers only the sites named with it, so one is never moved by accident.

  Pure.
  """

  @identity_hosts ~w(
    accounts.google.com login.microsoftonline.com appleid.apple.com login.live.com github.com
  )
  # Okta and Auth0 sign each customer in on a host of their own under these.
  @identity_domains ~w(okta.com oktapreview.com okta-emea.com auth0.com)
  # Public suffixes a person is likely to type, each of which would cover
  # every site registered under it. Not the whole list: a suffix not here
  # still needs two labels, which a top-level domain alone never has.
  @public_suffixes ~w(
    co.uk org.uk ac.uk gov.uk me.uk ltd.uk plc.uk net.uk co.jp ne.jp or.jp ac.jp go.jp
    com.au net.au org.au edu.au gov.au co.nz org.nz net.nz com.br net.br org.br co.in net.in
    org.in com.cn net.cn org.cn com.mx com.ar com.tr com.sg com.hk co.kr co.za co.il
    github.io gitlab.io herokuapp.com vercel.app netlify.app pages.dev workers.dev
    appspot.com web.app firebaseapp.com azurewebsites.net cloudfront.net blogspot.com
    s3.amazonaws.com
  )
  @max_sites 64
  @max_site_bytes 253
  @label ~r/\A[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\z/

  @typedoc "Why a list of sites was refused."
  @type refusal ::
          :no_sites
          | {:too_many_sites, pos_integer()}
          | {:invalid_site, String.t()}
          | {:public_suffix, String.t()}
          | {:identity_provider, String.t()}

  @doc "How many sites one hand-off may name."
  @spec max_sites() :: pos_integer()
  def max_sites, do: @max_sites

  @doc "The identity providers' sign-in hosts and the domains whose hosts are each one."
  @spec identity_providers() :: %{hosts: [String.t()], domains: [String.t()]}
  def identity_providers, do: %{hosts: @identity_hosts, domains: @identity_domains}

  @doc """
  The sites `names` name, lower-cased and each once, in the order given; or the
  first refusal. `allow_identity_provider?` is the owner's flag.
  """
  @spec parse([String.t()], boolean()) :: {:ok, [String.t()]} | {:error, refusal()}
  def parse(names, allow_identity_provider?)
      when is_list(names) and is_boolean(allow_identity_provider?) do
    with :ok <- count(names),
         {:ok, sites} <- normalize_all(names) do
      admit(Enum.uniq(sites), allow_identity_provider?)
    end
  end

  @doc "Whether `site` covers the cookie domain `domain` (a leading dot ignored)."
  @spec covers?(String.t(), String.t()) :: boolean()
  def covers?(site, domain) when is_binary(site) and is_binary(domain) do
    host = domain |> String.trim_leading(".") |> String.downcase()
    host == site or String.ends_with?(host, "." <> site)
  end

  @doc "The most specific of `sites` that covers `domain`, or `nil`."
  @spec site_for([String.t()], String.t()) :: String.t() | nil
  def site_for(sites, domain) when is_list(sites) and is_binary(domain) do
    sites
    |> Enum.filter(&covers?(&1, domain))
    |> Enum.max_by(&byte_size/1, fn -> nil end)
  end

  @doc "Whether `site` covers, or is covered by, an identity provider's sign-in host."
  @spec identity_provider?(String.t()) :: boolean()
  def identity_provider?(site) when is_binary(site) do
    Enum.any?(@identity_hosts, &(related?(site, &1) or related?(&1, site))) or
      Enum.any?(@identity_domains, &related?(site, &1))
  end

  defp related?(host, site), do: host == site or String.ends_with?(host, "." <> site)

  defp count([]), do: {:error, :no_sites}

  defp count(names) when length(names) > @max_sites,
    do: {:error, {:too_many_sites, length(names)}}

  defp count(_names), do: :ok

  defp normalize_all(names) do
    results = Enum.map(names, &normalize/1)

    case Enum.find(results, &match?({:error, _reason}, &1)) do
      nil -> {:ok, Enum.map(results, fn {:ok, site} -> site end)}
      error -> error
    end
  end

  defp normalize(name) when is_binary(name) do
    site = name |> String.trim() |> String.downcase() |> String.trim_trailing(".")
    labels = String.split(site, ".")

    cond do
      not host_name?(site, labels) -> {:error, {:invalid_site, name}}
      site in @public_suffixes -> {:error, {:public_suffix, site}}
      true -> {:ok, site}
    end
  end

  defp normalize(name), do: {:error, {:invalid_site, inspect(name)}}

  # A DNS name of two labels or more; the last one is never all digits, so an
  # IPv4 address is not a site.
  defp host_name?(site, labels) do
    byte_size(site) in 1..@max_site_bytes and length(labels) >= 2 and
      Enum.all?(labels, &Regex.match?(@label, &1)) and
      not Regex.match?(~r/\A[0-9]+\z/, List.last(labels))
  end

  defp admit(sites, true), do: {:ok, sites}

  defp admit(sites, false) do
    case Enum.find(sites, &identity_provider?/1) do
      nil -> {:ok, sites}
      site -> {:error, {:identity_provider, site}}
    end
  end
end
