defmodule FermixCore.Memory.PromptFiles do
  @moduledoc """
  Maintains bounded prompt-memory markdown files derived from durable memory rows.
  """

  alias FermixCore.Memory.Admission
  alias FermixCore.Memory.Config
  alias FermixCore.Memory.Repo
  alias FermixCore.Resource.Registry

  require Logger

  @type prompt_memory :: %{
          user: String.t() | nil,
          memory: String.t() | nil
        }

  @type memory_row :: Repo.memory_row()

  @user_sections ["Identity", "Preferences", "Ongoing Goals", "Additional Context"]
  @memory_sections ["Environment", "Project Context", "Working Rules", "Additional Context"]

  @spec user_path(String.t()) :: String.t()
  def user_path(agent_id) when is_binary(agent_id) do
    Path.join([Config.prompt_base_dir(), agent_id, "USER.md"])
  end

  @spec memory_path(String.t()) :: String.t()
  def memory_path(agent_id) when is_binary(agent_id) do
    Path.join([Config.prompt_base_dir(), agent_id, "MEMORY.md"])
  end

  @spec load(String.t()) :: {:ok, prompt_memory()} | {:error, term()}
  def load(agent_id) when is_binary(agent_id) do
    with {:ok, user} <- read_document(user_path(agent_id)),
         {:ok, memory} <- read_document(memory_path(agent_id)) do
      {:ok, %{user: user, memory: memory}}
    end
  end

  @spec rebuild(String.t(), String.t()) :: {:ok, prompt_memory()} | {:error, term()}
  def rebuild(agent_id, owner_id) when is_binary(agent_id) and is_binary(owner_id) do
    rebuild(agent_id, owner_id, :periodic, [])
  end

  @spec rebuild(String.t(), String.t(), atom(), keyword()) ::
          {:ok, prompt_memory()} | {:error, term()}
  def rebuild(agent_id, owner_id, reason, opts)
      when is_binary(agent_id) and is_binary(owner_id) and is_atom(reason) and is_list(opts) do
    with {:ok, memories} <- load_memories(agent_id, owner_id) do
      user = render_user_document(memories)
      memory = render_memory_document(memories)

      with :ok <- write_document(user_path(agent_id), user),
           :ok <- write_document(memory_path(agent_id), memory) do
        capture_revisions(agent_id, reason, opts, user, memory)
        {:ok, %{user: normalize_content(user), memory: normalize_content(memory)}}
      end
    end
  end

  defp load_memories(agent_id, owner_id) do
    case Repo.get_memories(
           %{agent_id: agent_id, owner_id: owner_id, archived?: false},
           server: Config.repo_server()
         ) do
      {:ok, memories} -> {:ok, memories}
      {:error, :disabled} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  defp render_user_document(memories) do
    memories
    |> select_user_memories()
    |> sectioned_items(:user)
    |> build_document(:user, Config.prompt_user_token_cap())
  end

  defp render_memory_document(memories) do
    memories
    |> select_memory_memories()
    |> sectioned_items(:memory)
    |> build_document(:memory, Config.prompt_memory_token_cap())
  end

  defp select_user_memories(memories) do
    # USER.md is intentionally owner-scoped because it is injected as direct
    # user preference/identity context; MEMORY.md may carry broader promoted
    # agent/project facts that are safe to share across that agent's prompts.
    memories
    |> Enum.filter(&(&1.scope_type == "owner" and Admission.prompt_target(&1) == "user_md"))
    |> dedupe_rows()
  end

  defp select_memory_memories(memories) do
    memories
    |> Enum.filter(&(Admission.prompt_target(&1) == "memory_md"))
    |> dedupe_rows()
  end

  defp dedupe_rows(rows) do
    {deduped, _seen} =
      Enum.reduce(rows, {[], MapSet.new()}, fn row, {acc, seen} ->
        marker = {row.scope_type, row.scope_id, row.key}

        if MapSet.member?(seen, marker) do
          {acc, seen}
        else
          {[row | acc], MapSet.put(seen, marker)}
        end
      end)

    Enum.reverse(deduped)
  end

  defp sectioned_items(rows, kind) do
    rows
    |> Enum.reduce(empty_sections(kind), fn row, acc ->
      section = section_name(kind, row.category)
      item = format_item(row)
      Map.update!(acc, section, fn items -> [item | items] end)
    end)
    |> ordered_sections(kind)
  end

  defp empty_sections(:user), do: Map.new(@user_sections, &{&1, []})
  defp empty_sections(:memory), do: Map.new(@memory_sections, &{&1, []})

  defp ordered_sections(section_map, kind) do
    kind
    |> section_titles()
    |> Enum.map(fn title -> {title, section_map |> Map.fetch!(title) |> Enum.reverse()} end)
    |> Enum.reject(fn {_title, items} -> items == [] end)
  end

  defp build_document([], _kind, _token_cap), do: ""

  defp build_document(sectioned_items, kind, token_cap) do
    flat_items =
      for {section, items} <- sectioned_items,
          item <- items do
        {section, item}
      end

    flat_items
    |> fitting_item_count(token_cap, section_titles(kind))
    |> then(&Enum.take(flat_items, &1))
    |> compose_document(section_titles(kind))
  end

  defp fitting_item_count(flat_items, token_cap, _section_order) do
    max_bytes = token_cap * 4

    {_bytes, count, _seen_sections} =
      Enum.reduce_while(flat_items, {0, 0, MapSet.new()}, fn {section, item},
                                                             {bytes, count, seen_sections} ->
        next_bytes = bytes + added_item_bytes(section, item, bytes, seen_sections)

        if next_bytes <= max_bytes do
          {:cont, {next_bytes, count + 1, MapSet.put(seen_sections, section)}}
        else
          {:halt, {bytes, count, seen_sections}}
        end
      end)

    count
  end

  defp compose_document([], _section_order), do: ""

  defp compose_document(flat_items, section_order) do
    section_map =
      Enum.reduce(flat_items, %{}, fn {section, item}, acc ->
        Map.update(acc, section, [item], fn items -> [item | items] end)
      end)

    section_order
    |> Enum.map(&render_section(&1, section_items(section_map, &1)))
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp section_items(section_map, title) do
    section_map
    |> Map.get(title, [])
    |> Enum.reverse()
  end

  defp added_item_bytes(section, item, current_bytes, seen_sections) do
    item_bytes = byte_size("- #{item}")

    if MapSet.member?(seen_sections, section) do
      byte_size("\n") + item_bytes
    else
      section_separator_bytes(current_bytes) + byte_size("## #{section}\n") + item_bytes
    end
  end

  defp section_separator_bytes(0), do: 0
  defp section_separator_bytes(_current_bytes), do: byte_size("\n\n")

  defp render_section(_title, []), do: nil

  defp render_section(title, items) do
    "## #{title}\n" <> Enum.map_join(items, "\n", &"- #{&1}")
  end

  defp section_titles(:user), do: @user_sections
  defp section_titles(:memory), do: @memory_sections

  defp section_name(:user, "identity"), do: "Identity"
  defp section_name(:user, "preference"), do: "Preferences"
  defp section_name(:user, "goal"), do: "Ongoing Goals"
  defp section_name(:user, _category), do: "Additional Context"

  defp section_name(:memory, "environment"), do: "Environment"
  defp section_name(:memory, "project"), do: "Project Context"
  defp section_name(:memory, "goal"), do: "Project Context"
  defp section_name(:memory, "instruction"), do: "Working Rules"
  defp section_name(:memory, "correction"), do: "Working Rules"
  defp section_name(:memory, "preference"), do: "Working Rules"
  defp section_name(:memory, _category), do: "Additional Context"

  defp format_item(row) do
    "#{normalize_inline(row.key)}: #{normalize_inline(row.value)}"
  end

  defp normalize_inline(text) do
    text
    |> String.replace(~r/[_-]+/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp write_document(path, content) do
    temp_path = temp_path(path)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temp_path, content),
         :ok <- File.rename(temp_path, path) do
      :ok
    else
      {:error, _reason} = error ->
        File.rm(temp_path)
        error
    end
  end

  defp temp_path(path) do
    suffix = System.unique_integer([:positive, :monotonic])
    "#{path}.tmp-#{suffix}"
  end

  defp read_document(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, normalize_content(content)}
      {:error, :enoent} -> {:ok, nil}
      {:error, reason} -> read_failed(path, reason)
    end
  end

  defp read_failed(path, reason) do
    Logger.warning("prompt memory file read failed for #{path}: #{inspect(reason)}")
    {:ok, nil}
  end

  defp capture_revisions(agent_id, reason, opts, user, memory) do
    source = mutation_source(reason)
    provenance = revision_provenance(source, reason, Keyword.get(opts, :provenance))

    capture_revision(agent_id, :user_md, user_path(agent_id), user, source, provenance, opts)

    capture_revision(
      agent_id,
      :memory_md,
      memory_path(agent_id),
      memory,
      source,
      provenance,
      opts
    )
  end

  defp capture_revision(agent_id, resource_type, path, content, source, provenance, opts) do
    commit_opts =
      opts
      |> registry_opts()
      |> Keyword.merge(
        mutation_source: source,
        provenance: provenance,
        resource_path: path
      )

    case Registry.commit(agent_id, resource_type, "global", content, commit_opts) do
      {:ok, _revision_or_unchanged} ->
        :ok

      {:error, :disabled} ->
        :ok

      {:error, reason} ->
        Logger.warning("prompt memory revision capture failed for #{path}: #{inspect(reason)}")
        :ok
    end
  end

  defp mutation_source(:event), do: :extraction_rebuild
  defp mutation_source(:periodic), do: :scheduler_rebuild
  defp mutation_source(_reason), do: :scheduler_rebuild

  defp registry_opts(opts) do
    case Keyword.get(opts, :repo, Keyword.get(opts, :server)) do
      nil -> [repo: Config.repo_server()]
      repo -> [repo: repo]
    end
  end

  defp revision_provenance(:extraction_rebuild, _reason, provenance) when is_map(provenance) do
    provenance
    |> Map.new()
    |> Map.put_new(:trigger, "extraction_rebuild")
    |> Map.put_new(:description, "Prompt file rebuild triggered by memory extraction")
  end

  defp revision_provenance(:extraction_rebuild, _reason, _provenance) do
    %{
      trigger: "extraction_rebuild",
      description: "Prompt file rebuild triggered by memory extraction"
    }
  end

  defp revision_provenance(:scheduler_rebuild, reason, provenance) when is_map(provenance) do
    provenance
    |> Map.new()
    |> Map.put_new(:trigger, "scheduler_rebuild")
    |> Map.put_new(:rebuild_reason, Atom.to_string(reason))
    |> Map.put_new(:description, "Periodic prompt file rebuild under current policy")
  end

  defp revision_provenance(:scheduler_rebuild, reason, _provenance) do
    %{
      trigger: "scheduler_rebuild",
      rebuild_reason: Atom.to_string(reason),
      description: "Periodic prompt file rebuild under current policy"
    }
  end

  defp normalize_content(content) do
    case String.trim(content) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
