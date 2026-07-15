defmodule FermixChannels.Gateway.Commands.Sandbox do
  @moduledoc false

  @behaviour FermixChannels.Gateway.Command

  require Logger

  alias FermixChannels.Gateway
  alias FermixChannels.Gateway.ChannelRegistry
  alias FermixChannels.Gateway.Commands.Authorization
  alias FermixChannels.Gateway.Commands.Sandbox.Confirmations
  alias FermixChannels.Gateway.Message
  alias FermixCore.Sandbox.Config
  alias FermixCore.Sandbox.ConfigMutation
  alias FermixCore.Sandbox.Mode

  @ttl_ms 60_000

  @typedoc "Where an agent-initiated grant request came from — binds the pending record to the owner's conversation."
  @type grant_origin :: %{
          channel: String.t(),
          chat_id: String.t(),
          thread_ts: term(),
          user_id: String.t() | nil,
          resume: grant_resume() | nil
        }

  @typedoc "Enough of the original inbound message to faithfully re-ingest it after the grant is confirmed."
  @type grant_resume :: %{content: String.t(), reply_target: String.t(), sender: String.t()}

  @typedoc "The access request the `request_directory_access` tool passes to the injected approval closure."
  @type grant_request :: %{path: String.t(), reason: String.t(), diff: String.t()}

  @impl true
  def name, do: "sandbox"

  @impl true
  def aliases, do: ["grant", "revoke", "confirm"]

  @impl true
  def description, do: "Inspect or update sandbox policy."

  # Directory-grant subcommands demand strict operator role. The
  # `command_allowlist` (which admits a trusted guest for /new, /compact) must
  # never reach sandbox mutation: a guest's own /grant binds the pending record
  # to their origin, so `same_origin?` would otherwise let them self-approve
  # (SANDBOX_ACCESS_APPROVAL_FLOW). Read-only /sandbox status|explain and the
  # remaining /sandbox subcommands keep the owner-or-allowlist gate.
  @operator_subcommands ["grant", "revoke", "confirm"]

  @impl true
  def authorize(message, metadata, context) do
    if invoked_command(metadata) in @operator_subcommands do
      Authorization.operator_only(message, metadata, context)
    else
      Authorization.owner_only(message, metadata, context)
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

  defp dispatch(_name, _args, _message, reply_fn, _context),
    do:
      reply(
        reply_fn,
        "Usage: /sandbox status, /sandbox explain, /sandbox mode MODE, " <>
          "/sandbox env allow NAME, /sandbox env deny NAME, /sandbox env set NAME -- CMD [ARGS...], " <>
          "/sandbox env unset NAME, /sandbox commands enable PRESET, " <>
          "/sandbox commands disable PRESET, /grant path PATH, /revoke path PATH, /confirm TOKEN"
      )

  defp propose(mutation, message, reply_fn) do
    current = Config.current()

    with {:ok, proposed} <- ConfigMutation.apply(current, mutation, dry_run: true) do
      if ConfigMutation.requires_confirmation?(current, proposed) do
        token = store_pending(mutation, message)

        reply(
          reply_fn,
          "Confirm sandbox change with /confirm #{token}\n#{ConfigMutation.diff(current, proposed)}"
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
  (the `request_directory_access` tool). Returns `{:ok, token, :existing}` when a
  live pending record for the same mutation + origin already exists (no second
  owner prompt), otherwise stores a new record and returns `{:ok, token, :new}`.
  """
  @spec store_pending_grant(grant_request(), grant_origin()) ::
          {:ok, String.t(), :new | :existing}
  def store_pending_grant(%{path: path}, %{} = origin) when is_binary(path) do
    mutation = {:add_allowed_root, path}

    case find_live_pending(mutation, origin) do
      {:ok, token} ->
        {:ok, token, :existing}

      :error ->
        token = token()
        :ok = Confirmations.store(token, grant_pending_record(mutation, origin))
        {:ok, token, :new}
    end
  end

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
      record.thread_ts == origin.thread_ts and record.user_id == origin.user_id
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
  end

  defp confirm(token, message, reply_fn, context) do
    case take_pending(token, message) do
      {:ok, record} -> apply_confirmed(record, token, reply_fn, context)
      {:error, reason} -> reply(reply_fn, "Confirmation failed: #{inspect(reason)}")
    end
  end

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
        opts = [
          channel: adapter,
          agent: Map.fetch!(context, :agent),
          agent_server: Map.fetch!(context, :agent_server)
        ]

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
end
