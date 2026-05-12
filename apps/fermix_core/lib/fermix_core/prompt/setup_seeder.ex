defmodule FermixCore.Prompt.SetupSeeder do
  @moduledoc """
  Setup-time seeder for bootstrap and prompt-memory files.

  Called from `Setup.Wizard` finalization. The only path that writes
  `IDENTITY.md`, `AGENTS.md`, `SOUL.md`, `REALTIME.md`, `USER.md`, and
  `MEMORY.md`. Read-side fallbacks (`Prompt.Defaults`) never write to disk.

  Per-file rule: if the target file already exists, skip writing — operator
  edits and prior seeds are preserved. Otherwise render the template, write
  atomically (temp + rename), then commit a `:seed` revision. If the commit
  fails after a successful write, return `:seeded_uncommitted` rather than
  aborting — `BootstrapLoader.load/1` will self-heal the missing revision on
  the next read via the `:imported` path.

  The seeder also upserts wizard-supplied identity and preference rows into
  `Memory.Repo` so future `PromptFiles.rebuild/2` runs reproduce the same
  USER.md / MEMORY.md content from durable memory.
  """

  alias FermixCore.Memory.Config
  alias FermixCore.Memory.PromptFiles
  alias FermixCore.Memory.Repo, as: MemoryRepo
  alias FermixCore.Prompt.BootstrapPaths
  alias FermixCore.Prompt.TemplateRenderer
  alias FermixCore.Resource.Registry

  require Logger

  @type seeded_file :: %{
          name: :identity | :agents | :soul | :realtime | :user | :memory,
          path: String.t(),
          outcome: :seeded | :skipped_exists | :seeded_uncommitted,
          revision_id: integer() | nil
        }

  @type personalization :: %{
          optional(:user_name) => String.t(),
          optional(:timezone) => String.t(),
          optional(:communication_style) => String.t()
        }

  @placeholder_user_name "there"
  @placeholder_timezone "UTC"
  @placeholder_communication_style "neutral and direct"

  @spec seed(personalization(), keyword()) :: {:ok, [seeded_file()]} | {:error, term()}
  def seed(personalization, opts \\ []) when is_map(personalization) and is_list(opts) do
    agent_id = Keyword.get(opts, :agent_id, Config.agent_id(opts))
    owner_id = Keyword.get(opts, :owner_id, Config.owner_id(opts))

    with {:ok, files} <- seed_files(file_specs(agent_id, personalization, opts), agent_id, opts),
         :ok <- seed_user_memories(agent_id, owner_id, personalization, opts) do
      {:ok, files}
    end
  end

  defp file_specs(agent_id, personalization, opts) do
    user_assigns = %{
      user_name: Map.get(personalization, :user_name, @placeholder_user_name),
      timezone: Map.get(personalization, :timezone, @placeholder_timezone),
      communication_style:
        Map.get(personalization, :communication_style, @placeholder_communication_style)
    }

    [
      %{
        name: :identity,
        resource_type: :identity_md,
        path: BootstrapPaths.identity_path(agent_id, opts),
        assigns: %{agent_name: agent_name()},
        wizard_inputs: [:agent_name]
      },
      %{
        name: :agents,
        resource_type: :agents_md,
        path: BootstrapPaths.agents_path(agent_id, opts),
        assigns: %{},
        wizard_inputs: []
      },
      %{
        name: :soul,
        resource_type: :soul_md,
        path: BootstrapPaths.soul_path(agent_id, opts),
        assigns: %{},
        wizard_inputs: []
      },
      %{
        name: :realtime,
        resource_type: :realtime_md,
        path: BootstrapPaths.realtime_path(agent_id, opts),
        assigns: %{},
        wizard_inputs: []
      },
      %{
        name: :user,
        resource_type: :user_md,
        path: PromptFiles.user_path(agent_id),
        assigns: user_assigns,
        wizard_inputs: [:user_name, :timezone, :communication_style]
      },
      %{
        name: :memory,
        resource_type: :memory_md,
        path: PromptFiles.memory_path(agent_id),
        assigns: %{},
        wizard_inputs: []
      }
    ]
  end

  defp seed_files(specs, agent_id, opts) do
    specs
    |> Enum.reduce_while([], fn spec, acc ->
      case seed_file(spec, agent_id, opts) do
        {:ok, result} -> {:cont, [result | acc]}
        error -> {:halt, error}
      end
    end)
    |> case do
      list when is_list(list) -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  defp seed_file(spec, agent_id, opts) do
    started_at = System.monotonic_time(:millisecond)

    if File.exists?(spec.path) do
      emit_seed_telemetry(spec, agent_id, :skipped_exists, 0, nil, started_at)
      {:ok, %{name: spec.name, path: spec.path, outcome: :skipped_exists, revision_id: nil}}
    else
      do_seed_file(spec, agent_id, opts, started_at)
    end
  end

  defp do_seed_file(spec, agent_id, opts, started_at) do
    with {:ok, content} <- TemplateRenderer.render(spec.name, spec.assigns),
         :ok <- write_atomically(spec.path, content) do
      commit_seed(spec, content, agent_id, opts, started_at)
    end
  end

  defp commit_seed(spec, content, agent_id, opts, started_at) do
    commit_opts =
      opts
      |> registry_opts()
      |> Keyword.merge(
        mutation_source: :seed,
        provenance: seed_provenance(spec.name, spec.wizard_inputs),
        resource_path: spec.path
      )

    case Registry.commit(agent_id, spec.resource_type, "global", content, commit_opts) do
      {:ok, :unchanged} ->
        finish_commit(spec, agent_id, byte_size(content), nil, started_at)

      {:ok, revision} ->
        finish_commit(spec, agent_id, byte_size(content), revision.id, started_at)

      {:error, reason} ->
        Logger.warning(
          "prompt setup seed wrote #{spec.path} but commit failed: #{inspect(reason)}"
        )

        emit_seed_telemetry(
          spec,
          agent_id,
          :seeded_uncommitted,
          byte_size(content),
          nil,
          started_at
        )

        {:ok, %{name: spec.name, path: spec.path, outcome: :seeded_uncommitted, revision_id: nil}}
    end
  end

  defp finish_commit(spec, agent_id, bytes, revision_id, started_at) do
    emit_seed_telemetry(spec, agent_id, :seeded, bytes, revision_id, started_at)
    {:ok, %{name: spec.name, path: spec.path, outcome: :seeded, revision_id: revision_id}}
  end

  defp write_atomically(path, content) do
    temp = "#{path}.tmp-#{System.unique_integer([:positive, :monotonic])}"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temp, content),
         :ok <- File.rename(temp, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(temp)
        {:error, {:write_failed, path, reason}}
    end
  end

  defp seed_user_memories(agent_id, owner_id, personalization, opts) do
    started_at = System.monotonic_time(:millisecond)
    rows = user_memory_rows(agent_id, owner_id, personalization)

    case upsert_rows(rows, opts) do
      :ok ->
        :telemetry.execute(
          [:fermix, :prompt, :seed_user_memories],
          %{count: length(rows), duration_ms: elapsed_ms(started_at)},
          %{agent_id: agent_id, owner_id: owner_id}
        )

        :ok

      {:error, reason} = error ->
        Logger.warning("prompt setup seed user-memory upsert failed: #{inspect(reason)}")
        error
    end
  end

  defp upsert_rows([], _opts), do: :ok

  defp upsert_rows([row | rest], opts) do
    case MemoryRepo.upsert_memory(row, repo_opts(opts)) do
      {:ok, _row} -> upsert_rows(rest, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp user_memory_rows(agent_id, owner_id, personalization) do
    base = %{
      agent_id: agent_id,
      owner_id: owner_id,
      source_message_id: nil
    }

    [
      Map.merge(base, %{
        scope_type: "owner",
        scope_id: owner_id,
        category: "identity",
        key: "name",
        value: Map.get(personalization, :user_name, @placeholder_user_name),
        promote_target: "user_md"
      }),
      Map.merge(base, %{
        scope_type: "owner",
        scope_id: owner_id,
        category: "identity",
        key: "timezone",
        value: Map.get(personalization, :timezone, @placeholder_timezone),
        promote_target: "user_md"
      }),
      Map.merge(base, %{
        scope_type: "owner",
        scope_id: owner_id,
        category: "preference",
        key: "communication style",
        value: Map.get(personalization, :communication_style, @placeholder_communication_style),
        promote_target: "user_md"
      }),
      Map.merge(base, %{
        scope_type: "agent",
        scope_id: agent_id,
        category: "identity",
        key: "agent name",
        value: agent_name(),
        promote_target: "memory_md"
      })
    ]
  end

  defp emit_seed_telemetry(spec, agent_id, outcome, bytes, revision_id, started_at) do
    :telemetry.execute(
      [:fermix, :prompt, :seed],
      %{bytes: bytes, duration_ms: elapsed_ms(started_at)},
      %{
        agent_id: agent_id,
        name: spec.name,
        template: template_filename(spec.name),
        path: spec.path,
        outcome: outcome,
        revision_id: revision_id
      }
    )
  end

  defp seed_provenance(name, wizard_inputs) do
    %{
      trigger: "setup_seed",
      template: template_filename(name),
      wizard_inputs: Enum.map(wizard_inputs, &Atom.to_string/1)
    }
  end

  defp template_filename(name) when is_atom(name), do: "#{name}.md.eex"

  defp registry_opts(opts) do
    opts
    |> Keyword.take([:repo, :server])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp repo_opts(opts) do
    case Keyword.get(opts, :repo, Keyword.get(opts, :server)) do
      nil -> Keyword.take(opts, [:timeout])
      server -> [server: server] ++ Keyword.take(opts, [:timeout])
    end
  end

  defp elapsed_ms(started_at) do
    System.monotonic_time(:millisecond) - started_at
  end

  defp agent_name do
    :fermix_core
    |> Application.get_env(:agent, [])
    |> Keyword.get(:name, "fermix")
  end
end
