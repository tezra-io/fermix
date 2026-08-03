defmodule FermixCore.Tools.SkillView do
  @moduledoc """
  Load a skill body from the live skill registry.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Agents.SkillRegistry
  alias FermixCore.SkillCuration.Usage
  alias FermixCore.Tools.Support

  @view_max_bytes 65_536
  @name_pattern ~r/^[A-Za-z0-9_-]{1,64}$/

  @impl true
  def name, do: "skill_view"

  @impl true
  def description,
    do:
      "Load the full instructions for an installed Fermix skill, or one of its named reference files."

  @impl true
  def parameters do
    %{
      type: "object",
      required: ["name"],
      properties: %{
        name: %{
          type: "string",
          description: "Installed skill name."
        },
        file: %{
          type: "string",
          description:
            "Optional reference file name (no extension) to load instead of the SKILL.md body, " <>
              "when the skill body points to one."
        }
      }
    }
  end

  @impl true
  def when_to_use do
    "Use after the Skill Catalog indicates a skill may apply; loads the full SKILL.md body. " <>
      "Pass `file` to load a named reference file the skill body points to."
  end

  @impl true
  def category, do: :skill_admin

  @impl true
  def execute(args, context) do
    Support.run(name(), context, fn -> do_execute(args, context) end)
  end

  defp do_execute(args, context) do
    with {:ok, skill_name} <- skill_name(args),
         {:ok, file} <- optional_file(args),
         {:ok, payload} <- build_view(skill_registry(context), skill_name, file) do
      Usage.record_view(skill_name, usage_opts(context))
      Support.success_json(payload)
    else
      {:error, reason} -> Support.error(reason)
    end
  end

  defp build_view(registry, skill_name, nil) do
    with {:ok, definition} <- load_skill(registry, skill_name),
         :ok <- within_size_limit(definition.system_prompt) do
      {:ok,
       %{
         name: definition.name,
         description: definition.description,
         trust: definition.trust,
         source_path: definition.source_path,
         body: definition.system_prompt
       }}
    end
  end

  defp build_view(registry, skill_name, file) do
    with {:ok, body} <- load_reference(registry, skill_name, file),
         :ok <- within_size_limit(body) do
      {:ok, %{name: skill_name, file: file, body: body}}
    end
  end

  defp skill_name(args) do
    with {:ok, value} <- Support.required_string(args, "name"),
         :ok <- validate_name(value) do
      {:ok, value}
    end
  end

  defp optional_file(args) do
    case Map.get(args, "file") do
      nil -> {:ok, nil}
      value -> validate_file(value)
    end
  end

  defp validate_file(value) when is_binary(value) do
    if String.match?(value, @name_pattern) do
      {:ok, value}
    else
      {:error, "invalid_reference_file: use letters, digits, underscore, or hyphen, max 64 chars"}
    end
  end

  defp validate_file(_value), do: {:error, "invalid_reference_file: must be a string"}

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

  defp load_reference(registry, skill_name, file) do
    case SkillRegistry.read_reference(registry, skill_name, file) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, reference_error(reason, skill_name, file)}
    end
  catch
    :exit, reason -> {:error, "skill_registry_unavailable: #{inspect(reason)}"}
  end

  defp reference_error({:unknown_skill, _}, skill_name, _file), do: "unknown_skill: #{skill_name}"

  defp reference_error({:invalid_reference_name, _}, _skill_name, file),
    do: "invalid_reference_file: #{file}"

  defp reference_error({:reference_not_found, _}, skill_name, file),
    do: "reference_not_found: #{skill_name}/#{file}"

  defp reference_error({:read_failed, reason}, _skill_name, _file),
    do: "reference_read_failed: #{inspect(reason)}"

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

  defp usage_opts(context) do
    case Map.get(context, :usage_repo) do
      nil -> []
      repo -> [repo: repo]
    end
  end
end
