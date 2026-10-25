defmodule FermixCore.Net.PinnedUrl do
  @moduledoc """
  A URL pinned to the address `Net.Guard` validated for it, and the one place
  that builds and sends a request to it, so every fetch of a public URL closes
  the same DNS-rebinding gap (audit F-04): the name is looked up and checked
  once, the connection goes to the address that was checked, and nothing looks
  the name up a second time between the check and the connect.

  `pin/2` resolves the URL through `Guard.resolve_and_validate/2` (with the
  caller's `:resolver`) and puts the validated address in place of the host,
  an IPv6 one in brackets. It keeps the URL and the host as given: a redirect's
  `Location` and a page's relative links resolve against `original_url`, never
  against the address, and a redirect target is pinned again on its own.

  `request/3` sends the request, end to end:

    * `Host` names the original host and the TLS name (`server_name_indication`)
      is set to it, so the certificate is verified against the name although the
      socket connects to the address (`request_options/2`).
    * Req never follows a redirect for it: a followed hop would go out by name
      with this hop's `Host`, TLS name and pin. The 3xx comes back to the caller.
    * It is routed by `Net.Egress` with the egress the caller passes, and the
      name is recorded there (`Egress.put_pinned_host/2`), so a `proxy_bypass`
      entry naming the host still applies. Behind a proxy the HTTPS tunnel is
      opened to the address and the name stays inside it.
    * A Finch pool with no connection to give raises rather than returns; that
      one raise comes back as `{:error, exception}`, logged by host.

  The request dials that one address, the guard's first answer (IPv4 before
  IPv6), with no second address to fall back to.

  Its own connect options give it a Finch instance Req starts per distinct set
  of them and never stops, and that instance's pool would keep an idle
  connection for good, to fail on the first request after the machine slept.
  The pool is therefore stopped after 15 s idle, its connections with it
  (`pool_max_idle_time`). The instance itself stays: Req offers no way to stop
  it.

  A URL whose host is already an address has nothing to look up again: it gets
  no `Host` or TLS name of its own, and is otherwise sent the same way.
  """

  require Logger

  alias FermixCore.Net.Egress
  alias FermixCore.Net.Guard
  alias FermixCore.Net.HttpClient

  # The shared pools' idle bound (`FermixCore.Application`), well under the
  # gap between two polls of a Cue feed.
  @pool_max_idle_ms 15_000

  @enforce_keys [:url, :original_url, :original_host, :ip]
  defstruct @enforce_keys

  @typedoc """
  `url` is what is dialled; `original_url` and `original_host` are as given;
  `ip` is the address that was checked, `nil` when the URL already names one.
  """
  @type t :: %__MODULE__{
          url: String.t(),
          original_url: String.t(),
          original_host: String.t(),
          ip: :inet.ip_address() | nil
        }

  @doc """
  Resolves and validates `url` (`Guard.resolve_and_validate/2`, passed `opts`)
  and pins it to the validated address. The guard's refusal is returned as is.
  """
  @spec pin(String.t(), Guard.opts()) :: {:ok, t()} | {:error, term()}
  def pin(url, opts \\ []) when is_binary(url) and is_list(opts) do
    case Guard.resolve_and_validate(url, opts) do
      :ok -> {:ok, unpinned(url)}
      {:ok, ip} -> {:ok, pinned(url, ip)}
      {:error, _reason} = refused -> refused
    end
  end

  @doc """
  The `Req` options `request/3` sends for `pinned`: `options` with the URL set
  to the pinned one, `Host` naming the original host ahead of the caller's
  headers (replacing any `Host` among them), the TLS name set to it in
  `:connect_options` (the caller's other connect and transport options kept),
  `redirect: false` and the pool's idle bound. Public so that a test seam
  standing in for `request/3` sees what would be sent.
  """
  @spec request_options(t(), keyword()) :: keyword()
  def request_options(%__MODULE__{} = pinned, options) when is_list(options) do
    options
    |> put_name(pinned)
    |> Keyword.merge(url: pinned.url, redirect: false, pool_max_idle_time: @pool_max_idle_ms)
  end

  @doc """
  Sends the request to `pinned` built from `options` (`request_options/2`),
  routed by `egress`. A pool with no connection to give is `{:error, exception}`;
  any other raise is not caught.
  """
  @spec request(t(), keyword(), Egress.t()) :: {:ok, Req.Response.t()} | {:error, Exception.t()}
  def request(%__MODULE__{} = pinned, options, %Egress{} = egress) when is_list(options) do
    pinned
    |> request_options(options)
    |> Req.new()
    |> Egress.put_pinned_host(pinned.original_host)
    |> Egress.attach(:direct, egress)
    |> send_request(pinned.original_host)
  end

  defp send_request(request, host) do
    Req.request(request)
  rescue
    error in RuntimeError -> no_connection!(error, host, __STACKTRACE__)
  end

  # Finch reraises its pool-checkout timeout in the caller (`Net.HttpClient`
  # explains). Any other `RuntimeError` is a bug and goes on up.
  defp no_connection!(error, host, stacktrace) do
    if HttpClient.connection_unavailable?(error) do
      Logger.warning("Pinned request to #{host} got no connection: #{Exception.message(error)}")
      {:error, error}
    else
      reraise error, stacktrace
    end
  end

  defp unpinned(url),
    do: %__MODULE__{url: url, original_url: url, original_host: URI.parse(url).host, ip: nil}

  # `URI.to_string/1` brackets an IPv6 host itself.
  defp pinned(url, ip) do
    uri = URI.parse(url)
    address = ip |> :inet.ntoa() |> to_string()

    %__MODULE__{
      url: URI.to_string(%{uri | host: address}),
      original_url: url,
      original_host: uri.host,
      ip: ip
    }
  end

  defp put_name(options, %__MODULE__{ip: nil}), do: options

  defp put_name(options, %__MODULE__{original_host: host}) do
    {headers, options} = Keyword.pop(options, :headers, [])
    {connect, options} = Keyword.pop(options, :connect_options, [])

    options
    |> Keyword.put(:headers, [{"host", host} | without_host(headers)])
    |> Keyword.put(:connect_options, with_tls_name(connect, host))
  end

  defp without_host(headers) when is_list(headers),
    do: Enum.reject(headers, fn {name, _value} -> String.downcase(to_string(name)) == "host" end)

  defp with_tls_name(connect, host) when is_list(connect) do
    transport = Keyword.get(connect, :transport_opts, [])
    name = String.to_charlist(host)
    Keyword.put(connect, :transport_opts, Keyword.put(transport, :server_name_indication, name))
  end
end
