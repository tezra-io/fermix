defmodule FermixChannels.X.Assignment do
  @moduledoc """
  Verification of one Fermix Connect assignment (`priv/connect/PROTOCOL.md` §4),
  pure: a compact JWS, the pairing record and a clock in, the signed claims or
  the first failing reason out.

  The checks run in the contract's order, and the first that fails names the
  receipt's reason:

    1. the JWS decodes (`malformed`) and its `kid` is the record's
       `connect_key_id` (`bad_signature`);
    2. the signature verifies with the record's `connect_public_key`, the
       algorithm pinned to `EdDSA` (`bad_signature`);
    3. `protocol_version` is 1, and the claims have the contract's shape
       (`malformed`);
    4. `instance_id` and `tenant_id` are the record's (`wrong_instance`), and
       so are `tenant_generation` and `key_generation` (`stale_generation`);
    5. `expires_at` is in the future and `issued_at` at most 60 seconds ahead
       of the clock (`expired`);
    6. `request_sha256` is the SHA-256 of `request_text` (`malformed`);
    7. the context and the whole JWS are within their caps (`over_cap`).

  Nothing in the token chooses an algorithm, a key or a key URL; nothing in it
  names a policy, a tool, a path or a prompt. The X channel's execution profile
  is its own constant.
  """

  alias FermixChannels.X.Pairing

  @enforce_keys [
    :protocol_version,
    :assignment_id,
    :interaction_id,
    :tenant_id,
    :tenant_generation,
    :instance_id,
    :key_generation,
    :bot_user_id,
    :requester_x_user_id,
    :invoking_post_id,
    :conversation_id,
    :request_text,
    :request_sha256,
    :context,
    :issued_at,
    :expires_at
  ]
  defstruct @enforce_keys

  @type role :: :invoking | :parent | :ancestor | :quoted

  @type post :: %{
          id: String.t(),
          role: role(),
          author_id: String.t() | nil,
          author_handle: String.t() | nil,
          text: String.t() | nil,
          created_at: DateTime.t() | nil,
          missing?: boolean()
        }

  @type t :: %__MODULE__{
          protocol_version: 1,
          assignment_id: String.t(),
          interaction_id: String.t(),
          tenant_id: String.t(),
          tenant_generation: pos_integer(),
          instance_id: String.t(),
          key_generation: pos_integer(),
          bot_user_id: String.t(),
          requester_x_user_id: String.t(),
          invoking_post_id: String.t(),
          conversation_id: String.t(),
          request_text: String.t(),
          request_sha256: String.t(),
          context: %{posts: [post()], truncated: boolean()},
          issued_at: DateTime.t(),
          expires_at: DateTime.t()
        }

  @type reason ::
          :bad_signature
          | :wrong_instance
          | :stale_generation
          | :expired
          | :malformed
          | :over_cap

  @max_posts 8
  @max_context_chars 12_000
  @default_max_bytes 32_768
  @issued_ahead_s 60

  @opaque_id ~r/\A[A-Za-z0-9_-]{1,64}\z/
  @x_id ~r/\A[1-9][0-9]{0,19}\z/
  @handle ~r/\A@[A-Za-z0-9_]{1,15}\z/
  @sha256 ~r/\A[0-9a-f]{64}\z/
  @segment ~r/\A[A-Za-z0-9_-]+\z/
  @timestamp ~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,6})?Z\z/

  @opaque_claims ~w(assignment_id interaction_id instance_id)
  @x_id_claims ~w(tenant_id bot_user_id requester_x_user_id invoking_post_id conversation_id)
  @generation_claims ~w(tenant_generation key_generation)
  @roles %{
    "invoking" => :invoking,
    "parent" => :parent,
    "ancestor" => :ancestor,
    "quoted" => :quoted
  }

  @doc """
  Verifies `jws` against `record` at `now`. `max_bytes:` is the session's
  `max_assignment_bytes` (#{@default_max_bytes} until `ready` says otherwise).
  """
  @spec verify(String.t(), Pairing.t(), DateTime.t(), keyword()) ::
          {:ok, t()} | {:error, reason()}
  def verify(jws, %Pairing{} = record, %DateTime{} = now, opts \\ [])
      when is_binary(jws) and is_list(opts) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

    with {:ok, header, payload} <- decode_compact(jws),
         :ok <- check_kid(header, record),
         :ok <- check_signature(jws, record),
         {:ok, claims} <- decode_claims(payload),
         {:ok, assignment} <- parse(claims),
         :ok <- check_binding(assignment, record),
         :ok <- check_window(assignment, now),
         :ok <- check_request_digest(assignment) do
      check_caps(assignment, jws, max_bytes)
    end
  end

  @doc """
  The claims of a JWS this installation verified and stored, read again with
  no signature or clock check: a recovered row re-derives its turn from the
  token it was accepted as. `{:error, :malformed}` for anything else.
  """
  @spec claims(String.t()) :: {:ok, t()} | {:error, :malformed}
  def claims(jws) when is_binary(jws) do
    with {:ok, _header, payload} <- decode_compact(jws),
         {:ok, claims} <- decode_claims(payload) do
      parse(claims)
    end
  end

  @doc """
  The `assignment_id` an unverified token claims, read only to name a
  `rejected` receipt; nothing else may trust it. `:error` when it names none.
  """
  @spec peek_id(String.t()) :: {:ok, String.t()} | :error
  def peek_id(jws) when is_binary(jws) do
    with {:ok, _header, payload} <- decode_compact(jws),
         {:ok, %{"assignment_id" => id}} <- decode_claims(payload),
         true <- is_binary(id) and Regex.match?(@opaque_id, id) do
      {:ok, id}
    else
      _unnamed -> :error
    end
  end

  # --- 1. decode and kid -----------------------------------------------------

  # The token is three base64url segments whose header is a JSON object; only
  # then is it handed to JOSE, which raises on anything less.
  defp decode_compact(jws) do
    with [header_b64, payload_b64, signature_b64] <- String.split(jws, "."),
         true <- Enum.all?([header_b64, payload_b64, signature_b64], &Regex.match?(@segment, &1)),
         {:ok, _header_bytes} <- Base.url_decode64(header_b64, padding: false),
         {:ok, payload} <- Base.url_decode64(payload_b64, padding: false),
         {:ok, _signature} <- Base.url_decode64(signature_b64, padding: false),
         {:ok, header} when is_map(header) <- Jason.decode(JOSE.JWS.peek_protected(jws)) do
      {:ok, header, payload}
    else
      _malformed -> {:error, :malformed}
    end
  end

  defp check_kid(%{"kid" => kid}, %Pairing{connect_key_id: kid}), do: :ok
  defp check_kid(_header, _record), do: {:error, :bad_signature}

  # --- 2. signature ----------------------------------------------------------

  defp check_signature(jws, %Pairing{connect_public_key: encoded}) do
    with {:ok, <<_::256>> = public_key} <- Base.url_decode64(encoded, padding: false),
         jwk = JOSE.JWK.from_okp({:Ed25519, public_key}),
         {true, _payload, _jws} <- JOSE.JWS.verify_strict(jwk, ["EdDSA"], jws) do
      :ok
    else
      _unverified -> {:error, :bad_signature}
    end
  end

  # --- 3. version and shape --------------------------------------------------

  defp decode_claims(payload) do
    case Jason.decode(payload) do
      {:ok, claims} when is_map(claims) -> {:ok, claims}
      _not_an_object -> {:error, :malformed}
    end
  end

  defp parse(%{"protocol_version" => 1} = claims) do
    with :ok <- all_match(claims, @opaque_claims, @opaque_id),
         :ok <- all_match(claims, @x_id_claims, @x_id),
         :ok <- all_generations(claims),
         {:ok, request_text} <- non_empty(claims["request_text"]),
         :ok <- match(@sha256, claims["request_sha256"]),
         {:ok, issued_at} <- timestamp(claims["issued_at"]),
         {:ok, expires_at} <- timestamp(claims["expires_at"]),
         {:ok, context} <- context(claims["context"]) do
      {:ok, build(claims, request_text, issued_at, expires_at, context)}
    else
      _malformed -> {:error, :malformed}
    end
  end

  defp parse(_claims), do: {:error, :malformed}

  defp build(claims, request_text, issued_at, expires_at, context) do
    %__MODULE__{
      protocol_version: 1,
      assignment_id: claims["assignment_id"],
      interaction_id: claims["interaction_id"],
      tenant_id: claims["tenant_id"],
      tenant_generation: claims["tenant_generation"],
      instance_id: claims["instance_id"],
      key_generation: claims["key_generation"],
      bot_user_id: claims["bot_user_id"],
      requester_x_user_id: claims["requester_x_user_id"],
      invoking_post_id: claims["invoking_post_id"],
      conversation_id: claims["conversation_id"],
      request_text: request_text,
      request_sha256: claims["request_sha256"],
      context: context,
      issued_at: issued_at,
      expires_at: expires_at
    }
  end

  defp context(%{"posts" => posts, "truncated" => truncated})
       when is_list(posts) and is_boolean(truncated) do
    posts
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, acc} ->
      case post(raw) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> then(fn
      {:ok, parsed} -> {:ok, %{posts: Enum.reverse(parsed), truncated: truncated}}
      :error -> :error
    end)
  end

  defp context(_context), do: :error

  # A post Connect could not read carries `missing: true` and no text; every
  # other post carries its text, author and time.
  defp post(%{"id" => id, "role" => role, "missing" => true} = raw)
       when not is_map_key(raw, "text") do
    with :ok <- match(@x_id, id),
         {:ok, role} <- role(role),
         {:ok, author_id} <- optional(raw["author_id"], @x_id),
         {:ok, handle} <- optional(raw["author_handle"], @handle),
         {:ok, created_at} <- optional_timestamp(raw["created_at"]) do
      {:ok, post_map(id, role, author_id, handle, nil, created_at, true)}
    else
      _malformed -> :error
    end
  end

  defp post(%{"id" => id, "role" => role, "text" => text} = raw)
       when is_binary(text) and not is_map_key(raw, "missing") do
    with :ok <- match(@x_id, id),
         {:ok, role} <- role(role),
         :ok <- match(@x_id, raw["author_id"]),
         :ok <- match(@handle, raw["author_handle"]),
         {:ok, created_at} <- timestamp(raw["created_at"]) do
      {:ok, post_map(id, role, raw["author_id"], raw["author_handle"], text, created_at, false)}
    else
      _malformed -> :error
    end
  end

  defp post(_raw), do: :error

  defp post_map(id, role, author_id, handle, text, created_at, missing?) do
    %{
      id: id,
      role: role,
      author_id: author_id,
      author_handle: handle,
      text: text,
      created_at: created_at,
      missing?: missing?
    }
  end

  defp role(role) do
    case Map.fetch(@roles, role) do
      {:ok, atom} -> {:ok, atom}
      :error -> :error
    end
  end

  # --- 4. binding to this pairing --------------------------------------------

  defp check_binding(%__MODULE__{} = assignment, %Pairing{} = record) do
    cond do
      assignment.instance_id != record.instance_id -> {:error, :wrong_instance}
      assignment.tenant_id != record.tenant_id -> {:error, :wrong_instance}
      assignment.tenant_generation != record.tenant_generation -> {:error, :stale_generation}
      assignment.key_generation != record.key_generation -> {:error, :stale_generation}
      true -> :ok
    end
  end

  # --- 5. validity window ----------------------------------------------------

  defp check_window(%__MODULE__{issued_at: issued_at, expires_at: expires_at}, now) do
    latest_issue = DateTime.add(now, @issued_ahead_s, :second)

    if DateTime.compare(expires_at, now) == :gt and
         DateTime.compare(issued_at, latest_issue) != :gt,
       do: :ok,
       else: {:error, :expired}
  end

  # --- 6. request digest -----------------------------------------------------

  defp check_request_digest(%__MODULE__{request_text: text, request_sha256: claimed}) do
    digest = :sha256 |> :crypto.hash(text) |> Base.encode16(case: :lower)
    if digest == claimed, do: :ok, else: {:error, :malformed}
  end

  # --- 7. caps ---------------------------------------------------------------

  defp check_caps(%__MODULE__{context: %{posts: posts}} = assignment, jws, max_bytes) do
    chars = posts |> Enum.map(&String.length(&1.text || "")) |> Enum.sum()

    cond do
      length(posts) > @max_posts -> {:error, :over_cap}
      chars > @max_context_chars -> {:error, :over_cap}
      byte_size(jws) > max_bytes -> {:error, :over_cap}
      true -> {:ok, assignment}
    end
  end

  # --- value helpers ---------------------------------------------------------

  defp all_match(claims, names, pattern) do
    if Enum.all?(names, &(match(pattern, claims[&1]) == :ok)), do: :ok, else: :error
  end

  defp all_generations(claims) do
    if Enum.all?(@generation_claims, &(is_integer(claims[&1]) and claims[&1] > 0)),
      do: :ok,
      else: :error
  end

  defp non_empty(text) when is_binary(text) and text != "", do: {:ok, text}
  defp non_empty(_text), do: :error

  defp match(pattern, value) when is_binary(value) do
    if Regex.match?(pattern, value), do: :ok, else: :error
  end

  defp match(_pattern, _value), do: :error

  defp optional(nil, _pattern), do: {:ok, nil}

  defp optional(value, pattern) do
    with :ok <- match(pattern, value), do: {:ok, value}
  end

  defp optional_timestamp(nil), do: {:ok, nil}
  defp optional_timestamp(value), do: timestamp(value)

  defp timestamp(value) do
    with :ok <- match(@timestamp, value),
         {:ok, at, 0} <- DateTime.from_iso8601(value) do
      {:ok, at}
    else
      _invalid -> :error
    end
  end
end
