defmodule FermixCore.Tools.UpdateJob do
  @moduledoc """
  Edit an existing scheduled job's task instructions, schedule, or description
  in place, without removing and recreating it.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Agents.SkillRegistry
  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Jobs.DeliveryDefaults
  alias FermixCore.Jobs.Registry
  alias FermixCore.Tools.JobRegistrySupport, as: Support

  @impl true
  def name, do: "update_job"

  @impl true
  def description do
    "Edit an existing Fermix scheduled job in place: revise its task instructions " <>
      "(for example to store a value the job needs, like a location or account), change " <>
      "its schedule or description, rebind it to a skill, or change where its output is " <>
      "delivered. Use this instead of removing and recreating a job when the user " <>
      "supplies missing details, wants a different time, or wants results sent elsewhere."
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
            "Replacement schedule expression: an interval like every 15 minutes, a 5-field cron like 0 8 * * * (8am daily), or an ISO8601 UTC timestamp. Cron fields support *, lists, ranges, and steps. Recomputes the next run time."
        },
        description: %{
          type: "string",
          description: "Replacement short description for the source catalog."
        },
        skill_name: %{
          type: "string",
          description:
            "Bind the job to an existing skill (rejected if unknown). The run then executes inside that skill's tool/capability confinement, intersected with the job's — never widened."
        },
        provider: %{
          type: "string",
          description:
            "Pin the job's runs to a provider (anthropic, openai, xai, openrouter, ollama, ...; must be a known, configured provider). Must be set together with model. Omit both to leave the current values unchanged. To remove an existing pin, use clear_route_pin instead."
        },
        model: %{
          type: "string",
          description:
            "Pin the job's runs to a provider-specific model id (paired with provider). Free-form — providers like ollama/openrouter accept arbitrary models. Omit both provider and model to leave the current values unchanged. To remove an existing pin, use clear_route_pin instead."
        },
        clear_route_pin: %{
          type: "boolean",
          description:
            "Set true to remove any pinned provider/model and return the job to default routing. Mutually exclusive with provider/model (set those to re-pin instead). Omit or false to leave the current pin unchanged."
        },
        delivery_mode: %{
          type: "string",
          enum: ["none", "origin", "channel", "local"],
          description:
            ~s(Replacement delivery_mode. "origin" reports back to the originating chat, "channel" needs a delivery_target or configured default, "local"/"none" are silent. Omit to leave delivery unchanged.)
        },
        delivery_target: %{
          type: "object",
          description:
            "Replacement delivery target for channel mode. Omit to leave the current target unchanged; switching to none/local clears it."
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
      %{tag: "empty_update", description: "no editable field provided"},
      %{tag: "invalid_schedule", description: "schedule expression cannot be parsed"},
      %{tag: "unknown_skill", description: "skill_name does not name an existing skill"},
      %{tag: "invalid_delivery", description: "delivery_mode or delivery_target is invalid"},
      %{
        tag: "route_pin_conflict",
        description: "clear_route_pin was combined with provider or model"
      }
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
         {:ok, skill_name} <- validate_skill_name(args, context),
         {:ok, delivery} <- resolve_delivery(args, context),
         {:ok, clear_route_pin?} <- validate_clear_route_pin(args),
         {:ok, route_pin} <- Support.validate_route_pin(args),
         {:ok, attrs} <- update_attrs(args, skill_name, delivery, route_pin, clear_route_pin?) do
      case Registry.update_job(job_id, attrs, repo: Support.repo(context)) do
        {:ok, job} -> Support.success_json(Support.job_payload(job))
        {:error, reason} -> Support.error(reason)
      end
    else
      {:error, reason} when is_binary(reason) -> {:ok, Tool.error(reason)}
      {:error, reason} -> Support.error(reason)
    end
  end

  # Clearing a pin and setting one are mutually exclusive: clear_route_pin=true
  # un-pins to default routing, so combining it with a provider/model is an
  # ambiguous request, not a fallback. Reject it loud (CLAUDE.md #12).
  defp validate_clear_route_pin(args) do
    clear? = Map.get(args, "clear_route_pin") == true
    has_pin? = Support.optional_string(args, "provider") || Support.optional_string(args, "model")

    if clear? and has_pin? do
      {:error, "clear_route_pin cannot be combined with provider or model"}
    else
      {:ok, clear?}
    end
  end

  defp update_attrs(args, skill_name, delivery, {provider, model}, clear_route_pin?) do
    attrs =
      %{}
      |> put_present(:task_prompt, Support.optional_string(args, "task"))
      |> put_present(:schedule, Support.optional_string(args, "schedule"))
      |> put_present(:description, Support.optional_string(args, "description"))
      |> put_present(:skill_name, skill_name)
      |> put_present(:provider, provider)
      |> put_present(:model, model)
      |> put_delivery(delivery)
      |> put_route_pin_clear(clear_route_pin?)

    if map_size(attrs) == 0 do
      {:error,
       "Provide at least one of task, schedule, description, skill_name, provider/model, clear_route_pin, or delivery to update."}
    else
      {:ok, attrs}
    end
  end

  # Signals the registry to null provider AND model atomically. A dedicated
  # sentinel is required because the registry's nil-drop write path treats
  # provider: nil as "leave unchanged", so the pin would otherwise survive.
  defp put_route_pin_clear(map, true), do: Map.put(map, :clear_route_pin, true)
  defp put_route_pin_clear(map, false), do: map

  # Absent delivery yields :no_change so an unrelated edit never retargets the
  # job; an explicit delivery is validated by DeliveryDefaults before it lands.
  defp resolve_delivery(args, context) do
    case DeliveryDefaults.resolve_update(args, context) do
      :no_change -> {:ok, :no_change}
      {:ok, {mode, target}} -> {:ok, {mode, target}}
      {:error, reason} -> {:error, reason}
    end
  end

  # A re-bound skill must already exist; the run-time confinement is enforced in
  # Jobs.Runner. Absent skill_name leaves the existing binding untouched.
  defp validate_skill_name(args, context) do
    case Support.optional_string(args, "skill_name") do
      nil ->
        {:ok, nil}

      name ->
        registry = Map.get(context, :skill_registry, SkillRegistry)

        case SkillRegistry.load(registry, name) do
          {:ok, _definition} -> {:ok, name}
          {:error, {:unknown_skill, _}} -> {:error, "unknown_skill: #{name}"}
        end
    end
  catch
    :exit, reason -> {:error, "skill_registry_unavailable: #{inspect(reason)}"}
  end

  defp put_delivery(map, :no_change), do: map

  defp put_delivery(map, {mode, target}) do
    Map.merge(map, %{delivery_mode: mode, delivery_target: target})
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
