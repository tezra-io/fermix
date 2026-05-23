defmodule FermixCore.Tools.SkillRun do
  @moduledoc """
  Run an installed skill through the sub-agent execution path.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Agents.SkillRegistry
  alias FermixCore.Capabilities.Skill
  alias FermixCore.Tools.Support

  @name_pattern ~r/^[A-Za-z0-9_-]{1,64}$/

  @impl true
  def name, do: "skill_run"

  @impl true
  def description, do: "Delegate a task to an installed Fermix skill sub-agent."

  @impl true
  def parameters do
    %{
      type: "object",
      required: ["name", "task"],
      properties: %{
        name: %{type: "string", description: "Installed skill name."},
        task: %{type: "string", description: "Clear work request for the skill."},
        context: %{type: "string", description: "Optional parent context for the skill."}
      }
    }
  end

  @impl true
  def when_to_use do
    "Use when a loaded skill should execute as a delegated sub-agent instead of only informing the current turn."
  end

  @impl true
  def category, do: :skill_admin

  @impl true
  def execute(args, context) do
    Support.run(name(), context, fn -> do_execute(args, context) end)
  end

  defp do_execute(args, context) do
    with {:ok, skill_name} <- skill_name(args),
         {:ok, task} <- Support.required_string(args, "task"),
         {:ok, definition} <- load_skill(skill_registry(context), skill_name) do
      skill_args =
        args
        |> Map.take(["context"])
        |> Map.put("task", task)

      Skill.invoke(skill_args, context, definition)
    else
      {:error, reason} -> Support.error(reason)
    end
  end

  defp skill_name(args) do
    with {:ok, value} <- Support.required_string(args, "name"),
         :ok <- validate_name(value) do
      {:ok, value}
    end
  end

  defp validate_name(value) do
    if String.match?(value, @name_pattern) do
      :ok
    else
      {:error, "invalid_skill_name: use letters, digits, underscore, or hyphen, max 64 chars"}
    end
  end

  defp load_skill(registry, name) do
    case SkillRegistry.load(registry, name) do
      {:ok, definition} -> {:ok, definition}
      {:error, {:unknown_skill, _}} -> {:error, "unknown_skill: #{name}"}
    end
  catch
    :exit, reason -> {:error, "skill_registry_unavailable: #{inspect(reason)}"}
  end

  defp skill_registry(context) do
    Map.get(context, :skill_registry, SkillRegistry)
  end
end
