defmodule FermixChannels.Commands.Sandbox do
  @moduledoc false

  @behaviour FermixChannels.Command

  alias FermixChannels.Commands.Authorization
  alias FermixChannels.Commands.Sandbox.Confirmations
  alias FermixCore.Sandbox.Config
  alias FermixCore.Sandbox.ConfigMutation

  @ttl_ms 60_000

  @impl true
  def name, do: "sandbox"

  @impl true
  def aliases, do: ["grant", "revoke", "confirm"]

  @impl true
  def description, do: "Inspect or update sandbox policy."

  @impl true
  def authorize(message, metadata, context),
    do: Authorization.owner_only(message, metadata, context)

  @impl true
  def execute(message, reply_fn, _context) do
    dispatch(command_name(message), args(message), message, reply_fn)
  end

  defp dispatch("sandbox", ["status"], _message, reply_fn), do: reply(reply_fn, status_text())
  defp dispatch("sandbox", ["explain"], _message, reply_fn), do: reply(reply_fn, explain_text())

  defp dispatch("sandbox", ["mode", mode], message, reply_fn),
    do: propose({:set_mode, mode}, message, reply_fn)

  defp dispatch("sandbox", ["env", "allow", name], message, reply_fn),
    do: propose({:add_env_passthrough, name, [source: :env, name: name]}, message, reply_fn)

  defp dispatch("sandbox", ["env", "set", name, "--", command | args], message, reply_fn),
    do: propose({:add_env_passthrough, name, [source: :command, command: command, args: args]}, message, reply_fn)

  defp dispatch("sandbox", ["env", command, name], _message, reply_fn)
       when command in ["deny", "unset"],
       do: apply_now({:remove_env_passthrough, name}, reply_fn)

  defp dispatch("sandbox", ["commands", "profile", profile], message, reply_fn),
    do: propose({:set_command_profile, profile}, message, reply_fn)

  defp dispatch("sandbox", ["commands", "enable", preset], message, reply_fn),
    do: propose({:enable_preset, preset}, message, reply_fn)

  defp dispatch("sandbox", ["commands", "disable", preset], _message, reply_fn),
    do: apply_now({:disable_preset, preset}, reply_fn)

  defp dispatch("grant", ["path", path], message, reply_fn),
    do: propose({:add_allowed_root, path}, message, reply_fn)

  defp dispatch("revoke", ["path", path], _message, reply_fn),
    do: apply_now({:remove_allowed_root, path}, reply_fn)

  defp dispatch("confirm", [token], message, reply_fn), do: confirm(token, message, reply_fn)

  defp dispatch(_name, _args, _message, reply_fn),
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

  defp confirm(token, message, reply_fn) do
    case take_pending(token, message) do
      {:ok, mutation} -> apply_now(mutation, reply_fn)
      {:error, reason} -> reply(reply_fn, "Confirmation failed: #{inspect(reason)}")
    end
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

    "mode: #{config.mode}\nallowed roots:\n#{Enum.map_join(config.allowed_roots, "\n", &"- #{&1}")}\nenv names: #{Enum.join(config.env.allow, ", ")}"
  end

  defp store_pending(mutation, message) do
    token = token()
    :ok = Confirmations.store(token, pending_record(mutation, message))
    token
  end

  defp take_pending(token, message) do
    case Confirmations.take(token) do
      {:ok, record} -> validate_pending(record, message)
      :error -> {:error, :unknown_token}
    end
  end

  defp validate_pending(record, message) do
    cond do
      record.expires_at < now_ms() -> {:error, :expired}
      same_origin?(record, message) -> {:ok, record.mutation}
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
    reply_fn.(text)
    :ok
  end
end
