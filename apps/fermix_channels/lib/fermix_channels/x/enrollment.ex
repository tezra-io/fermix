defmodule FermixChannels.X.Enrollment do
  @moduledoc """
  The enrollment calls of the Fermix Connect contract
  (`priv/connect/PROTOCOL.md` §2), over HTTPS: open an enrollment for this
  installation's key, prove the key with the authorization code the owner's
  browser delivered (§2.2), and revoke the instance on unpair with a signed
  request (§2.4). The browser step between the first two is
  `X.PairSession`'s; nothing here reads an enrollment back.

  `origin` is the scheme, host and optional port the installation dials, with
  no path and no trailing slash (`X.Pairing.origin?/1`). It is exactly the
  string every signature names and the pairing record stores, so anything
  else is refused before a byte is sent (`ArgumentError`), as is an id, a
  code or a verifier that is not the contract's shape. Every call goes
  through `Net.HttpClient`, so the egress route and the shared pools' TLS
  posture are the daemon's own. Nothing follows a redirect, because the
  origin is the audience every signature names, and nothing is retried here:
  the code is single-use, so a refused proof ends the pairing session.

  Errors are typed:

    * `:connect_unreachable`: no answer from Connect, which is a transport
      failure, or a 5xx whose body is not the contract's error (a proxy or a
      load balancer in front of a Connect that is down);
    * `{:connect_refused, code}`: Connect answered with the contract's error
      body, and `code` is its `code`;
    * `:unsupported_protocol`: Connect named the protocol version as one it
      does not speak (`unsupported_version`), or answered in a shape that is
      not the contract's;
    * `{:key_unavailable, reason}`: the instance key could not be read to
      publish or sign with.

  `opts`: `:pairing` (the `X.Pairing` options, `root:` in tests),
  `:req_options` (merged into every request, `plug:` in tests), `:egress`,
  and `:clock` (the signed request's timestamp).
  """

  require Logger

  alias FermixChannels.X.Pairing
  alias FermixCore.Net.Egress
  alias FermixCore.Net.HttpClient

  @protocol_version 1
  @receive_timeout_ms 15_000
  # The pairing session appends the authorization request (under 300 bytes)
  # to this link, and the whole link stays within the management export's
  # 2,048-byte `confirm_url`.
  @max_confirm_url_bytes 1_024
  # Connect counts a label in graphemes after trimming and refuses control
  # characters; the schema bounds it in code points. A label kept within 64
  # code points is within both.
  @max_label_codepoints 64
  @default_label "Fermix"
  @label_control ~r/[\x{0000}-\x{001F}\x{007F}-\x{009F}\x{2028}\x{2029}]/u

  # The contract's own patterns (protocol.schema.json `$defs`).
  @opaque_id ~r/\A[A-Za-z0-9_-]{1,64}\z/
  @x_id ~r/\A[1-9][0-9]{0,19}\z/
  @handle ~r/\A@[A-Za-z0-9_]{1,15}\z/
  @public_key ~r/\A[A-Za-z0-9_-]{43}\z/
  @authorization_code ~r/\A[A-Za-z0-9_-]{43}\z/
  @code_verifier ~r/\A[A-Za-z0-9._~-]{43,128}\z/
  @confirm_token ~r/\A[A-Za-z0-9_-]+\z/
  @error_code ~r/\A[a-z][a-z0-9_]*\z/
  @timestamp ~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,6})?Z\z/

  @proof_fields [
    {"instance_id", :instance_id},
    {"tenant_id", :tenant_id},
    {"handle", :handle},
    {"key_generation", :key_generation},
    {"tenant_generation", :tenant_generation},
    {"connect_key_id", :connect_key_id},
    {"connect_public_key", :connect_public_key}
  ]

  @type error ::
          :connect_unreachable
          | {:connect_refused, String.t()}
          | :unsupported_protocol
          | {:key_unavailable, term()}
  @type created :: %{enrollment_id: String.t(), confirm_url: String.t(), expires_at: DateTime.t()}
  @type proof :: %{
          instance_id: String.t(),
          tenant_id: String.t(),
          handle: String.t(),
          key_generation: pos_integer(),
          tenant_generation: pos_integer(),
          connect_key_id: String.t(),
          connect_public_key: String.t()
        }

  @doc """
  The label an installation enrolls with, made from any text (the host name):
  control characters removed, trimmed, and kept within the contract's bound.
  Blank text is `"#{@default_label}"`.
  """
  @spec label(String.t()) :: String.t()
  def label(text) when is_binary(text) do
    text
    |> String.replace_invalid("")
    |> String.replace(@label_control, "")
    |> String.trim()
    |> within_bound()
    |> String.trim()
    |> case do
      "" -> @default_label
      label -> label
    end
  end

  @doc "Whether `label` is one `create/3` sends as it is."
  @spec label?(term()) :: boolean()
  def label?(label) when is_binary(label), do: String.valid?(label) and label(label) == label
  def label?(_label), do: false

  @doc """
  Whether `code` is the contract's authorization code (§2.1): 43 characters
  of base64url. A code the browser delivered in any other shape is not one
  Connect minted, and `prove/5` refuses it.
  """
  @spec code?(term()) :: boolean()
  def code?(code), do: matches?(@authorization_code, code)

  @doc """
  `POST /v1/enrollments`: publishes this installation's public key under
  `label` and answers the enrollment, its expiry, and the one-use
  confirmation link, which is `<origin>/confirm/<token>` with no query.
  """
  @spec create(String.t(), String.t(), keyword()) :: {:ok, created()} | {:error, error()}
  def create(origin, label, opts \\ []) when is_binary(label) and is_list(opts) do
    origin = origin!(origin)
    unless label?(label), do: raise(ArgumentError, "not an enrollment label: #{inspect(label)}")

    with {:ok, public_key} <- public_key(opts) do
      body = %{
        "protocol_version" => @protocol_version,
        "public_key" => encode(public_key),
        "key_id" => Pairing.key_id(public_key),
        "label" => label
      }

      origin
      |> request(:post, "/v1/enrollments", [json: body], opts)
      |> answer(201, &created(&1, origin))
    end
  end

  @doc """
  `POST /v1/enrollments/{enrollment_id}/prove` (§2.2): sends the code the
  browser delivered, the verifier it was minted against, and the instance
  key's signature over `fermix-connect-enroll|<origin>|<enrollment_id>|<code>`,
  and answers what the pairing record is made of.
  """
  @spec prove(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, proof()} | {:error, error()}
  def prove(origin, enrollment_id, code, code_verifier, opts \\ []) when is_list(opts) do
    origin = origin!(origin)
    id = shape!(@opaque_id, enrollment_id, "enrollment id")
    code = shape!(@authorization_code, code, "authorization code")
    verifier = shape!(@code_verifier, code_verifier, "code verifier")

    with {:ok, signature} <- sign(enroll_message(origin, id, code), opts) do
      body = %{"code" => code, "code_verifier" => verifier, "signature" => signature}

      origin
      |> request(:post, "/v1/enrollments/#{id}/prove", [json: body], opts)
      |> answer(200, &proof/1)
    end
  end

  @doc """
  `DELETE /v1/instances/{instance_id}`, signed (§2.4): revokes the instance at
  Connect, which cancels its pending assignments and closes its socket.
  """
  @spec delete_instance(String.t(), String.t(), keyword()) :: :ok | {:error, error()}
  def delete_instance(origin, instance_id, opts \\ []) when is_list(opts) do
    origin = origin!(origin)
    id = shape!(@opaque_id, instance_id, "instance id")
    path = "/v1/instances/" <> id

    with {:ok, headers} <- signed_headers(origin, id, path, opts),
         {:ok, :revoked} <-
           origin |> request(:delete, path, [headers: headers], opts) |> answer(204, &revoked/1) do
      :ok
    end
  end

  @doc "What an enrollment proof signs (§2.2)."
  @spec enroll_message(String.t(), String.t(), String.t()) :: String.t()
  def enroll_message(origin, enrollment_id, code)
      when is_binary(origin) and is_binary(enrollment_id) and is_binary(code),
      do: Enum.join(["fermix-connect-enroll", origin, enrollment_id, code], "|")

  @doc "What a signed HTTPS request signs (§2.4)."
  @spec request_message(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def request_message(origin, method, path, timestamp)
      when is_binary(origin) and is_binary(method) and is_binary(path) and is_binary(timestamp),
      do: Enum.join(["fermix-connect-request", origin, method, path, timestamp], "|")

  # --- requests --------------------------------------------------------------

  defp request(origin, method, path, request_opts, opts) do
    [
      method: method,
      url: origin <> path,
      headers: [{"accept", "application/json"}],
      redirect: false,
      retry: false,
      receive_timeout: @receive_timeout_ms
    ]
    |> Keyword.merge(request_opts, &merge_headers/3)
    |> Req.new()
    |> Req.merge(Keyword.get(opts, :req_options, []))
    |> HttpClient.request("Fermix Connect #{method_name(method)}", egress(opts))
  end

  defp merge_headers(:headers, base, extra), do: base ++ extra
  defp merge_headers(_key, _base, value), do: value

  defp method_name(method), do: method |> Atom.to_string() |> String.upcase()

  defp egress(opts), do: Keyword.get_lazy(opts, :egress, &Egress.active/0)

  defp signed_headers(origin, instance_id, path, opts) do
    timestamp = opts |> clock() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    with {:ok, public_key} <- public_key(opts),
         {:ok, signature} <- sign(request_message(origin, "DELETE", path, timestamp), opts) do
      {:ok,
       [
         {"x-fermix-instance", instance_id},
         {"x-fermix-key-id", Pairing.key_id(public_key)},
         {"x-fermix-timestamp", timestamp},
         {"x-fermix-signature", signature}
       ]}
    end
  end

  defp clock(opts), do: Keyword.get(opts, :clock, &DateTime.utc_now/0).()

  defp public_key(opts) do
    case Pairing.public_key(Keyword.get(opts, :pairing, [])) do
      {:ok, public_key} -> {:ok, public_key}
      {:error, reason} -> {:error, {:key_unavailable, reason}}
    end
  end

  defp sign(message, opts) do
    case Pairing.sign(message, Keyword.get(opts, :pairing, [])) do
      {:ok, signature} -> {:ok, encode(signature)}
      {:error, reason} -> {:error, {:key_unavailable, reason}}
    end
  end

  # --- answers ---------------------------------------------------------------

  defp answer({:ok, %Req.Response{status: status, body: body}}, status, parse) do
    case parse.(body) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        Logger.warning(
          "X: Fermix Connect answered #{status} in a shape the contract does not name"
        )

        {:error, :unsupported_protocol}
    end
  end

  defp answer({:ok, %Req.Response{status: status, body: body}}, _expected, _parse),
    do: refusal(status, body)

  defp answer({:error, exception}, _expected, _parse) do
    Logger.warning("X: Fermix Connect could not be reached: #{Exception.message(exception)}")
    {:error, :connect_unreachable}
  end

  defp refusal(status, %{"error" => %{"code" => "unsupported_version"}}) do
    Logger.warning("X: Fermix Connect does not speak protocol #{@protocol_version} (#{status})")
    {:error, :unsupported_protocol}
  end

  defp refusal(status, %{"error" => %{"code" => code, "sentence" => sentence}})
       when is_binary(code) and is_binary(sentence) do
    if Regex.match?(@error_code, code) do
      Logger.warning("X: Fermix Connect refused the request (#{status} #{code})")
      {:error, {:connect_refused, code}}
    else
      refusal(status, nil)
    end
  end

  defp refusal(status, _body) when status >= 500 do
    Logger.warning("X: Fermix Connect answered #{status} without the contract's error body")
    {:error, :connect_unreachable}
  end

  defp refusal(status, _body) do
    Logger.warning("X: Fermix Connect answered #{status}, which the contract does not name")
    {:error, :unsupported_protocol}
  end

  # An open answer (§7): a field the contract adds is ignored.
  defp created(%{"enrollment_id" => id, "confirm_url" => url, "expires_at" => expires_at}, origin) do
    with true <- matches?(@opaque_id, id) and confirm_url?(url, origin),
         {:ok, expires_at} <- timestamp(expires_at) do
      {:ok, %{enrollment_id: id, confirm_url: url, expires_at: expires_at}}
    else
      _invalid -> :error
    end
  end

  defp created(_body, _origin), do: :error

  # `<origin>/confirm/<token>` with no query and no fragment, on the origin
  # this installation dialed: the pairing session appends the authorization
  # request to it, and a link on another host is not Connect's.
  defp confirm_url?(url, origin) when is_binary(url) do
    prefix = origin <> "/confirm/"
    token = String.replace_prefix(url, prefix, "")

    byte_size(url) <= @max_confirm_url_bytes and token != url and
      matches?(@confirm_token, token)
  end

  defp confirm_url?(_url, _origin), do: false

  # The proof answer seeds the pairing record, so it is closed: a field the
  # contract does not name is a new protocol version, never ignored.
  defp proof(%{} = body) do
    names = Enum.map(@proof_fields, &elem(&1, 0))

    if Enum.sort(Map.keys(body)) == Enum.sort(names) and proof_valid?(body),
      do: {:ok, Map.new(@proof_fields, fn {name, key} -> {key, Map.fetch!(body, name)} end)},
      else: :error
  end

  defp proof(_body), do: :error

  defp proof_valid?(body) do
    matches?(@opaque_id, body["instance_id"]) and matches?(@x_id, body["tenant_id"]) and
      matches?(@handle, body["handle"]) and generation?(body["key_generation"]) and
      generation?(body["tenant_generation"]) and matches?(@opaque_id, body["connect_key_id"]) and
      public_key?(body["connect_public_key"])
  end

  defp revoked(_body), do: {:ok, :revoked}

  # --- values ----------------------------------------------------------------

  defp origin!(origin) do
    if Pairing.origin?(origin),
      do: origin,
      else: raise(ArgumentError, "not a Fermix Connect origin: #{inspect(origin)}")
  end

  defp shape!(pattern, value, name) do
    if matches?(pattern, value),
      do: value,
      else: raise(ArgumentError, "not a #{name}: #{inspect(value)}")
  end

  defp matches?(pattern, value) when is_binary(value), do: Regex.match?(pattern, value)
  defp matches?(_pattern, _value), do: false

  defp generation?(value), do: is_integer(value) and value > 0

  defp public_key?(value) do
    matches?(@public_key, value) and match?({:ok, <<_::256>>}, decode(value))
  end

  defp timestamp(value) when is_binary(value) do
    with true <- Regex.match?(@timestamp, value),
         {:ok, at, 0} <- DateTime.from_iso8601(value) do
      {:ok, at}
    else
      _invalid -> :error
    end
  end

  defp timestamp(_value), do: :error

  defp within_bound(label) do
    label
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn grapheme, {kept, count} ->
      size = length(String.codepoints(grapheme))

      if count + size <= @max_label_codepoints,
        do: {:cont, {[grapheme | kept], count + size}},
        else: {:halt, {kept, count}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join()
  end

  defp encode(bytes), do: Base.url_encode64(bytes, padding: false)
  defp decode(text), do: Base.url_decode64(text, padding: false)
end
