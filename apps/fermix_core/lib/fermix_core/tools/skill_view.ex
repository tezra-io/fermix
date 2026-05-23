defmodule FermixCore.Tools.SkillView do
  @moduledoc """
  Load a skill body from the live skill registry.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Agents.SkillRegistry
  alias FermixCore.Tools.Support

  @view_max_bytes 65_536
  @name_pattern ~r/^[A-Za-z0-9_-]{1,64}$/

  @impl true
  def name, do: "skill_view"

  @impl true
  def description, do: "Load the full instructions for an installed Fermix skill."

  @impl true
  def parameters do
    %{
      type: "object",
      required: ["name"],
      properties: %{
        name: %{
          type: "string",
          description: "Installed skill name."
        }
      }
    }
  end

  @impl true
  def when_to_use do
    "Use after the Skill Catalog indicates a skill may apply; loads the full SKILL.md body."
  end

  @impl true
  def category, do: :skill_admin

  @impl true
  def execute(args, context) do
    Support.run(name(), context, fn -> do_execute(args, context) end)
  end

  defp do_execute(args, context) do
    with {:ok, skill_name} <- skill_name(args),
         {:ok, definition} <- load_skill(skill_registry(context), skill_name),
         :ok <- within_size_limit(definition.system_prompt) do
      Support.success_json(%{
        name: definition.name,
        description: definition.description,
        trust: definition.trust,
        source_path: definition.source_path,
        body: definition.system_prompt
      })
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

  defp within_size_limit(body) do
    if byte_size(body) <= @view_max_bytes do
      :ok
    else
      {:error,
       "skill_body_too_large: #{byte_size(body)} bytes exceeds #{@view_max_bytes}; " <>
         "split the skill or move long references into separate files"}
    end
  end

  defp skill_registry(context) do
    Map.get(context, :skill_registry, SkillRegistry)
  end
end
