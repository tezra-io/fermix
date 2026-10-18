defmodule FermixCore.Capabilities.MCP.Remote.Endpoint do
  @moduledoc """
  The validated remote MCP endpoint (M27 §7.2 rules 4-7, §7.4; M74 E4).

  An endpoint has one of two sources, and this module is the single place that
  decides whether either is a legal target and turns its host into a validated
  peer address:

    * **`:manifest`** (`new/2`): a signed plugin manifest's `base_url` and
      `mcp_path`, and nowhere else — not user config, not the environment, not
      a redirect. Validation is deliberately narrow: an origin with a path,
      query, fragment, userinfo, template, wildcard, or IP literal is refused
      outright rather than normalized into something safe-looking, and the peer
      must be globally routable.
    * **`:operator`** (`operator/1`): the URL the owner typed for an
      `[mcp.servers.*]` server. It may carry a path and a query, and name an IP
      literal, a private network or this machine, because the owner typed it;
      userinfo, a fragment and a template are refused, plain `http` is allowed
      only to this machine, and its peers are checked under `Net.Guard`'s owner
      policy: the operating system's answers for its name, none of them a
      link-local or cloud metadata address.

  Both answer this one struct, which the one remote client takes. `resolve/2`
  returns the peers the caller may connect to, in order. Callers connect to
  one of those addresses while presenting the endpoint's **hostname** for the
  `Host` header, TLS SNI, and certificate verification — validating a name
  and then letting the socket layer resolve it again is not a gate (the
  resolver could answer differently the second time).
  """

  alias FermixCore.Net.Guard

  @type t :: %__MODULE__{
          scheme: :https | :http,
          host: String.t(),
          port: pos_integer(),
          path: String.t(),
          source: :manifest | :operator
        }

  # `path` is the request target: the path, and the query an operator URL
  # carries.
  @enforce_keys [:scheme, :host, :port, :path, :source]
  defstruct [:scheme, :host, :port, :path, :source]

  @default_ports %{https: 443, http: 80}

  # `{`/`}` catch manifest templating, `*` catches wildcard hosts. Both would
  # mean the effective target is not the reviewed, signed one.
  @template_chars ["{", "}", "*"]

  @doc """
  Build a validated endpoint from a manifest's `base_url` and `mcp_path`.

  `base_url` must be an HTTPS **origin**: scheme, host, optional port, nothing
  else. `mcp_path` must be a literal absolute path.
  """
  @spec new(String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def new(base_url, mcp_path) when is_binary(base_url) and is_binary(mcp_path) do
    with {:ok, host, port} <- validate_base_url(base_url),
         :ok <- validate_mcp_path(mcp_path) do
      {:ok,
       %__MODULE__{scheme: :https, host: host, port: port, path: mcp_path, source: :manifest}}
    end
  end

  def new(base_url, mcp_path), do: {:error, {:invalid_endpoint, base_url, mcp_path}}

  @doc """
  Build a validated endpoint from the URL the owner typed.

  `https` to any host, `http` only to this machine (`Net.Guard.loopback_host?/1`).
  The path follows the manifest path's rules, an absent one is `/`, and a
  query rides the request target.
  """
  @spec operator(String.t()) :: {:ok, t()} | {:error, term()}
  def operator(url) when is_binary(url) do
    with :ok <- refuse_unsafe_text(url, :invalid_url),
         %URI{} = uri <- URI.parse(url),
         {:ok, scheme} <- operator_scheme(uri.scheme),
         :ok <- check(is_nil(uri.userinfo), {:invalid_url, :userinfo_not_allowed}),
         :ok <- check(is_nil(uri.fragment), {:invalid_url, :fragment_not_allowed}),
         {:ok, host} <- operator_host(uri.host),
         :ok <- clear_text_to_loopback(scheme, host),
         {:ok, target} <- operator_target(uri) do
      {:ok,
       %__MODULE__{scheme: scheme, host: host, port: uri.port, path: target, source: :operator}}
    end
  end

  def operator(_url), do: {:error, {:invalid_url, :not_text}}

  @doc """
  The absolute request URI. Contains no credential — the bearer rides in a
  header the transport process builds, never in the target.
  """
  @spec uri(t()) :: String.t()
  def uri(%__MODULE__{} = endpoint), do: origin(endpoint) <> endpoint.path

  @doc "The scheme/host/port origin, for status text and error classes."
  @spec origin(t()) :: String.t()
  def origin(%__MODULE__{scheme: scheme, port: port} = endpoint) do
    if Map.fetch!(@default_ports, scheme) == port,
      do: "#{scheme}://#{authority_host(endpoint)}",
      else: "#{scheme}://#{authority_host(endpoint)}:#{port}"
  end

  @doc "The host as a URL's authority writes it: an IPv6 literal in brackets."
  @spec authority_host(t()) :: String.t()
  def authority_host(%__MODULE__{host: host}) do
    if String.contains?(host, ":"), do: "[#{host}]", else: host
  end

  @doc """
  Resolve the endpoint's host to the validated peer addresses, in the order
  they are to be dialled.

  A manifest endpoint has one: every A and AAAA answer must be globally
  routable, and the first is the peer. An operator endpoint has each answer
  the operating system's resolver gives, none of them a link-local or metadata
  address, or its IP literal. `Net.Guard` refuses the whole set if any answer
  fails, so Fermix never picks a convenient answer out of a mixed reply.
  Callers must re-run this before every new connection — a cached peer is a
  cached DNS decision.
  """
  @spec resolve(t(), keyword()) :: {:ok, [:inet.ip_address(), ...]} | {:error, term()}
  def resolve(endpoint, opts \\ [])

  def resolve(%__MODULE__{source: :manifest} = endpoint, opts) when is_list(opts) do
    case Guard.resolve_and_validate(uri(endpoint), opts) do
      {:ok, ip} -> {:ok, [ip]}
      # An IP-literal host is refused at `new/2`, so the guard's `:ok`
      # (nothing to pin) is unreachable here; treat it as the invariant
      # violation it would be rather than connecting unpinned.
      :ok -> {:error, {:remote_security_blocked, :endpoint_not_pinnable}}
      {:error, reason} -> {:error, {:remote_security_blocked, reason}}
    end
  end

  def resolve(%__MODULE__{source: :operator} = endpoint, opts) when is_list(opts) do
    case Guard.owner_peers(uri(endpoint), opts) do
      {:ok, peers} -> {:ok, peers}
      {:error, reason} -> {:error, {:remote_security_blocked, reason}}
    end
  end

  defp validate_base_url(base_url) do
    with :ok <- refuse_unsafe_text(base_url, :invalid_base_url),
         %URI{} = uri <- URI.parse(base_url),
         :ok <- check(uri.scheme == "https", {:invalid_base_url, :scheme_not_https}),
         :ok <- check(is_nil(uri.userinfo), {:invalid_base_url, :userinfo_not_allowed}),
         :ok <- check(is_nil(uri.query), {:invalid_base_url, :query_not_allowed}),
         :ok <- check(is_nil(uri.fragment), {:invalid_base_url, :fragment_not_allowed}),
         :ok <- check(uri.path in [nil, ""], {:invalid_base_url, :path_not_allowed}),
         {:ok, host} <- validate_host(uri.host) do
      {:ok, host, uri.port || @default_ports.https}
    end
  end

  defp operator_scheme("https"), do: {:ok, :https}
  defp operator_scheme("http"), do: {:ok, :http}
  defp operator_scheme(_scheme), do: {:error, {:invalid_url, :scheme_not_http_or_https}}

  defp operator_host(host) when is_binary(host) and host != "", do: {:ok, String.downcase(host)}
  defp operator_host(_host), do: {:error, {:invalid_url, :empty_host}}

  # Plain `http` carries the headers, the key among them, in the clear, so it
  # goes no further than this machine.
  defp clear_text_to_loopback(:https, _host), do: :ok

  defp clear_text_to_loopback(:http, host),
    do: check(Guard.loopback_host?(host), {:invalid_url, :http_only_to_loopback})

  defp operator_target(%URI{path: path, query: query}) do
    path = if path in [nil, ""], do: "/", else: path

    case validate_mcp_path(path) do
      :ok -> {:ok, if(is_nil(query), do: path, else: path <> "?" <> query)}
      {:error, {:invalid_mcp_path, reason}} -> {:error, {:invalid_url, reason}}
    end
  end

  defp validate_host(host) when is_binary(host) and host != "" do
    host = String.downcase(host)

    # An IP literal cannot be pinned — there is no name left to verify the
    # certificate against, so the DNS revalidation contract is unenforceable.
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, _ip} -> {:error, {:invalid_base_url, :ip_literal_not_allowed}}
      {:error, :einval} -> {:ok, host}
    end
  end

  defp validate_host(_host), do: {:error, {:invalid_base_url, :empty_host}}

  defp validate_mcp_path(path) do
    with :ok <- refuse_unsafe_text(path, :invalid_mcp_path),
         :ok <- check(String.starts_with?(path, "/"), {:invalid_mcp_path, :not_absolute}),
         :ok <- check(not String.contains?(path, "?"), {:invalid_mcp_path, :query_not_allowed}),
         :ok <- check(not String.contains?(path, "#"), {:invalid_mcp_path, :fragment_not_allowed}),
         :ok <- check(not String.contains?(path, "\\"), {:invalid_mcp_path, :backslash}),
         :ok <- check(not encoded_slash?(path), {:invalid_mcp_path, :encoded_slash}) do
      check(not dot_segment?(path), {:invalid_mcp_path, :dot_segment})
    end
  end

  # A percent-encoded slash re-introduces path structure after validation: the
  # server may decode it into a segment boundary this module never reviewed.
  defp encoded_slash?(path) do
    downcased = String.downcase(path)
    String.contains?(downcased, "%2f")
  end

  defp dot_segment?(path) do
    path |> String.split("/") |> Enum.any?(&(&1 in [".", ".."]))
  end

  defp refuse_unsafe_text(value, tag) do
    cond do
      value == "" -> {:error, {tag, :empty}}
      Regex.match?(~r/[[:space:][:cntrl:]]/u, value) -> {:error, {tag, :whitespace_or_control}}
      Enum.any?(@template_chars, &String.contains?(value, &1)) -> {:error, {tag, :template}}
      true -> :ok
    end
  end

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}
end
