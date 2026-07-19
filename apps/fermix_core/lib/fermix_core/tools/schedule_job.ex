defmodule FermixCore.Tools.ScheduleJob do
  @moduledoc """
  Create a durable scheduled job without running it immediately.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Agents.SkillRegistry
  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
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
            "Schedule expression: an interval like every 15 minutes, a 5-field cron like 0 8 * * * (8am daily), or an ISO8601 UTC timestamp for a one-off run. Cron fields support *, lists (1,15), ranges (9-17), and steps (*/15)."
        },
        task: %{
          type: "string",
          description:
            "Work instructions for the future Fermix scheduled run. Do not execute the task now unless the user separately asks for an immediate run. Keep lifecycle timing in schedule and expires_at, not in the task text. Bake any values the run will need (such as a location, zip code, or account) into this text — scheduled runs run in isolation and cannot see this conversation. Use update_job to revise these instructions later."
        },
        description: %{type: "string", description: "Short description for the source catalog."},
        timezone: %{type: "string", description: "IANA timezone label stored with the job."},
        expires_at: %{
          type: "string",
          description:
            "Optional ISO8601 UTC datetime for temporary jobs. When reached, Fermix stops running the job and marks it expired."
        },
        allowed_tools: %{
          type: "array",
          items: %{type: "string"},
          description:
            "Optional narrowing list of tool names the future run may call. Names must be a subset of the tools available to the caller now; unknown names are rejected. Capability policy is derived from the caller — the model cannot widen the future run's policy class."
        },
        skill_name: %{
          type: "string",
          description:
            "Optional name of an existing skill to bind the run to. The scheduled run then executes inside that skill's confinement — its allowed_tools and capability policy are intersected with the job's, never widened. Unknown skill names are rejected."
        },
        provider: %{
          type: "string",
          description:
            "Optional provider to pin this job's runs to (anthropic, openai, xai, openrouter, ollama, ...; must be a known, configured provider). Must be set together with model. Omit both to use the default cron route."
        },
        model: %{
          type: "string",
          description:
            "Optional provider-specific model id to pin this job's runs to (paired with provider). Free-form — providers like ollama/openrouter accept arbitrary models. Omit both provider and model to use the default cron route."
        },
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
          "schedule" => "0 8 * * *",
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
      %{tag: "invalid_delivery", description: "delivery_mode or delivery_target is invalid"},
      %{
        tag: "invalid_route_pin",
        description: "provider is unknown, or provider/model are not paired"
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
    with {:ok, name} <- Support.required_string(args, "name"),
         {:ok, schedule} <- Support.required_string(args, "schedule"),
         {:ok, task} <- Support.required_string(args, "task"),
         {:ok, timeout_seconds} <- Support.optional_positive_integer(args, "timeout_seconds"),
         {:ok, inactivity_timeout_seconds} <-
           Support.optional_positive_integer(args, "inactivity_timeout_seconds"),
         {:ok, expires_at} <- Support.optional_datetime(args, "expires_at"),
         {:ok, {delivery_mode, delivery_target}} <- DeliveryDefaults.resolve(args, context),
         {:ok, allowed_tools} <- caller_scoped_allowed_tools(args, context),
         {:ok, skill_name} <- validate_skill_name(args, context),
         {:ok, created_by_trust} <- require_source_trust(context),
         {:ok, {provider, model}} <- Support.validate_route_pin(args) do
      attrs = %{
        name: name,
        schedule: schedule,
        task_prompt: task,
        skill_name: skill_name,
        provider: provider,
        model: model,
        description: Support.optional_string(args, "description"),
        timezone: Support.optional_string(args, "timezone", "UTC"),
        allowed_tools: allowed_tools,
        capability_policy: [],
        timeout_seconds: timeout_seconds,
        inactivity_timeout_seconds: inactivity_timeout_seconds,
        expires_at: expires_at,
        delivery_mode: delivery_mode,
        delivery_target: delivery_target,
        created_by_agent_id: Map.get(context, :memory_agent_id, "main"),
        created_by_session_id: origin_session_id(context),
        created_by_channel: Map.get(context, :source_channel),
        created_by_trust: created_by_trust
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

  # Audit F-08: tool names in `allowed_tools` must be a subset of the
  # capabilities the caller can currently see. A remote-channel main-agent
  # turn cannot smuggle `shell` or `web_fetch` into a future scheduled run.
  defp caller_scoped_allowed_tools(args, context) do
    requested = Support.optional_list(args, "allowed_tools")

    if requested == [] do
      {:ok, []}
    else
      visible = caller_visible_tool_names(context)

      case Enum.reject(requested, &(&1 in visible)) do
        [] -> {:ok, requested}
        unknown -> {:error, "tools not available to the caller: #{Enum.join(unknown, ", ")}"}
      end
    end
  end

  # A job may name a skill so the future run executes inside the skill's
  # tool/policy confinement (enforced in Jobs.Runner). Reject unknown skills at
  # create time so the binding can never reference a skill that does not exist.
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

  defp caller_visible_tool_names(context) do
    registry =
      Map.get(context, :capability_registry) ||
        FermixCore.Capabilities.Registry

    opts =
      []
      |> maybe_put(:trust, Map.get(context, :source_trust))

    registry
    |> CapabilityRegistry.list(opts)
    |> Enum.map(& &1.name)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # A scheduled job inherits its creator's trust. A context with no
  # source_trust cannot create jobs — surface a clear tool error to the model
  # instead of minting a trust the caller never had.
  defp require_source_trust(context) do
    case Map.get(context, :source_trust) do
      trust when is_atom(trust) and not is_nil(trust) ->
        {:ok, Atom.to_string(trust)}

      _absent ->
        {:error,
         "schedule_job requires a source_trust in context; this context cannot create scheduled jobs."}
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
