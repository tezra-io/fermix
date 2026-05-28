defmodule FermixCore.Tools.UpdateJob do
  @moduledoc """
  Edit an existing scheduled job's task instructions, schedule, or description
  in place, without removing and recreating it.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Jobs.Registry
  alias FermixCore.Tools.JobRegistrySupport, as: Support

  @impl true
  def name, do: "update_job"

  @impl true
  def description do
    "Edit an existing Fermix scheduled job in place: revise its task instructions " <>
      "(for example to store a value the job needs, like a location or account), change " <>
      "its schedule, or update its description. Use this instead of removing and " <>
      "recreating a job when the user supplies missing details or wants a different time."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      required: ["job_id"],
      properties: %{
        job_id: %{type: "string", description: "Scheduled job id to edit."},
        task: %{
          type: "string",
          description:
            "Replacement work instructions for the future run. Include any values the run needs (such as a location or zip code) directly in this text — scheduled runs cannot see the chat where the job was set up."
        },
        schedule: %{
          type: "string",
          description:
            "Replacement schedule expression, such as every 15 minutes, daily at 8am, or 0 8 * * *. Recomputes the next run time."
        },
        description: %{
          type: "string",
          description: "Replacement short description for the source catalog."
        }
      }
    }
  end

  @impl true
  def when_to_use do
    "Edit a scheduled job's task, schedule, or description after it was created — especially to persist a value the run needs."
  end

  @impl true
  def examples do
    [
      %{
        args: %{"job_id" => "weather_abc", "task" => "Send the daily weather for zip 94105."},
        note: "store a parameter the scheduled run needs"
      }
    ]
  end

  @impl true
  def failure_modes do
    [
      %{tag: "missing_job_id", description: "job_id is absent or blank"},
      %{tag: "not_found", description: "job id does not exist"},
      %{tag: "empty_update", description: "no task, schedule, or description provided"},
      %{tag: "invalid_schedule", description: "schedule expression cannot be parsed"}
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
    with {:ok, job_id} <- Support.required_string(args, "job_id"),
         {:ok, attrs} <- update_attrs(args) do
      case Registry.update_job(job_id, attrs, repo: Support.repo(context)) do
        {:ok, job} -> Support.success_json(Support.job_payload(job))
        {:error, reason} -> Support.error(reason)
      end
    else
      {:error, reason} when is_binary(reason) -> {:ok, Tool.error(reason)}
      {:error, reason} -> Support.error(reason)
    end
  end

  defp update_attrs(args) do
    attrs =
      %{}
      |> put_present(:task_prompt, Support.optional_string(args, "task"))
      |> put_present(:schedule, Support.optional_string(args, "schedule"))
      |> put_present(:description, Support.optional_string(args, "description"))

    if map_size(attrs) == 0 do
      {:error, "Provide at least one of task, schedule, or description to update."}
    else
      {:ok, attrs}
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
