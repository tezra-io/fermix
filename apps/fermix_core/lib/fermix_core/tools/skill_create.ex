defmodule FermixCore.Tools.SkillCreate do
  @moduledoc """
  Scaffold a local Fermix skill.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Tools.Support

  @impl true
  def name, do: "skill_create"

  @impl true
  def description, do: "Scaffold a new local Fermix skill with SKILL.md and starter evals."

  @impl true
  def parameters do
    %{
      type: "object",
      required: ["name", "description"],
      properties: %{
        name: %{
          type: "string",
          description: "Skill directory/name using letters, digits, _ or -."
        },
        description: %{type: "string", description: "One-line skill trigger description."}
      }
    }
  end

  @impl true
  def when_to_use, do: "Create a new local skill scaffold under the Fermix skills directory."

  @impl true
  def examples do
    [
      %{
        args: %{"name" => "research_helper", "description" => "Use for focused research."},
        note: "create skill scaffold"
      }
    ]
  end

  @impl true
  def failure_modes do
    [
      %{tag: "invalid_name", description: "name contains unsupported characters"},
      %{tag: "already_exists", description: "skill directory already exists"},
      %{tag: "write_failed", description: "filesystem write failed"}
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :skill_admin

  @impl true
  def execute(args, context) when is_map(args) and is_map(context) do
    Support.run(name(), context, fn -> do_execute(args) end)
  end

  defp do_execute(args) do
    with {:ok, skill_name} <- Support.required_string(args, "name"),
         {:ok, description} <- Support.required_string(args, "description"),
         :ok <- validate_name(skill_name),
         {:ok, skill_dir} <- prepare_skill_dir(skill_name),
         :ok <- write_skill(skill_dir, skill_name, description),
         :ok <- write_evals(skill_dir, skill_name) do
      Support.success_json(%{created: true, path: skill_dir})
    else
      {:error, reason} when is_binary(reason) -> Support.error(reason)
      {:error, reason} -> Support.error("skill_create failed: #{inspect(reason)}")
    end
  end

  defp validate_name(name) do
    if String.match?(name, ~r/^[a-zA-Z0-9_-]{1,64}$/) do
      :ok
    else
      {:error, "invalid_name: use letters, digits, underscore, or hyphen, max 64 chars"}
    end
  end

  defp prepare_skill_dir(name) do
    skill_dir = Path.join(ConfigStore.workspace_paths().skills, name)

    if File.exists?(skill_dir) do
      {:error, "already exists: #{skill_dir}"}
    else
      case File.mkdir_p(skill_dir) do
        :ok -> {:ok, skill_dir}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp write_skill(skill_dir, name, description) do
    content = """
    ---
    name: #{name}
    description: #{description}
    allowed_tools: []
    ---

    # #{name}

    #{description}

    Replace this body with the operating instructions for the skill.
    """

    File.write(Path.join(skill_dir, "SKILL.md"), content)
  end

  defp write_evals(skill_dir, name) do
    eval_dir = Path.join(skill_dir, "evals")

    with :ok <- File.mkdir_p(eval_dir) do
      File.write(
        Path.join(eval_dir, "evals.json"),
        Jason.encode!(eval_payload(name), pretty: true)
      )
    end
  end

  defp eval_payload(name) do
    %{
      "skill" => name,
      "cases" => [
        %{
          "name" => "selects_#{name}",
          "prompt" => "Use #{name} for a small representative task.",
          "expectations" => ["invokes skill #{name}", "does not answer from free-form text only"]
        }
      ]
    }
  end
end
