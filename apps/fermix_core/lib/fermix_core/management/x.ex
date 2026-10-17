defmodule FermixCore.Management.X do
  @moduledoc """
  The `x.*` methods: pairing this installation with Fermix Connect, unpairing
  it, and the shared X handle channel's status (M63).

  A stateless adapter, shaped like `FermixCore.Management.Mobile`. The pairing
  key, the enrollment and the connection have one owner, the X channel, and it
  lives in the channels app, which this app does not compile against. So every
  call goes by function name to the provider that app registers at
  `:x_management_provider`, and this module turns the atom-keyed facts it
  answers with into the string-keyed wire and owns every sentence on it.

  The provider contract, each function taking its options last:

    * `status/1` answers `{:ok, %{enabled, paired, connection, refusal,
      pending, running, last_failure, pairing}}`. `paired` is `nil` or
      `%{instance_id, handle, fingerprint, origin, tenant_generation,
      paired_at}`; `connection` one of `:off`, `:refused`, `:connecting`, `:connected`
      or `:down`;
      `refusal` `nil` or a refusal reason; `last_failure` `nil` or
      `%{at, reason}`; `pairing` `nil` or `%{session_id, state}`.
    * `pair_start/2` (the Connect origin) answers `{:ok, %{session: session,
      confirm_url: url}}`, `{:error, :pairing_active}`, or `{:error, reason}`
      for a start that opened nothing.
    * `pair_get/2`, `pair_paste/3` (the address a browser ended on) and
      `pair_cancel/2` answer `{:ok, session}`, `{:error,
      :unknown_pairing_session}`, or (paste) `{:error, :pairing_not_waiting}`.
    * `unpair/1` answers `{:ok, %{instance_id: id}}`, `{:error, :not_paired}`
      or `{:error, :connect_unreachable}`.

  A session is `%{session_id, state, ttl_ms, origin, handle, failure}`, with
  `handle` the X account Connect paired once `approved` (else `nil`) and
  `failure` `nil` or `%{reason: reason}`.

  Pairing has the shape of a provider sign-in: `x.pair.start` opens the
  session and answers with the authorization link, once; the pane opens it,
  the owner signs in with X and approves in the browser, and the browser
  returns to the engine's loopback, which proves the key to Connect. On a
  machine whose browser is elsewhere, `x.pair.paste` hands the engine the
  address the browser ended on. The pane reads `x.pair.get` until the session
  is terminal. A refusal that has something to tell the operator is a
  `failed` session view carrying the daemon's sentence; only a session
  already open is the `busy` envelope. A provider that is missing, or a call
  that exits, answers `unavailable` for the `x` capability, with the reason in
  the daemon log and never on the wire.
  """

  alias FermixCore.Auth.Redaction

  require Logger

  @capability "x"
  @operation "x.pair"
  @default_origin "https://connect.fermix.ai"
  # Every bound the adapter asserts rather than trusts: the authorization link,
  # the origin a client may name, and the strings a Connect answer can carry.
  @max_url_bytes 2_048
  @max_origin_bytes 256
  @max_handle_bytes 64
  # The Connect contract's own origin shape (`priv/connect/protocol.schema.json`,
  # `$defs/origin`): https, a lowercase host, an optional port, no path and no
  # trailing slash, because every signature names it byte for byte.
  @origin_pattern ~r/^https:\/\/[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*(:[0-9]{1,5})?$/
  @states ~w(awaiting_browser approved denied expired cancelled failed)a
  @connections ~w(off refused connecting connected down)a

  @refusals [
    not_paired: "The X channel is on, but this Fermix is not paired with Fermix Connect.",
    pairing_invalid: "The pairing record could not be read. Unpair and pair again.",
    memory_disabled: "The X channel keeps its work in the memory store, which is turned off.",
    proxy_unsupported:
      "The X channel cannot reach Fermix Connect through the configured proxy yet.",
    revoked: "Fermix Connect no longer accepts this Fermix. Unpair and pair again."
  ]

  @last_failures [
    connect_failed: "Fermix Connect could not be reached.",
    auth_failed: "Fermix Connect refused this Fermix's key.",
    connection_lost: "The connection to Fermix Connect was lost.",
    replaced: "Another connection for this Fermix replaced this one.",
    rate_limited: "Fermix Connect asked this Fermix to slow down.",
    malformed: "Fermix Connect closed the connection over a malformed message.",
    restarting: "Fermix Connect was restarting.",
    expired: "A mention expired before this Fermix could answer it.",
    assignment_rejected: "A mention from Fermix Connect failed verification and was refused.",
    turn_failed: "A mention could not be answered because its turn failed.",
    result_rejected: "Fermix Connect refused the reply this Fermix sent."
  ]

  # How a pairing session can fail, as `{code, sentence}`. The code is the job
  # vocabulary every failed view shares.
  @session_failures [
    connect_unreachable: {"unavailable", "Fermix Connect could not be reached. Try again later."},
    connect_refused: {"refused", "Fermix Connect would not start pairing. Try again later."},
    proof_rejected:
      {"refused", "Fermix Connect did not accept this Fermix's key. Start pairing again."},
    already_paired:
      {"refused", "This Fermix is already paired with Fermix Connect. Unpair it first."},
    unsupported_protocol:
      {"refused", "Fermix Connect does not speak this Fermix's protocol. Update Fermix."},
    key_unavailable:
      {"internal_error", "The instance key could not be created. See the daemon log."},
    record_unwritable: {"internal_error", "The pairing could not be saved. See the daemon log."},
    loopback_unavailable:
      {"internal_error",
       "Fermix could not open a local port for the browser to return to. See the daemon log."}
  ]
  @session_failure_reasons Keyword.keys(@session_failures)

  @start_sentence "Pairing could not start. See the daemon log."
  @origin_sentence "The Fermix Connect address must be an https address with a host and no path."
  @not_waiting_sentence "This pairing is no longer waiting for the browser."
  @not_paired_sentence "This Fermix is not paired with Fermix Connect."
  @unpair_unreachable_sentence "Fermix Connect could not be reached, so this Fermix is still paired. Try again later."
  @owner_only_sentence "Only the owner can pair this Fermix with Fermix Connect or unpair it, from their own app or terminal."

  @type refusal ::
          {:busy, String.t()}
          | {:unavailable, String.t()}
          | {:unavailable, String.t(), String.t()}
          | {:invalid_params, String.t(), String.t()}
          | {:unknown_pairing_session, String.t()}
  @type result :: {:ok, map()} | {:error, refusal()}

  @doc "Every operator-facing sentence this module can put on the wire."
  @spec sentences() :: [String.t()]
  def sentences do
    Keyword.values(@refusals) ++
      Keyword.values(@last_failures) ++
      Enum.map(@session_failures, fn {_reason, {_code, sentence}} -> sentence end) ++
      [
        @start_sentence,
        @origin_sentence,
        @not_waiting_sentence,
        @not_paired_sentence,
        @unpair_unreachable_sentence,
        @owner_only_sentence
      ]
  end

  @doc """
  The sentence the daemon socket's refusal of a pairing or unpairing decision
  carries when the caller is not the owner at a terminal or app of their own.
  """
  @spec owner_only_sentence() :: String.t()
  def owner_only_sentence, do: @owner_only_sentence

  @doc """
  The daemon's sentence for why the channel cannot run (`x.status`'s
  `refusal`), which readiness and Doctor name it by too.
  """
  @spec refusal_sentence(atom()) :: String.t()
  def refusal_sentence(reason) when is_atom(reason), do: Keyword.fetch!(@refusals, reason)

  @doc "The Connect origin a pairing dials when the client names none."
  @spec default_origin() :: String.t()
  def default_origin, do: @default_origin

  @doc "The shared X handle channel as it stands. Answers with the channel off, too."
  @spec status(keyword()) :: result()
  def status(opts \\ []) when is_list(opts) do
    with {:ok, reply} <- call(opts, :status, []), do: status_reply(reply)
  end

  @doc """
  Opens a pairing session with Fermix Connect at `origin` (the daemon's own
  default when `nil`) and answers with the session plus the authorization
  link, once. A refusal with a sentence is a `failed` view with no session
  behind it.
  """
  @spec pair_start(String.t() | nil, keyword()) :: result()
  def pair_start(origin, opts \\ [])
      when (is_nil(origin) or is_binary(origin)) and is_list(opts) do
    with {:ok, origin} <- validate_origin(origin || @default_origin),
         {:ok, reply} <- call(opts, :pair_start, [origin]) do
      start_reply(reply, origin)
    end
  end

  @doc "One pairing session as it stands."
  @spec pair_get(String.t(), keyword()) :: result()
  def pair_get(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    with {:ok, reply} <- call(opts, :pair_get, [session_id]),
         do: session_reply(:pair_get, session_id, reply)
  end

  @doc """
  Hands one waiting session the address a browser elsewhere ended on, which
  the engine reads as its loopback reads a callback, and answers the session
  as it stands.
  """
  @spec pair_paste(String.t(), String.t(), keyword()) :: result()
  def pair_paste(session_id, url, opts \\ [])
      when is_binary(session_id) and is_binary(url) and is_list(opts) do
    with {:ok, reply} <- call(opts, :pair_paste, [session_id, url]),
         do: session_reply(:pair_paste, session_id, reply)
  end

  @doc "Closes one pairing session. A finished session answers as it is."
  @spec pair_cancel(String.t(), keyword()) :: result()
  def pair_cancel(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    with {:ok, reply} <- call(opts, :pair_cancel, [session_id]),
         do: session_reply(:pair_cancel, session_id, reply)
  end

  @doc "Revokes this installation at Connect and forgets its key and pairing."
  @spec unpair(keyword()) :: result()
  def unpair(opts \\ []) when is_list(opts) do
    with {:ok, reply} <- call(opts, :unpair, []), do: unpair_reply(reply)
  end

  # A pairing record is valid for exactly one origin, the scheme and host every
  # signature names, so anything a signature could not name is refused here
  # rather than dialed.
  defp validate_origin(origin) do
    if byte_size(origin) <= @max_origin_bytes and Regex.match?(@origin_pattern, origin),
      do: {:ok, origin},
      else: {:error, {:invalid_params, "origin", @origin_sentence}}
  end

  # One call to the provider, by name, with the remaining options as the
  # provider's own seams. A provider nobody registered, or one without the
  # function, is the capability being absent rather than a crash.
  defp call(opts, function, args) do
    {provider, provider_opts} = Keyword.pop(opts, :provider, registered_provider())
    args = args ++ [provider_opts]

    if callable?(provider, function, length(args)) do
      invoke(provider, function, args)
    else
      Logger.warning("management x: no provider serves #{function}/#{length(args)}")
      {:error, {:unavailable, @capability}}
    end
  end

  defp registered_provider, do: Application.get_env(:fermix_core, :x_management_provider)

  defp callable?(provider, function, arity) when is_atom(provider) and not is_nil(provider),
    do: Code.ensure_loaded?(provider) and function_exported?(provider, function, arity)

  defp callable?(_provider, _function, _arity), do: false

  # The channel is a process tree in another app, so a call into it can exit.
  # The reason names that app's internals and stays in the log.
  defp invoke(provider, function, args) do
    {:ok, apply(provider, function, args)}
  catch
    :exit, reason ->
      Logger.error("management x: #{function} exited: #{Redaction.format(reason)}")
      {:error, {:unavailable, @capability}}
  end

  defp status_reply({:ok, status}) when is_map(status), do: {:ok, status_view(status)}
  defp status_reply(reply), do: unexpected(:status, reply)

  defp start_reply({:ok, %{session: session, confirm_url: url}}, _origin)
       when is_map(session) and is_binary(url) and byte_size(url) <= @max_url_bytes,
       do: {:ok, Map.put(session_view(session), "confirm_url", url)}

  defp start_reply({:error, :pairing_active}, _origin), do: {:error, {:busy, @operation}}

  defp start_reply({:error, reason}, origin) when reason in @session_failure_reasons,
    do: failed_start(origin, Keyword.fetch!(@session_failures, reason))

  defp start_reply({:error, reason}, origin) do
    Logger.error("management x: the pairing session refused: #{Redaction.format(reason)}")
    failed_start(origin, {"internal_error", @start_sentence})
  end

  # A success reply carries the authorization link, which is never logged.
  defp start_reply(_reply, _origin) do
    Logger.error("management x: pair_start answered a shape this daemon does not publish")
    {:error, {:unavailable, @capability}}
  end

  defp session_reply(_function, _session_id, {:ok, session}) when is_map(session),
    do: {:ok, session_view(session)}

  defp session_reply(_function, session_id, {:error, :unknown_pairing_session}),
    do: {:error, {:unknown_pairing_session, session_id}}

  defp session_reply(_function, _session_id, {:error, :pairing_not_waiting}),
    do: {:error, {:invalid_params, "session_id", @not_waiting_sentence}}

  defp session_reply(function, _session_id, reply), do: unexpected(function, reply)

  defp unpair_reply({:ok, %{instance_id: instance_id}}) when is_binary(instance_id),
    do: {:ok, %{"instance_id" => instance_id, "unpaired" => true}}

  defp unpair_reply({:error, :not_paired}),
    do: {:error, {:unavailable, @capability, @not_paired_sentence}}

  defp unpair_reply({:error, :connect_unreachable}),
    do: {:error, {:unavailable, @capability, @unpair_unreachable_sentence}}

  defp unpair_reply(reply), do: unexpected(:unpair, reply)

  # A refusal the contract does not name is a defect between the two apps. The
  # reason is logged; a reply that is not a refusal can carry a handle or a
  # link, so only the fact that it was unexpected is.
  defp unexpected(function, {:error, reason}) do
    Logger.error("management x: #{function} refused: #{Redaction.format(reason)}")
    {:error, {:unavailable, @capability}}
  end

  defp unexpected(function, _reply) do
    Logger.error("management x: #{function} answered a shape this daemon does not publish")
    {:error, {:unavailable, @capability}}
  end

  # Nothing was opened, so there is no session to poll and no link to show.
  defp failed_start(origin, {code, sentence}) do
    {:ok,
     %{
       "session_id" => nil,
       "state" => "failed",
       "ttl_ms" => nil,
       "origin" => origin,
       "handle" => nil,
       "failure" => failure(code, sentence),
       "confirm_url" => nil
     }}
  end

  defp session_view(session) do
    %{
      "session_id" => session.session_id,
      "state" => state_word(session.state),
      "ttl_ms" => session.ttl_ms,
      "origin" => session.origin,
      "handle" => handle_view(session.handle),
      "failure" => failure_view(session.failure)
    }
  end

  defp state_word(state) when state in @states, do: Atom.to_string(state)

  defp handle_view(nil), do: nil

  defp handle_view(handle) when is_binary(handle) and byte_size(handle) <= @max_handle_bytes,
    do: handle

  defp failure_view(nil), do: nil

  defp failure_view(%{reason: reason}) when reason in @session_failure_reasons do
    {code, sentence} = Keyword.fetch!(@session_failures, reason)
    failure(code, sentence)
  end

  defp failure(code, sentence), do: %{"code" => code, "sentence" => sentence}

  defp status_view(status) do
    %{
      "enabled" => status.enabled,
      "paired" => paired_view(status.paired),
      "connection" => connection_word(status.connection),
      "refusal" => refusal_view(status.refusal),
      "pending" => count(status.pending),
      "running" => count(status.running),
      "last_failure" => last_failure_view(status.last_failure),
      "pairing" => pairing_view(status.pairing)
    }
  end

  defp paired_view(nil), do: nil

  defp paired_view(paired) when is_map(paired) do
    %{
      "instance_id" => paired.instance_id,
      "handle" => paired.handle,
      "fingerprint" => paired.fingerprint,
      "origin" => paired.origin,
      "tenant_generation" => paired.tenant_generation,
      "paired_at" => paired.paired_at
    }
  end

  defp connection_word(connection) when connection in @connections,
    do: Atom.to_string(connection)

  defp refusal_view(nil), do: nil

  defp refusal_view(reason) when is_atom(reason),
    do: %{"reason" => Atom.to_string(reason), "sentence" => Keyword.fetch!(@refusals, reason)}

  defp last_failure_view(nil), do: nil

  defp last_failure_view(%{at: at, reason: reason}) when is_binary(at) and is_atom(reason),
    do: %{"at" => at, "sentence" => Keyword.fetch!(@last_failures, reason)}

  defp count(value) when is_integer(value) and value >= 0, do: value

  defp pairing_view(nil), do: nil

  defp pairing_view(%{session_id: session_id, state: state}) when is_binary(session_id),
    do: %{"session_id" => session_id, "state" => state_word(state)}
end
