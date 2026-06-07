defmodule FermixChannels.Gateway.Commands.Background do
  @moduledoc false

  @behaviour FermixChannels.Gateway.Command

  alias FermixChannels.Gateway.Authorization, as: IngressAuthorization
  alias FermixChannels.Gateway.Commands.Authorization
  alias FermixChannels.Gateway.WorkRegistry
  alias FermixCore.Agents.BackgroundRun

  @default_registry FermixChannels.Gateway.WorkRegistry

  @impl true
  def name, do: "background"

  @impl true
  def aliases, do: ["bg"]

  @impl true
  def description,
    do: "Run a task in the background without blocking this chat. Usage: /background <prompt>"

  @impl true
  def authorize(message, metadata, context),
    do: Authorization.owner_only(message, metadata, context)

  @impl true
  def execute(message, reply_fn, context) do
    case String.trim(message.content) do
      "" -> reply_fn.({:text, "Usage: /background <prompt>"})
      prompt -> start_work(prompt, message, reply_fn, context)
    end

    :ok
  end

  defp start_work(prompt, message, reply_fn, context) do
    request = %{
      run: runner(prompt, source_trust(context), reply_fn, background_run(context)),
      command: "background",
      profile: :normal,
      channel: message.channel,
      conversation_key: Map.get(context, :conversation_key),
      prompt_preview: prompt
    }

    case WorkRegistry.start(registry(context), request) do
      {:ok, work_id} ->
        reply_fn.(
          {:text,
           "Started background work #{work_id}. I'll post the result here when it's done — " <>
             "/tasks to check, /stop to cancel."}
        )

      {:error, reason} ->
        reply_fn.({:text, "Couldn't start background work: #{inspect(reason)}"})
    end
  end

  # The background task: run the detached core coordinator, then deliver its
  # result back to this conversation through the captured reply context.
  defp runner(prompt, source_trust, reply_fn, background_run) do
    fn work_id ->
      result = background_run.run(%{prompt: prompt, work_id: work_id, source_trust: source_trust})
      reply_fn.({:text, format_result(work_id, result)})
      finish(result)
    end
  end

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
