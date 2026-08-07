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
         {:ok, skill_dir} <- scaffold(%{name: skill_name, description: description}) do
      Support.success_json(%{created: true, path: skill_dir})
    else
      {:error, reason} when is_binary(reason) -> Support.error(reason)
      {:error, reason} -> Support.error("skill_create failed: #{inspect(reason)}")
    end
  end

  @doc """
  Shared scaffold writer (MILESTONE_26_SKILL_CURATION §6.8): one writer, two
  callers — this tool passes no `:body` and gets the placeholder; the curation
  Creator passes the drafted body. All validation (name regex, the
  leading-underscore reservation, existing-dir refusal) lives here so the two
  paths can never drift. `attrs` takes `:name`, `:description`, optional
  `:body` (markdown below the frontmatter) and optional `:home` (skills root
  override for tests).
  """
  @spec scaffold(map()) :: {:ok, String.t()} | {:error, String.t() | term()}
  def scaffold(%{name: skill_name, description: description} = attrs)
      when is_binary(skill_name) and is_binary(description) do
    with :ok <- validate_name(skill_name),
         {:ok, skill_dir} <- prepare_skill_dir(skill_name, Map.get(attrs, :home)),
         :ok <-
           write_skill(
             skill_dir,
             skill_name,
             frontmatter_line(description),
             Map.get(attrs, :body)
           ),
         :ok <- write_evals(skill_dir, skill_name) do
      {:ok, skill_dir}
    end
  end

  # The description is interpolated into YAML frontmatter and may be
  # model-authored: collapse it to one bounded line so an embedded newline or
  # `---` can never terminate the frontmatter early and drop `allowed_tools`.
  defp frontmatter_line(description) do
    description
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 300)
  end

  # Leading-underscore names are reserved for non-skill directories under the
  # skills root (`_archive/` holds archived skills the discovery glob must never
  # see — MILESTONE_26_SKILL_CURATION §6.4/§6.9), so they can never become live
  # skills.
  defp validate_name("_" <> _rest) do
    {:error, "invalid_name: names starting with underscore are reserved"}
  end

  defp validate_name(name) do
    if String.match?(name, ~r/^[a-zA-Z0-9_-]{1,64}\z/) do
      :ok
    else
      {:error, "invalid_name: use letters, digits, underscore, or hyphen, max 64 chars"}
    end
  end

  defp prepare_skill_dir(name, home) do
    skill_dir = Path.join(home || ConfigStore.workspace_paths().skills, name)

    if File.exists?(skill_dir) do
      {:error, "already exists: #{skill_dir}"}
    else
      case File.mkdir_p(skill_dir) do
        :ok -> {:ok, skill_dir}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp write_skill(skill_dir, name, description, body) do
    content = """
    ---
    name: #{name}
    description: #{description}
    allowed_tools: []
    ---

    #{body || placeholder_body(name, description)}\
    """

    File.write(Path.join(skill_dir, "SKILL.md"), content)
  end

  defp placeholder_body(name, description) do
    """
    # #{name}

    #{description}

    Replace this body with the operating instructions for the skill.
    """
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
