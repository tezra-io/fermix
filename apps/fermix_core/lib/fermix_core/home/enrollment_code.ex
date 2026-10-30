defmodule FermixCore.Home.EnrollmentCode do
  @moduledoc """
  The enrollment code a primary opens for a candidate primary (M75 §7.1):

      fxenroll1.<base64url(JSON)>

  The JSON is `{"v": 1, "secret", "gateway_pk", "node_id", "relays",
  "relays_rev", "name", "expires_at"}`: the window's 32-byte secret and the
  primary's X25519 gateway key (standard base64 with padding, as the mobile
  wire carries keys), its iroh endpoint id (64 lowercase hex digits), the
  relays it listens on (1 to 8, in the wire's `{url, quic_port}` shape) and
  their revision, the name a person knows it by (at most 128 bytes of
  printable text) and when the window closes (UTC, ISO 8601). The base64url
  part has no padding.

  The secret is the PSK of the enrollment handshake (`FXM1 0x03`, `IKpsk2`),
  so the code is shown once and never logged. A whole code is at most
  #{2_048} characters, the bound the first-boot script and the CloudFormation
  template hold it to. `decode/1` trims surrounding whitespace, since a file
  written with `printf '%s\\n'` ends in a newline.

  Pure.
  """

  @prefix "fxenroll1."
  @version 1
  @max_code_bytes 2_048
  @max_name_bytes 128
  @max_relays 8
  @node_id ~r/\A[0-9a-f]{64}\z/
  @relays_rev ~r/\A[0-9a-f]{16}\z/
  @relay_url ~r/\Ahttps:\/\/[a-z0-9]([a-z0-9.-]*[a-z0-9])?\/\z/
  @controls ~r/[\x{0000}-\x{001F}\x{007F}-\x{009F}]/u

  @typedoc "A relay in the mobile wire's shape."
  @type relay :: %{required(String.t()) => String.t() | pos_integer()}

  @typedoc "What a code carries."
  @type t :: %{
          secret: <<_::256>>,
          gateway_pk: <<_::256>>,
          node_id: String.t(),
          relays: [relay(), ...],
          relays_rev: String.t(),
          name: String.t(),
          expires_at: DateTime.t()
        }

  @doc "The longest code there is, in characters."
  @spec max_code_bytes() :: pos_integer()
  def max_code_bytes, do: @max_code_bytes

  @doc """
  The code for `facts`: `{:ok, code}`, or `{:error, {:invalid_code, field}}`
  for a fact out of its bounds and `{:error, :code_too_long}` past
  #{@max_code_bytes} characters.
  """
  @spec encode(t()) :: {:ok, String.t()} | {:error, {:invalid_code, String.t()} | :code_too_long}
  def encode(%{expires_at: %DateTime{} = expires_at} = facts) do
    json =
      Jason.encode!(%{
        "v" => @version,
        "secret" => Base.encode64(Map.fetch!(facts, :secret)),
        "gateway_pk" => Base.encode64(Map.fetch!(facts, :gateway_pk)),
        "node_id" => Map.fetch!(facts, :node_id),
        "relays" => Map.fetch!(facts, :relays),
        "relays_rev" => Map.fetch!(facts, :relays_rev),
        "name" => Map.fetch!(facts, :name),
        "expires_at" => expires_at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      })

    code = @prefix <> Base.url_encode64(json, padding: false)

    with :ok <- within_bound(code),
         {:ok, _facts} <- decode(code),
         do: {:ok, code}
  end

  defp within_bound(code) when byte_size(code) <= @max_code_bytes, do: :ok
  defp within_bound(_code), do: {:error, :code_too_long}

  @doc """
  The facts a code carries, or `{:error, {:invalid_code, what}}` naming the
  first thing that is not as `encode/1` writes it. Never echoes the code.
  """
  @spec decode(term()) :: {:ok, t()} | {:error, {:invalid_code, String.t()}}
  def decode(text) when is_binary(text) do
    with {:ok, body} <- body(String.trim(text)),
         {:ok, json} <- base64url(body),
         {:ok, map} <- json_object(json),
         :ok <- version(map) do
      fields(map)
    end
  end

  def decode(_text), do: invalid("code")

  defp body(@prefix <> body) when byte_size(body) > 0 and byte_size(body) <= @max_code_bytes,
    do: {:ok, body}

  defp body(_text), do: invalid("prefix")

  defp base64url(body) do
    case Base.url_decode64(body, padding: false) do
      {:ok, json} -> {:ok, json}
      :error -> invalid("base64url")
    end
  end

  defp json_object(json) do
    case Jason.decode(json) do
      {:ok, %{} = map} -> {:ok, map}
      _other -> invalid("json")
    end
  end

  defp version(%{"v" => @version}), do: :ok
  defp version(_map), do: invalid("v")

  defp fields(map) do
    with {:ok, secret} <- key(map, "secret"),
         {:ok, gateway_pk} <- key(map, "gateway_pk"),
         {:ok, node_id} <- matching(map, "node_id", @node_id),
         {:ok, relays} <- relays(map),
         {:ok, rev} <- matching(map, "relays_rev", @relays_rev),
         {:ok, name} <- name(map),
         {:ok, expires_at} <- expires_at(map) do
      {:ok,
       %{
         secret: secret,
         gateway_pk: gateway_pk,
         node_id: node_id,
         relays: relays,
         relays_rev: rev,
         name: name,
         expires_at: expires_at
       }}
    end
  end

  defp key(map, field) do
    with value when is_binary(value) <- Map.get(map, field),
         {:ok, <<_::256>> = key} <- Base.decode64(value) do
      {:ok, key}
    else
      _other -> invalid(field)
    end
  end

  defp matching(map, field, regex) do
    case Map.get(map, field) do
      value when is_binary(value) ->
        if Regex.match?(regex, value), do: {:ok, value}, else: invalid(field)

      _other ->
        invalid(field)
    end
  end

  defp relays(%{"relays" => relays}) when is_list(relays) and relays != [] do
    if length(relays) <= @max_relays and Enum.all?(relays, &relay?/1),
      do: {:ok, Enum.map(relays, &Map.take(&1, ["url", "quic_port"]))},
      else: invalid("relays")
  end

  defp relays(_map), do: invalid("relays")

  defp relay?(%{"url" => url, "quic_port" => port}) when is_binary(url) and is_integer(port),
    do: Regex.match?(@relay_url, url) and port in 1..65_535

  defp relay?(_relay), do: false

  defp name(%{"name" => name}) when is_binary(name) do
    if printable?(name), do: {:ok, name}, else: invalid("name")
  end

  defp name(_map), do: invalid("name")

  defp expires_at(%{"expires_at" => text}) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> {:ok, at}
      {:error, _reason} -> invalid("expires_at")
    end
  end

  defp expires_at(_map), do: invalid("expires_at")

  @doc "Whether `name` is text a person reads: valid UTF-8, no control characters, 1 to 128 bytes."
  @spec printable?(term()) :: boolean()
  def printable?(name) when is_binary(name),
    do:
      byte_size(name) in 1..@max_name_bytes and String.valid?(name) and
        not Regex.match?(@controls, name)

  def printable?(_name), do: false

  defp invalid(what), do: {:error, {:invalid_code, what}}
end
