defmodule FermixCore.Tools.ScheduleJob do
  @moduledoc """
  Create a durable scheduled job without running it immediately.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Jobs.DeliveryDefaults
  alias FermixCore.Jobs.Registry
  alias FermixCore.Tools.JobRegistrySupport, as: Support

  @impl true
  def name, do: "schedule_job"

  @impl true
  def description do
    "Create a durable Fermix scheduled job for reminders, cron-style recurring work, " <>
      "periodic checks, digests, watchers, temporary jobs, or tasks that should run " <>
      "later. Use expires_at for jobs that should stop after a fixed time. Use this " <>
      "instead of shell, browser, computer-use, or external automation when the user " <>
      "asks Fermix to schedule work."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      required: ["name", "schedule", "task"],
      properties: %{
        name: %{type: "string", description: "Human-readable job name."},
        schedule: %{
          type: "string",
          description:
            "Natural or cron-style schedule expression, such as every 15 minutes, daily at 8am, or 0 8 * * *."
        },
        task: %{
          type: "string",
          description:
            "Work instructions for the future Fermix scheduled run. Do not execute the task now unless the user separately asks for an immediate run. Keep lifecycle timing in schedule and expires_at, not in the task text."
        },
        description: %{type: "string", description: "Short description for the source catalog."},
        timezone: %{type: "string", description: "IANA timezone label stored with the job."},
        expires_at: %{
          type: "string",
          description:
            "Optional ISO8601 UTC datetime for temporary jobs. When reached, Fermix stops running the job and marks it expired."
        },
        allowed_tools: %{type: "array", items: %{type: "string"}},
        capability_policy: %{type: "array", items: %{type: "string"}},
        timeout_seconds: %{
          type: "integer",
          minimum: 1,
          description: "Optional wall-clock timeout for each run."
        },
        inactivity_timeout_seconds: %{
          type: "integer",
          minimum: 1,
          description: "Optional timeout when the provider/tool loop stops making progress."
        },
        delivery_mode: %{
          type: "string",
          enum: ["none", "origin", "channel", "local"],
          description:
            ~s(Optional delivery_mode. Use "origin" when a channel request should report back to the same chat, "channel" only with an explicit delivery_target or configured default, and "none" for silent jobs.)
        },
        delivery_target: %{type: "object"}
      }
    }
  end

  @impl true
  def when_to_use do
    "Create a Fermix scheduled job for reminders, recurring checks, digests, watchers, or later work."
  end

  @impl true
  def examples do
    [
      %{
        args: %{
          "name" => "daily_digest",
          "schedule" => "daily at 8am",
          "task" => "Send a digest."
        },
        note: "schedule recurring Fermix work"
      }
    ]
  end

  @impl true
  def failure_modes do
    [
      %{tag: "missing_parameters", description: "name, schedule, or task is absent"},
      %{tag: "invalid_schedule", description: "schedule expression cannot be parsed"},
      %{tag: "invalid_delivery", description: "delivery_mode or delivery_target is invalid"}
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :scheduling

  @impl true
  def execute(args, context) when is_map(args) and is_map(context) do
    Support.run(name(), context, fn -> do_execute(args, context) end)
  end

  defp do_execute(args, context) do
    with {:ok, name} <- Support.required_string(args, "name"),
         {:ok, schedule} <- Support.required_string(args, "schedule"),
         {:ok, task} <- Support.required_string(args, "task"),
         {:ok, timeout_seconds} <- Support.optional_positive_integer(args, "timeout_seconds"),
         {:ok, inactivity_timeout_seconds} <-
           Support.optional_positive_integer(args, "inactivity_timeout_seconds"),
         {:ok, expires_at} <- Support.optional_datetime(args, "expires_at"),
         {:ok, {delivery_mode, delivery_target}} <- DeliveryDefaults.resolve(args, context) do
      attrs = %{
        name: name,
        schedule: schedule,
        task_prompt: task,
        description: Support.optional_string(args, "description"),
        timezone: Support.optional_string(args, "timezone", "UTC"),
        allowed_tools: Support.optional_list(args, "allowed_tools"),
        capability_policy: Support.optional_list(args, "capability_policy"),
        timeout_seconds: timeout_seconds,
        inactivity_timeout_seconds: inactivity_timeout_seconds,
        expires_at: expires_at,
        delivery_mode: delivery_mode,
        delivery_target: delivery_target,
        created_by_agent_id: Map.get(context, :memory_agent_id, "main"),
        created_by_session_id: origin_session_id(context)
      }

      case Registry.create_job(attrs, repo: Support.repo(context)) do
        {:ok, job} -> Support.success_json(Support.job_payload(job))
        {:error, reason} -> Support.error(reason)
      end
    else
      {:error, reason} when is_binary(reason) -> {:ok, Tool.error(reason)}
      {:error, reason} -> Support.error(reason)
    end
  end

  defp origin_session_id(%{conversation_key: {channel, chat_id, thread_scope}}) do
    Enum.map_join([channel, chat_id, thread_scope], ":", &target_part/1)
  end

  defp origin_session_id(context), do: Map.get(context, :session_id)

  defp target_part(:root), do: "root"
  defp target_part(value) when is_binary(value), do: value
  defp target_part(value) when is_integer(value), do: Integer.to_string(value)
  defp target_part(value) when is_atom(value), do: Atom.to_string(value)
  defp target_part(value), do: inspect(value)
end
