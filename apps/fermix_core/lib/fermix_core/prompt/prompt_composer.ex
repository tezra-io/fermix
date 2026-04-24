defmodule FermixCore.Prompt.PromptComposer do
  @moduledoc """
  Composes file-backed and generated prompt parts into ordered system messages.
  """

  alias FermixCore.Memory.PromptFiles
  alias FermixCore.Prompt.Accounting
  alias FermixCore.Prompt.BootstrapLoader
  alias FermixCore.Prompt.RuntimeSections

  @type message :: %{role: String.t(), content: String.t()}

  @type prompt_part :: %{
          name: :soul | :agents | :user | :memory | :runtime,
          kind: :bootstrap | :prompt_memory | :generated,
          source_path: String.t() | nil,
          content: String.t(),
          exported_role: String.t()
        }

  @type composition :: %{
          messages: [message()],
          parts: [prompt_part()],
          accounting: [Accounting.entry()]
        }

  @spec compose(keyword()) :: {:ok, [message()]} | {:error, term()}
  def compose(opts) when is_list(opts) do
    with {:ok, result} <- compose_with_metadata(opts) do
      {:ok, result.messages}
    end
  end

  @spec compose_with_metadata(keyword()) :: {:ok, composition()} | {:error, term()}
  def compose_with_metadata(opts) when is_list(opts) do
    agent_id = Keyword.get(opts, :agent_id, "main")
    available_skills = Keyword.get(opts, :available_skills, [])

    with {:ok, bootstrap} <- BootstrapLoader.load(agent_id, opts),
         {:ok, prompt_memory} <- PromptFiles.load(agent_id) do
      parts = build_parts(agent_id, bootstrap, prompt_memory, available_skills)

      {:ok,
       %{
         messages: Enum.map(parts, &export_message/1),
         parts: parts,
         accounting: Enum.map(parts, &accounting_entry/1)
       }}
    end
  end

  defp build_parts(agent_id, bootstrap, prompt_memory, available_skills) do
    [
      bootstrap_part(:soul, :bootstrap, bootstrap.soul),
      bootstrap_part(:agents, :bootstrap, bootstrap.agents),
      memory_part(:user, PromptFiles.user_path(agent_id), prompt_memory.user),
      memory_part(:memory, PromptFiles.memory_path(agent_id), prompt_memory.memory),
      runtime_part(available_skills)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp bootstrap_part(_name, _kind, nil), do: nil

  defp bootstrap_part(name, kind, file) do
    part(name, kind, file.path, file.content)
  end

  defp memory_part(_name, _path, nil), do: nil

  defp memory_part(name, path, content) do
    part(name, :prompt_memory, path, content)
  end

  defp runtime_part(available_skills) do
    part(:runtime, :generated, nil, RuntimeSections.build(available_skills))
  end

  defp part(name, kind, source_path, content) do
    %{
      name: name,
      kind: kind,
      source_path: source_path,
      content: content,
      exported_role: "system"
    }
  end

  defp export_message(part) do
    %{role: part.exported_role, content: part.content}
  end

  defp accounting_entry(part) do
    Accounting.entry(part.name, part.source_path, part.content)
  end
end
