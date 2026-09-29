defmodule FermixChannels.Gateway.Commands.Sandbox do
  @moduledoc false

  @behaviour FermixChannels.Gateway.Command

  require Logger

  alias FermixChannels.Gateway
  alias FermixChannels.Gateway.ChannelRegistry
  alias FermixChannels.Gateway.Commands.Authorization
  alias FermixChannels.Gateway.Commands.Sandbox.Confirmations
  alias FermixChannels.Gateway.Message
  alias FermixCore.Capabilities.AccessGate
  alias FermixCore.Harness.Ledger
  alias FermixCore.Sandbox.Config
  alias FermixCore.Sandbox.ConfigMutation
  alias FermixCore.Sandbox.Mode

  @ttl_ms 60_000

  # What the owner is told when a confirmed access-sensitive run crashed.
  @access_outcome_unknown "Confirmed, but the command failed before it reported, so whether it " <>
                            "reached the device is unknown. Check it before sending it again."

  @typedoc "Where an agent-initiated grant request came from — binds the pending record to the owner's conversation."
  @type grant_origin :: %{
          optional(:ingress_context) => map(),
          channel: String.t(),
          chat_id: String.t(),
          thread_ts: term(),
          user_id: String.t() | nil,
          resume: grant_resume() | nil
        }

  @typedoc "Enough of the original inbound message to faithfully re-ingest it after the grant is confirmed."
  @type grant_resume :: %{content: String.t(), reply_target: String.t(), sender: String.t()}

  @typedoc """
  What core passes to the injected approval closure: a directory grant from the
  `request_directory_access` tool, a coding run's vendor-config change for the
  owner to acknowledge before the next harness launch (GAP3-1), or an
  access-sensitive plugin command parked by `Capabilities.AccessGate` (its
  intent id; the call itself stays in core).
  """
  @type grant_request ::
          %{path: String.t(), reason: String.t(), diff: String.t()}
          | %{acknowledge_vendor_config: String.t()}
          | %{access_sensitive: String.t()}

  @impl true
  def name, do: "sandbox"

  @impl true
  def aliases, do: ["grant", "revoke", "confirm", "deny"]

  @impl true
  def description, do: "Inspect or update sandbox policy."

  # Directory-grant subcommands demand strict operator role. The
  # `command_allowlist` (which admits a trusted guest for /new, /compact) must
  # never reach sandbox mutation: a guest's own /grant binds the pending record
  # to their origin, so `same_origin?` would otherwise let them self-approve
  # (SANDBOX_ACCESS_APPROVAL_FLOW). Read-only /sandbox status|explain and the
  # remaining /sandbox subcommands keep the owner-or-allowlist gate. Every
  # subcommand is in the approval family, so a process Fermix started cannot
  # answer or mint a prompt (`Authorization.in_person/1`).
  @operator_subcommands ["grant", "revoke", "confirm", "deny"]

  @impl true
  def authorize(message, metadata, context) do
    with :ok <- Authorization.in_person(metadata) do
      if invoked_command(metadata) in @operator_subcommands do
        Authorization.operator_only(message, metadata, context)
      else
        Authorization.owner_only(message, metadata, context)
      end
    end
  end

  defp invoked_command(metadata) when is_map(metadata),
    do: Map.get(metadata, :command_name, "sandbox")

  @impl true
  def execute(message, reply_fn, context) do
    dispatch(command_name(message), args(message), message, reply_fn, context)
  end

  defp dispatch("sandbox", ["status"], _message, reply_fn, _context),
    do: reply(reply_fn, status_text())

  defp dispatch("sandbox", ["explain"], _message, reply_fn, _context),
    do: reply(reply_fn, explain_text())

  defp dispatch("sandbox", ["mode", mode], message, reply_fn, _context),
    do: propose({:set_mode, mode}, message, reply_fn)

  defp dispatch("sandbox", ["env", "allow", name], message, reply_fn, _context),
    do: propose({:add_env_passthrough, name, [source: :env, name: name]}, message, reply_fn)

  defp dispatch(
         "sandbox",
         ["env", "set", name, "--", command | args],
         message,
         reply_fn,
         _context
       ),
       do:
         propose(
           {:add_env_passthrough, name, [source: :command, command: command, args: args]},
           message,
           reply_fn
         )

  defp dispatch("sandbox", ["env", command, name], _message, reply_fn, _context)
       when command in ["deny", "unset"],
       do: apply_now({:remove_env_passthrough, name}, reply_fn)

  defp dispatch("sandbox", ["commands", "profile", profile], message, reply_fn, _context),
    do: propose({:set_command_profile, profile}, message, reply_fn)

  defp dispatch("sandbox", ["commands", "enable", preset], message, reply_fn, _context),
    do: propose({:enable_preset, preset}, message, reply_fn)

  defp dispatch("sandbox", ["commands", "disable", preset], _message, reply_fn, _context),
    do: apply_now({:disable_preset, preset}, reply_fn)

  defp dispatch("grant", ["path", path], message, reply_fn, _context),
    do: propose({:add_allowed_root, path}, message, reply_fn)

  defp dispatch("revoke", ["path", path], _message, reply_fn, _context),
    do: apply_now({:remove_allowed_root, path}, reply_fn)

  defp dispatch("confirm", [token], message, reply_fn, context),
    do: confirm(token, message, reply_fn, context)

  defp dispatch("deny", [token], message, reply_fn, context),
    do: deny(token, message, reply_fn, context)

  defp dispatch(_name, _args, _message, reply_fn, _context),
    do:
      reply(
        reply_fn,
        "Usage: /sandbox status, /sandbox explain, /sandbox mode MODE, " <>
          "/sandbox env allow NAME, /sandbox env deny NAME, /sandbox env set NAME -- CMD [ARGS...], " <>
          "/sandbox env unset NAME, /sandbox commands enable PRESET, " <>
          "/sandbox commands disable PRESET, /grant path PATH, /revoke path PATH, " <>
          "/confirm TOKEN, /deny TOKEN"
      )

  defp propose(mutation, message, reply_fn) do
    current = Config.current()

    with {:ok, proposed} <- ConfigMutation.apply(current, mutation, dry_run: true) do
      if ConfigMutation.requires_confirmation?(current, proposed) do
        token = store_pending(mutation, message)
        diff = ConfigMutation.diff(current, proposed)

        reply_approval(
          reply_fn,
          %{
            kind: :sandbox,
            text: "Confirm sandbox change with /confirm #{token}\n#{diff}",
            detail: diff,
            token: token,
            ttl_s: div(@ttl_ms, 1_000)
          }
        )
      else
        persist(proposed, reply_fn)
      end
    else
      {:error, reason} -> reply(reply_fn, "Sandbox change rejected: #{format_error(reason)}")
    end
  end

  defp apply_now(mutation, reply_fn) do
    current = Config.current()

    with {:ok, config} <- ConfigMutation.apply(current, mutation, dry_run: true),
         :ok <- ConfigMutation.persist(config) do
      reply(reply_fn, "Sandbox updated.\n#{ConfigMutation.diff(current, config)}")
    else
      {:error, reason} -> reply(reply_fn, "Sandbox change rejected: #{format_error(reason)}")
    end
  end

  @doc """
  Store (or dedupe) an agent-initiated grant request as a pending confirmation,
  bound to the owner's conversation origin. This is the channels-side seam the
  gateway's injected `approval_fn` closure calls from inside an operator turn
  (the `request_directory_access` tool, and a coding-harness launch waiting on a
  vendor-config acknowledgment). Returns `{:ok, token, :existing}` when a live
  pending record for the same mutation + origin already exists (no second owner
  prompt), otherwise stores a new record and returns `{:ok, token, :new}`.
  """
  @spec store_pending_grant(grant_request(), grant_origin()) ::
          {:ok, String.t(), :new | :existing}
  def store_pending_grant(request, %{} = origin) when is_map(request) do
    mutation = grant_mutation(request)

    case find_live_pending(mutation, origin) do
      {:ok, token} ->
        {:ok, token, :existing}

      :error ->
        token = token()
        :ok = Confirmations.store(token, grant_pending_record(mutation, origin))
        {:ok, token, :new}
    end
  end

  defp grant_mutation(%{path: path}) when is_binary(path), do: {:add_allowed_root, path}

  defp grant_mutation(%{acknowledge_vendor_config: run_id}) when is_binary(run_id),
    do: {:acknowledge_vendor_config, run_id}

  defp grant_mutation(%{access_sensitive: intent_id}) when is_binary(intent_id),
    do: {:access_sensitive, intent_id}

  defp find_live_pending(mutation, origin) do
    now = now_ms()

    Confirmations.list()
    |> Enum.find(fn {_token, record} -> live_match?(record, mutation, origin, now) end)
    |> case do
      {token, _record} -> {:ok, token}
      nil -> :error
    end
  end

  defp live_match?(record, mutation, origin, now) do
    Map.get(record, :mutation) == mutation and record.expires_at >= now and
      record.channel == origin.channel and record.chat_id == origin.chat_id and
      record.thread_ts == origin.thread_ts and record.user_id == origin.user_id and
      Map.get(record, :ingress_context) == Map.get(origin, :ingress_context)
  end

  defp grant_pending_record(mutation, origin) do
    %{
      mutation: mutation,
      channel: origin.channel,
      chat_id: origin.chat_id,
      thread_ts: origin.thread_ts,
      user_id: origin.user_id,
      resume: Map.get(origin, :resume),
      expires_at: now_ms() + @ttl_ms
    }
    |> maybe_put(:ingress_context, Map.get(origin, :ingress_context))
  end

  defp confirm(token, message, reply_fn, context) do
    case take_pending(token, message) do
      {:ok, record} ->
        :ok = notify_approval(context, :sandbox, token, :approved)
        apply_confirmed(record, token, reply_fn, context)

      {:error, reason} ->
        reply(reply_fn, "Confirmation failed: #{inspect(reason)}")
    end
  end

  defp deny(token, message, reply_fn, context) do
    case take_pending(token, message) do
      {:ok, record} ->
        :ok = notify_approval(context, :sandbox, token, :denied)
        reply(reply_fn, denied_text(record))

      {:error, reason} ->
        reply(reply_fn, "Denial failed: #{inspect(reason)}")
    end
  end

  defp denied_text(%{mutation: {:acknowledge_vendor_config, _run_id}}) do
    "Not acknowledged — coding runs there stay paused until you confirm the change " <>
      "when the next one asks, or revert or commit it."
  end

  defp denied_text(%{mutation: {:access_sensitive, _intent_id}}),
    do: "Not sent: the command was not approved."

  defp denied_text(_grant), do: "Sandbox change denied — the pending grant was discarded."

  # A coding run's vendor-config change, acknowledged by the owner (GAP3-1): the
  # ledger row is marked resolved, so the next harness launch there proceeds, and
  # the request that was waiting on it resumes like an agent-initiated grant.
  defp apply_confirmed(
         %{mutation: {:acknowledge_vendor_config, run_id}} = record,
         token,
         reply_fn,
         context
       ) do
    case Ledger.clear_vendor_config(run_id, server: Map.fetch!(context, :memory_repo)) do
      {:ok, _row} -> finish_acknowledge(record, token, reply_fn, context)
      {:error, reason} -> reply(reply_fn, "Acknowledgment failed: #{format_error(reason)}")
    end
  end

  # An access-sensitive command the owner confirmed: core runs exactly the
  # recorded call (`AccessGate.confirm/2`) and this chat gets its outcome once.
  # Nothing is re-ingested — the daemon runs the call, not a new model turn.
  defp apply_confirmed(%{mutation: {:access_sensitive, intent_id}}, _token, reply_fn, context),
    do: spawn_access_confirm(intent_id, reply_fn, context)

  # A confirmed grant persists exactly like an owner-typed `/confirm`; the only
  # addition is the auto-resume branch for an agent-initiated record.
  defp apply_confirmed(record, token, reply_fn, context) do
    current = Config.current()

    with {:ok, config} <- ConfigMutation.apply(current, record.mutation, dry_run: true),
         :ok <- ConfigMutation.persist(config) do
      finish_confirm(record, token, reply_fn, context, ConfigMutation.diff(current, config))
    else
      {:error, reason} -> reply(reply_fn, "Sandbox change rejected: #{format_error(reason)}")
    end
  end

  defp notify_approval(context, kind, token, outcome) do
    case Map.get(context, :approval_resolution_fn) do
      nil ->
        :ok

      callback when is_function(callback, 1) ->
        run_approval_callback(callback, kind, token, outcome)
    end
  end

  defp run_approval_callback(callback, kind, token, outcome) do
    case callback.(%{kind: kind, token: token, outcome: outcome}) do
      :ok -> :ok
      other -> log_approval_callback_failure(kind, outcome, other)
    end
  rescue
    error -> log_approval_callback_failure(kind, outcome, error)
  catch
    caught_kind, reason -> log_approval_callback_failure(kind, outcome, {caught_kind, reason})
  end

  # The failure itself must reach the log: "callback failed" with no reason is
  # undiagnosable when an approval card sticks un-resolved.
  defp log_approval_callback_failure(kind, outcome, error) do
    Logger.error(
      "#{kind} approval resolution callback failed after #{outcome}: #{inspect(error)}"
    )

    :ok
  end

  # Three shapes: an owner-typed `/grant` record has no `:resume` key (unchanged
  # "Sandbox updated." reply); an agent request on a re-ingestable channel carries
  # a resume intent (auto-resume); an agent request on a one-shot origin (CLI)
  # carries `resume: nil` (owner re-runs manually).
  defp finish_confirm(record, token, reply_fn, context, diff) do
    case Map.fetch(record, :resume) do
      :error ->
        reply(reply_fn, "Sandbox updated.\n#{diff}")

      {:ok, %{content: _content} = resume} ->
        reply(reply_fn, "Sandbox updated. Access granted — resuming your request.\n#{diff}")
        resume_request(record, resume, token, context)

      {:ok, nil} ->
        reply(reply_fn, "Sandbox updated. Access granted — re-run your request.\n#{diff}")
    end
  end

  # Always an agent-initiated record, so it carries a resume intent: a chat
  # re-ingests the waiting request, a one-shot origin (CLI) re-runs it.
  defp finish_acknowledge(record, token, reply_fn, context) do
    case Map.fetch!(record, :resume) do
      %{content: _content} = resume ->
        reply(reply_fn, "Acknowledged — resuming your request.")
        resume_request(record, resume, token, context)

      nil ->
        reply(reply_fn, "Acknowledged — re-run your request.")
    end
  end

  # Re-ingest the original request as a fresh inbound message so authorization,
  # reply_fn, and queueing all happen exactly as for real inbound (the grant is
  # now live). Dispatched async on the task supervisor: `confirm` runs inside the
  # transport process that called `Gateway.ingest`, so a synchronous re-ingest
  # would re-enter that pipeline in the same process — the async hop keeps the
  # confirm reply prompt and never blocks the transport. A failure is logged, not
  # swallowed.
  defp resume_request(record, resume, token, context) do
    case ChannelRegistry.adapter(record.channel) do
      nil ->
        Logger.error(
          "grant resume: no adapter for channel #{record.channel}; cannot resume request"
        )

      adapter ->
        opts =
          [
            channel: adapter,
            agent: Map.fetch!(context, :agent),
            agent_server: Map.fetch!(context, :agent_server)
          ]
          |> maybe_put(:ingress_context, Map.get(record, :ingress_context))

        spawn_resume(synthesize_resume_message(record, resume, token), opts)
    end
  end

  defp spawn_resume(message, opts) do
    Task.Supervisor.start_child(FermixCore.TaskSupervisor, fn ->
      case Gateway.ingest([message], opts) do
        :ok -> :ok
        {:error, reason} -> Logger.error("grant resume ingest failed: #{inspect(reason)}")
      end
    end)

    :ok
  end

  # The command's helper call can take seconds, and `confirm` runs in the
  # transport process that called `Gateway.ingest`, so it runs on the task
  # supervisor (the `spawn_resume/2` hop) and replies exactly once. On the Mac
  # app and the phone the `/confirm` is a client request, deferred here (in the
  # ingest process, as the seam requires) and settled only after that reply, or
  # the reply would land on a request already closed and be dropped.
  defp spawn_access_confirm(intent_id, reply_fn, context) do
    finish = defer_command(context)

    {:ok, _pid} =
      Task.Supervisor.start_child(FermixCore.TaskSupervisor, fn ->
        run_access_confirm(intent_id, reply_fn, finish)
      end)

    :ok
  end

  # A crashed run may or may not have reached the device, so the owner is told
  # that before the crash goes on to the task supervisor's log.
  defp run_access_confirm(intent_id, reply_fn, finish) do
    case confirm_access(intent_id) do
      {:crashed, kind, reason, stacktrace} ->
        reply(reply_fn, @access_outcome_unknown)
        settle_command(finish, {:error, :crashed})
        :erlang.raise(kind, reason, stacktrace)

      result ->
        reply(reply_fn, access_outcome_text(result))
        settle_command(finish, result)
    end
  end

  defp confirm_access(intent_id) do
    AccessGate.confirm(intent_id)
  catch
    kind, reason -> {:crashed, kind, reason, __STACKTRACE__}
  end

  defp access_outcome_text({:ok, outcome}), do: "Confirmed. #{outcome}"
  defp access_outcome_text({:error, reason}), do: "Confirmed, but #{reason}"

  defp defer_command(context) do
    case Map.get(context, :defer_command_fn) do
      defer when is_function(defer, 0) -> defer.()
      nil -> nil
    end
  end

  defp settle_command(nil, _result), do: :ok
  defp settle_command(finish, {:ok, _outcome}), do: finish.(:completed)
  defp settle_command(finish, {:error, reason}), do: finish.({:failed, reason})

  defp synthesize_resume_message(record, resume, token) do
    Message.new!(%{
      id: "grant-resume-#{System.unique_integer([:positive])}",
      content: resume.content,
      sender: resume.sender,
      channel: record.channel,
      chat_id: record.chat_id,
      reply_target: resume.reply_target,
      thread_ts: record.thread_ts,
      metadata: %{user_id: record.user_id, resumed_from_grant: token}
    })
  end

  defp maybe_put(values, _key, nil), do: values
  defp maybe_put(values, key, value) when is_map(values), do: Map.put(values, key, value)
  defp maybe_put(values, key, value) when is_list(values), do: Keyword.put(values, key, value)

  defp persist(config, reply_fn) do
    case ConfigMutation.persist(config) do
      :ok -> reply(reply_fn, "Sandbox updated.")
      {:error, reason} -> reply(reply_fn, "Sandbox change rejected: #{format_error(reason)}")
    end
  end

  defp status_text do
    config = Config.current()

    "mode: #{config.mode}\nworkspace: #{config.workspace_root}\nallowed roots: #{length(config.allowed_roots)}\nenv passthrough: #{length(config.env.allow)}"
  end

  defp explain_text do
    config = Config.current()

    "mode: #{config.mode}\neffective roots:\n#{format_roots(Mode.root_provenance(config))}\nenv names: #{Enum.join(config.env.allow, ", ")}"
  end

  defp format_roots([]), do: "(none)"

  defp format_roots(roots),
    do: Enum.map_join(roots, "\n", fn {root, provenance} -> "- #{root} (#{provenance})" end)

  defp store_pending(mutation, message) do
    token = token()
    :ok = Confirmations.store(token, pending_record(mutation, message))
    token
  end

  # Peek → validate → take: a wrong-origin or expired /confirm must NOT consume
  # the owner's single-use token (token-burn hardening). The final `take` stays
  # the single-use authority — if a concurrent valid confirm consumed the token
  # between our peek and take, `take` returns `:error` and we report it as
  # already-used, never as success. This preserves exactly-once.
  defp take_pending(token, message) do
    with {:ok, record} <- Confirmations.peek(token),
         {:ok, ^record} <- validate_pending(record, message),
         {:ok, taken} <- Confirmations.take(token) do
      {:ok, taken}
    else
      :error -> {:error, :unknown_token}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_pending(record, message) do
    cond do
      record.expires_at < now_ms() -> {:error, :expired}
      same_origin?(record, message) -> {:ok, record}
      true -> {:error, :origin_mismatch}
    end
  end

  defp pending_record(mutation, message) do
    %{
      mutation: mutation,
      channel: message.channel,
      chat_id: message.chat_id,
      thread_ts: message.thread_ts,
      user_id: stable_user_id(message.metadata || %{}),
      expires_at: now_ms() + @ttl_ms
    }
  end

  defp same_origin?(record, message) do
    record.channel == message.channel and record.chat_id == message.chat_id and
      record.thread_ts == message.thread_ts and
      record.user_id == stable_user_id(message.metadata || %{})
  end

  defp token do
    5 |> :crypto.strong_rand_bytes() |> Base.encode32(padding: false) |> binary_part(0, 8)
  end

  defp command_name(message), do: Map.get(message.metadata || %{}, :command_name, "sandbox")
  defp args(message), do: String.split(message.content, ~r/\s+/, trim: true)
  defp stable_user_id(metadata), do: Map.get(metadata, :user_id) || Map.get(metadata, "user_id")
  defp now_ms, do: System.monotonic_time(:millisecond)

  defp format_error({:unsafe_root, path}) do
    "unsafe_root: #{path} cannot be granted. Run: /sandbox explain"
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp reply(reply_fn, text) do
    reply_fn.({:text, text})
    :ok
  end

  defp reply_approval(reply_fn, spec) do
    reply_fn.({:approval_prompt, spec})
    :ok
  end
end
