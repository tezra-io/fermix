defmodule FermixChannels.Gateway.Commands.Background do
  @moduledoc false

  @behaviour FermixChannels.Gateway.Command

  alias FermixChannels.Gateway.Authorization, as: IngressAuthorization
  alias FermixChannels.Gateway.Commands.Authorization
  alias FermixChannels.Gateway.WorkRegistry
  alias FermixCore.Agents.BackgroundRun

  @default_registry FermixChannels.Gateway.WorkRegistry
  @runner_gate_timeout_ms 5_000

  @impl true
  def name, do: "background"

  @impl true
  def aliases, do: ["bg"]

  @impl true
  def description,
    do: "Run a task in the background without blocking this chat. Usage: /background <prompt>"

  # Strict operator role: `/background` bypasses the single-flight queue and
  # spends the owner's provider budget on a detached run. The
  # `command_allowlist` guest branch exists for conversation-scoped lifecycle
  # commands (/new, /compact), not for starting owner-funded work.
  @impl true
  def authorize(message, metadata, context),
    do: Authorization.operator_only(message, metadata, context)

  @impl true
  def execute(message, reply_fn, context) do
    case String.trim(message.content) do
      "" -> reply_fn.({:text, "Usage: /background <prompt>"})
      prompt -> start_work(prompt, message, reply_fn, context)
    end

    :ok
  end

  defp start_work(prompt, message, reply_fn, context) do
    finish_command = defer_command(context)
    gate = {self(), make_ref()}

    request = %{
      run:
        runner(
          prompt,
          source_trust(context),
          reply_fn,
          background_run(context),
          finish_command,
          gate
        ),
      command: "background",
      profile: :normal,
      channel: message.channel,
      conversation_key: Map.get(context, :conversation_key),
      prompt_preview: prompt
    }

    case WorkRegistry.start(registry(context), request) do
      {:ok, work_id} ->
        ack =
          reply_fn.(
            {:text,
             "Started background work #{work_id}. I'll post the result here when it's done — " <>
               "/tasks to check, /stop to cancel."}
          )

        release_runner(gate, ack, finish_command)

      {:error, {:max_running_work, max}} ->
        reply_fn.(
          {:text,
           "Too many background tasks already running (limit #{max}). " <>
             "Wait for one to finish, or /stop to cancel them, then try again."}
        )

        settle_completed(finish_command)

      {:error, reason} ->
        reply_fn.({:text, "Couldn't start background work: #{inspect(reason)}"})
        settle_completed(finish_command)
    end
  end

  # The background task: run the detached core coordinator, then deliver its
  # result back to this conversation through the captured reply context.
  defp runner(prompt, source_trust, reply_fn, background_run, finish_command, gate) do
    fn work_id ->
      case await_runner_release(gate) do
        :run -> run_background(work_id, prompt, source_trust, reply_fn, background_run, finish_command)
        {:abort, reason} -> abort_background(reason, finish_command)
      end
    end
  end

  defp run_background(work_id, prompt, source_trust, reply_fn, background_run, finish_command) do
    result = background_run.run(%{prompt: prompt, work_id: work_id, source_trust: source_trust})
    reply_result = reply_fn.({:text, format_result(work_id, result)})
    settle_after_reply(finish_command, result, reply_result)
    finish(result)
  end

  defp release_runner({_owner, ref}, ack_result, finish_command) do
    receive do
      {^ref, runner} when is_pid(runner) ->
        send(runner, {ref, release_action(ack_result)})
        :ok
    after
      @runner_gate_timeout_ms ->
        settle_failed(finish_command, :runner_start_timeout)
        {:error, :runner_start_timeout}
    end
  end

  defp await_runner_release({owner, ref}) do
    send(owner, {ref, self()})

    receive do
      {^ref, action} when action == :run or elem(action, 0) == :abort -> action
    after
      @runner_gate_timeout_ms -> {:abort, :ack_timeout}
    end
  end

  defp release_action({:error, reason}), do: {:abort, {:ack_failed, reason}}
  defp release_action(_success), do: :run

  defp abort_background(reason, finish_command) do
    settle_failed(finish_command, reason)
    exit({:shutdown, {:background_run_failed, reason}})
  end

  defp defer_command(context) do
    case Map.get(context, :defer_command_fn) do
      defer when is_function(defer, 0) -> defer.()
      nil -> nil
    end
  end

  defp settle_command(nil, _result), do: :ok
  defp settle_command(finish, {:ok, _response}), do: finish.(:completed)
  defp settle_command(finish, {:error, reason}), do: finish.({:failed, reason})

  defp settle_after_reply(finish, _result, {:error, reason}),
    do: settle_failed(finish, {:final_reply_failed, reason})

  defp settle_after_reply(finish, result, _success), do: settle_command(finish, result)

  defp settle_completed(nil), do: :ok
  defp settle_completed(finish), do: finish.(:completed)

  defp settle_failed(nil, _reason), do: :ok
  defp settle_failed(finish, reason), do: finish.({:failed, reason})

  # WorkRegistry derives terminal status from the task's exit reason: a normal
  # exit records :completed. So a core failure must exit non-normally to be
  # recorded as :failed — a quiet `:shutdown` (no crash report), since the error
  # was already handled and delivered to the user above.
  defp finish({:ok, _response}), do: :ok
  defp finish({:error, reason}), do: exit({:shutdown, {:background_run_failed, reason}})

  defp format_result(work_id, {:ok, response}),
    do: "Background work #{work_id} done:\n\n#{response}"

  defp format_result(work_id, {:error, reason}),
    do: "Background work #{work_id} failed: #{inspect(reason)}"

  defp source_trust(%{authorization: %IngressAuthorization{trust: trust}})
       when trust in [:operator, :guest],
       do: trust

  defp source_trust(_context), do: :guest

  defp registry(context), do: Map.get(context, :work_registry, @default_registry)
  defp background_run(context), do: Map.get(context, :background_run, BackgroundRun)
end
