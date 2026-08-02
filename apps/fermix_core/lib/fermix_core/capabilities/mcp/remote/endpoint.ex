defmodule FermixCore.Capabilities.MCP.Remote.Endpoint do
  @moduledoc """
  The validated remote MCP endpoint (M27 §7.2 rules 4-7, §7.4).

  An endpoint comes from a **signed plugin manifest** and nowhere else — not
  user config, not the environment, not a redirect. This module is the single
  place that decides whether a manifest's `base_url`/`mcp_path` pair is a legal
  target, and the single place that turns a signed hostname into a validated
  peer address.

  Validation is deliberately narrow. Remote MCP is not an arbitrary
  remote-proxy configuration surface: an origin with a path, query, fragment,
  userinfo, template, wildcard, or IP literal is refused outright rather than
  normalized into something safe-looking.

  `resolve/2` returns the peer the caller must connect to. Callers connect to
  that address while presenting the **signed hostname** for the `Host` header,
  TLS SNI, and certificate verification — validating a name and then letting
  the socket layer resolve it again is not a gate (the resolver could answer
  differently the second time).
  """

  alias FermixCore.Net.Guard

  @type t :: %__MODULE__{
          host: String.t(),
          port: pos_integer(),
          path: String.t()
        }

  @enforce_keys [:host, :port, :path]
  defstruct [:host, :port, :path]

  @default_port 443

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
      {:ok, %__MODULE__{host: host, port: port, path: mcp_path}}
    end
  end

  def new(base_url, mcp_path), do: {:error, {:invalid_endpoint, base_url, mcp_path}}

  @doc """
  The absolute request URI. Contains no credential — the bearer rides in a
  header the transport process builds, never in the target.
  """
  @spec uri(t()) :: String.t()
  def uri(%__MODULE__{} = endpoint), do: origin(endpoint) <> endpoint.path

  @doc "The scheme/host/port origin, for status text and error classes."
  @spec origin(t()) :: String.t()
  def origin(%__MODULE__{host: host, port: @default_port}), do: "https://" <> host
  def origin(%__MODULE__{host: host, port: port}), do: "https://#{host}:#{port}"

  @doc """
  Resolve the signed hostname to one globally-routable peer address.

  Every A and AAAA answer must be globally routable; `Net.Guard` refuses the
  whole set if any answer is not, so Fermix never picks a convenient public
  answer out of a mixed reply. Callers must re-run this before every new
  connection — a cached peer is a cached DNS decision.
  """
  @spec resolve(t(), keyword()) :: {:ok, :inet.ip_address()} | {:error, term()}
  def resolve(%__MODULE__{} = endpoint, opts \\ []) when is_list(opts) do
    case Guard.resolve_and_validate(uri(endpoint), opts) do
      {:ok, ip} -> {:ok, ip}
      # An IP-literal host is refused at `new/2`, so the guard's `:ok`
      # (nothing to pin) is unreachable here; treat it as the invariant
      # violation it would be rather than connecting unpinned.
      :ok -> {:error, {:remote_security_blocked, :endpoint_not_pinnable}}
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
      {:ok, host, uri.port || @default_port}
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
