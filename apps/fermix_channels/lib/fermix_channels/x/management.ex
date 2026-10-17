defmodule FermixChannels.X.Management do
  @moduledoc """
  The provider `FermixCore.Management.X` calls for the `x.*` methods, which
  core resolves at runtime (`:x_management_provider`), so core never compiles
  against the channel. It answers atom-keyed facts; core turns them into the
  wire and owns every sentence.

    * `status/1` reads the switch from config, the pairing from its files,
      the connection and the counters from `X.Pump` while the channel runs,
      and the pairing session from `X.PairSession`. With the channel switched
      on and not running, the refusal is the one `X.Supervisor.admit/1` names,
      asked again by the same checks.
    * `pair_start/2`, `pair_get/2`, `pair_paste/3` and `pair_cancel/2` are
      `X.PairSession`'s, which runs whether or not the channel does.
    * `unpair/1` revokes the instance at Connect with a signed request, then
      deletes the record and the key, then stops the channel's subtree. A
      Connect out of reach changes nothing here; a Connect that no longer
      knows the instance has already revoked it, so this Fermix forgets it
      too. A pairing whose record or key cannot be read cannot sign that
      request, so it is forgotten here and the log says to remove the
      installation from the Connect account page.

  `opts` (all seams): `:config` (the `[fermix_channels.x]` section),
  `:pairing` (the `X.Pairing` options), `:pump` and `:session` (the servers),
  `:admit` (`X.Supervisor.admit/1`'s options), `:enrollment` (a module with
  `X.Enrollment`'s `delete_instance/3`) and `:enrollment_opts`, and
  `:subtree` (`X.Supervisor.stop_registered/1`'s options).
  """

  require Logger

  alias FermixChannels.X.Enrollment
  alias FermixChannels.X.Pairing
  alias FermixChannels.X.PairSession
  alias FermixChannels.X.Pump
  alias FermixChannels.X.Supervisor, as: XSupervisor

  @type refusal ::
          :not_paired | :pairing_invalid | :memory_disabled | :proxy_unsupported | :revoked
  @type last_failure_reason ::
          :connect_failed
          | :auth_failed
          | :connection_lost
          | :replaced
          | :rate_limited
          | :malformed
          | :restarting
          | :expired
          | :assignment_rejected
          | :turn_failed
          | :result_rejected

  @doc "The channel as it stands, with the channel off too."
  @spec status(keyword()) :: {:ok, map()}
  def status(opts \\ []) when is_list(opts) do
    enabled = Keyword.get(config(opts), :enabled, false) == true

    {:ok,
     Map.merge(runtime(enabled, opts), %{
       enabled: enabled,
       paired: paired_fact(pairing(opts)),
       pairing: PairSession.latest(session(opts))
     })}
  end

  @spec pair_start(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def pair_start(origin, opts \\ []) when is_binary(origin) and is_list(opts),
    do: PairSession.start(origin, session(opts))

  @spec pair_get(String.t(), keyword()) :: {:ok, map()} | {:error, :unknown_pairing_session}
  def pair_get(session_id, opts \\ []) when is_binary(session_id) and is_list(opts),
    do: PairSession.get(session_id, session(opts))

  @spec pair_paste(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, :unknown_pairing_session | :pairing_not_waiting}
  def pair_paste(session_id, url, opts \\ [])
      when is_binary(session_id) and is_binary(url) and is_list(opts),
      do: PairSession.paste(session_id, url, session(opts))

  @spec pair_cancel(String.t(), keyword()) :: {:ok, map()} | {:error, :unknown_pairing_session}
  def pair_cancel(session_id, opts \\ []) when is_binary(session_id) and is_list(opts),
    do: PairSession.cancel(session_id, session(opts))

  @doc "Revokes this installation at Connect and forgets its key and pairing."
  @spec unpair(keyword()) ::
          {:ok, %{instance_id: String.t()}}
          | {:error, :not_paired | :connect_unreachable | term()}
  def unpair(opts \\ []) when is_list(opts) do
    case Pairing.load(pairing(opts)) do
      {:ok, record} -> unpair_record(record, XSupervisor.paired(pairing(opts)), opts)
      {:error, :unpaired} -> {:error, :not_paired}
      {:error, {:invalid_record, reason}} -> forget_unreadable(reason, opts)
    end
  end

  # --- status ----------------------------------------------------------------

  defp runtime(enabled, opts) do
    case Pump.status(Keyword.get(opts, :pump, Pump)) do
      {:ok, pump} ->
        %{
          connection: connection_word(pump.connection),
          refusal: connection_refusal(pump.connection),
          pending: pump.pending,
          running: pump.running,
          last_failure: last_failure(pump.last_failure)
        }

      {:error, :not_running} ->
        {connection, refusal} = not_running(enabled, opts)
        %{connection: connection, refusal: refusal, pending: 0, running: 0, last_failure: nil}
    end
  end

  defp not_running(false, _opts), do: {:off, nil}

  # Switched on and not running: refused for the reason the supervisor gave
  # at its start, asked again, or simply not started yet (turned on since the
  # last start), which a restart starts.
  defp not_running(true, opts) do
    admit_opts = Keyword.merge([pairing: pairing(opts)], Keyword.get(opts, :admit, []))

    case XSupervisor.admit(admit_opts) do
      {:ok, _record} -> {:off, nil}
      {:error, reason} -> {:refused, admission_refusal(reason)}
    end
  end

  defp admission_refusal(:unpaired), do: :not_paired
  defp admission_refusal({:invalid_record, _reason}), do: :pairing_invalid
  defp admission_refusal({:instance_key, _reason}), do: :pairing_invalid
  defp admission_refusal(:memory_unavailable), do: :memory_disabled
  defp admission_refusal(:proxy_unsupported_transport), do: :proxy_unsupported

  defp connection_word({:refused, _reason}), do: :refused

  defp connection_word(connection) when connection in [:connecting, :connected, :down],
    do: connection

  # `X.Client`'s refusals, for good: `4401` revoked, `4409` replaced by another
  # socket (no refusal of its own: `last_failure` says so), or the proxy.
  defp connection_refusal({:refused, :revoked}), do: :revoked
  defp connection_refusal({:refused, :replaced}), do: nil
  defp connection_refusal({:refused, :proxy_unsupported_transport}), do: :proxy_unsupported
  defp connection_refusal(_connection), do: nil

  defp last_failure(nil), do: nil

  defp last_failure(%{at: %DateTime{} = at, reason: reason}) do
    case failure_word(reason) do
      nil -> nil
      word -> %{at: at |> DateTime.truncate(:second) |> DateTime.to_iso8601(), reason: word}
    end
  end

  @doc """
  The `x.status` word for each failure `X.Pump` records, or `nil` for an
  ending that is not a failure the owner can act on (Connect cancelled or
  suppressed the mention, or had already settled it).
  """
  @spec failure_word(term()) :: last_failure_reason() | nil
  def failure_word({:refused, :revoked}), do: :auth_failed
  def failure_word({:refused, :replaced}), do: :replaced
  def failure_word({:refused, :proxy_unsupported_transport}), do: :connect_failed
  def failure_word({:assignment_rejected, _reason}), do: :assignment_rejected
  def failure_word({:result_rejected, _reason}), do: :result_rejected
  def failure_word({:start_refused, :expired}), do: :expired

  def failure_word({:start_refused, reason})
      when reason in [
             :cancelled,
             :suppressed,
             :stale_generation,
             :unknown_assignment,
             :already_settled
           ],
      do: nil

  def failure_word({:start_failed, _reason}), do: :connection_lost

  def failure_word(reason)
      when reason in [
             :malformed_start_grant,
             :stored_assignment_unreadable,
             :turn_stopped,
             :result_too_large,
             :deadline,
             :runner_restarted
           ],
      do: :turn_failed

  def failure_word({kind, _reason})
      when kind in [
             :store_failed,
             :recovery_failed,
             :ingest_failed,
             :turn_failed,
             :reply_not_staged
           ],
      do: :turn_failed

  # The pairing as `x.status` shows it: a record whose key is this
  # installation's, with that key's fingerprint.
  defp paired_fact(pairing) do
    case XSupervisor.paired(pairing) do
      {:ok, record, public_key} ->
        %{
          instance_id: record.instance_id,
          handle: record.handle,
          fingerprint: Pairing.fingerprint(public_key),
          origin: record.origin,
          tenant_generation: record.tenant_generation,
          paired_at: record.paired_at
        }

      {:error, _unpaired_or_unusable} ->
        nil
    end
  end

  # --- unpair ----------------------------------------------------------------

  defp unpair_record(record, {:ok, _record, _public_key}, opts), do: revoke(record, opts)

  defp unpair_record(record, {:error, {:instance_key, reason}}, opts),
    do: forget_unsigned(record, reason, opts)

  defp revoke(record, opts) do
    enrollment = Keyword.get(opts, :enrollment, Enrollment)

    case enrollment.delete_instance(record.origin, record.instance_id, enrollment_opts(opts)) do
      :ok ->
        forget(record, opts)

      {:error, {:connect_refused, "unknown_instance"}} ->
        Logger.info(
          "X: Fermix Connect no longer knows instance #{record.instance_id}, so it is " <>
            "already revoked there; forgetting the pairing here"
        )

        forget(record, opts)

      {:error, {:key_unavailable, reason}} ->
        forget_unsigned(record, reason, opts)

      {:error, :connect_unreachable} ->
        {:error, :connect_unreachable}

      {:error, reason} ->
        {:error, {:unpair_refused, reason}}
    end
  end

  # An instance key that is gone, unreadable or not the record's cannot sign
  # the revocation, and nothing else can: the pairing is forgotten here.
  defp forget_unsigned(record, reason, opts) do
    Logger.warning(
      "X: instance #{record.instance_id} could not sign its unpair (#{inspect(reason)}), " <>
        "so Fermix Connect was not told; remove it from the Connect account page"
    )

    forget(record, opts)
  end

  defp forget(record, opts) do
    with :ok <- delete_files(opts) do
      :ok = XSupervisor.stop_registered(Keyword.get(opts, :subtree, []))
      Logger.info("X: unpaired instance #{record.instance_id}")
      {:ok, %{instance_id: record.instance_id}}
    end
  end

  # A record that cannot be read names no instance this Fermix could sign a
  # revocation for, so it is removed here and this Fermix is no longer paired.
  defp forget_unreadable(reason, opts) do
    Logger.warning(
      "X: the pairing record could not be read (#{inspect(reason)}), so Fermix Connect was " <>
        "not told; it is removed here. Remove the installation from the Connect account page"
    )

    with :ok <- delete_files(opts) do
      :ok = XSupervisor.stop_registered(Keyword.get(opts, :subtree, []))
      {:error, :not_paired}
    end
  end

  defp delete_files(opts) do
    case Pairing.delete(pairing(opts)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:pairing_not_deleted, reason}}
    end
  end

  # --- options ---------------------------------------------------------------

  defp config(opts),
    do: Keyword.get_lazy(opts, :config, fn -> Application.get_env(:fermix_channels, :x, []) end)

  defp pairing(opts), do: Keyword.get(opts, :pairing, [])

  defp session(opts), do: [server: Keyword.get(opts, :session, PairSession)]

  defp enrollment_opts(opts),
    do: Keyword.merge([pairing: pairing(opts)], Keyword.get(opts, :enrollment_opts, []))
end
