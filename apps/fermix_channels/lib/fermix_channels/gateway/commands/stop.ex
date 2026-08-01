defmodule FermixChannels.Gateway.Commands.Stop do
  @moduledoc false

  @behaviour FermixChannels.Gateway.Command

  alias FermixChannels.Gateway.Commands.Authorization
  alias FermixChannels.Gateway.Stopper

  @impl true
  def name, do: "stop"

  @impl true
  def aliases, do: []

  @impl true
  def description, do: "Stop all running Fermix work and clear queued messages."

  # Strict operator role: `/stop` is daemon-global, not conversation-scoped —
  # `Stopper.stop_all/1` fans out to every queued conversation across every
  # channel plus all background work and coding runs. The `command_allowlist`
  # guest branch exists for conversation-scoped lifecycle commands (/new,
  # /compact), so it must never reach a global fail-safe.
  @impl true
  def authorize(message, metadata, context),
    do: Authorization.operator_only(message, metadata, context)

  # Handled in the ingress path before the queue, so `/stop` runs immediately
  # instead of waiting behind the work it is trying to stop.
  @impl true
  def execute(_message, reply_fn, context) do
    reply_fn.({:text, reply(Stopper.stop_all(stopper_opts(context)))})
    :ok
  end

  # Stop the queue THIS ingress is using. The active queue is `:agent_server`
  # (the CLI/bench paths isolate their own via `ingest(agent_server: ...)`);
  # fall back to the registered servers only when none are in context.
  defp stopper_opts(context) do
    []
    |> put_server(:queue, Map.get(context, :agent_server))
    |> put_server(:work_registry, Map.get(context, :work_registry))
    |> put_server(:harness, Map.get(context, :harness_manager))
  end

  defp put_server(opts, _key, nil), do: opts
  defp put_server(opts, key, server), do: Keyword.put(opts, key, server)

  defp reply(%{active_turns: 0, queued_messages: 0, background_tasks: 0, harness_runs: 0}),
    do: "No active Fermix execution to stop."

  defp reply(%{
         active_turns: turns,
         queued_messages: messages,
         background_tasks: tasks,
         harness_runs: harness_runs
       }) do
    "Stopped Fermix execution — cancelled #{count(turns, "active turn")}, " <>
      "cleared #{count(messages, "queued message")}, stopped " <>
      "#{count(tasks, "background task")}, and cancelled " <>
      "#{count(harness_runs, "coding run")} (including any a scheduled job started). " <>
      "Scheduled jobs themselves and voice are not affected by /stop."
  end

  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n} #{noun}s"
end
