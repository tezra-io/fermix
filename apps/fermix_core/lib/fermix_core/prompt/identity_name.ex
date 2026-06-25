defmodule FermixCore.Prompt.IdentityName do
  @moduledoc """
  Boot-time reconcile of each agent's `IDENTITY.md` `**Name:**` line to the
  configured assistant name (`[fermix_core.agent].name`).

  `IDENTITY.md` is seeded once and never rewritten (`Prompt.SetupSeeder` skips
  existing files), so changing the configured name alone never reached the file
  the model reads — the agent kept answering with the originally-seeded name.
  This walks the per-agent bootstrap directories and, when a name is explicitly
  configured and differs from the file's current `**Name:**` value, rewrites
  only that line, preserving every other operator edit.

  Idempotent and fail-soft — safe to call on every boot (sibling to
  `Prompt.BootstrapRename`). A blank/unset configured name is a deliberate
  no-op: it never overwrites a manually-edited IDENTITY.md with a default.
  """

  alias FermixCore.Prompt.BootstrapPaths

  require Logger

  @identity_basename "IDENTITY.md"
  @name_marker "**Name:**"

  @spec reconcile(keyword()) :: :ok
  def reconcile(opts \\ []) when is_list(opts) do
    case configured_name() do
      nil -> :ok
      name -> reconcile_to(name, opts)
    end
  end

  defp reconcile_to(name, opts) do
    dir = BootstrapPaths.bootstrap_dir(opts)

    case File.ls(dir) do
      {:ok, entries} ->
        Enum.each(entries, &reconcile_agent(dir, &1, name))

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning("identity name reconcile scan failed for #{dir}: #{inspect(reason)}")
    end

    :ok
  end

  defp reconcile_agent(dir, agent_id, name) do
    path = Path.join([dir, agent_id, @identity_basename])

    with true <- File.regular?(path),
         {:ok, content} <- File.read(path),
         {:changed, updated} <- rewrite_name(content, name) do
      write(path, updated, name)
    else
      _ -> :ok
    end
  end

  # Rewrite only the first `- **Name:** X` line whose value differs from `name`.
  defp rewrite_name(content, name) do
    lines = String.split(content, "\n")

    case Enum.find_index(lines, &name_line?/1) do
      nil ->
        :unchanged

      idx ->
        line = Enum.at(lines, idx)

        if current_value(line) == name do
          :unchanged
        else
          {:changed, lines |> List.replace_at(idx, set_value(line, name)) |> Enum.join("\n")}
        end
    end
  end

  defp name_line?(line), do: String.contains?(line, @name_marker)

  defp current_value(line) do
    [_prefix, rest] = String.split(line, @name_marker, parts: 2)
    String.trim(rest)
  end

  defp set_value(line, name) do
    [prefix, _rest] = String.split(line, @name_marker, parts: 2)
    "#{prefix}#{@name_marker} #{name}"
  end

  # Atomic rewrite (temp + rename) so a crash mid-write can't corrupt the
  # operator's identity file.
  defp write(path, content, name) do
    temp = "#{path}.tmp-#{System.unique_integer([:positive, :monotonic])}"

    with :ok <- File.write(temp, content),
         :ok <- File.rename(temp, path) do
      Logger.info("reconciled IDENTITY.md name -> #{inspect(name)} at #{path}")
    else
      {:error, reason} ->
        File.rm(temp)
        Logger.warning("identity name reconcile write failed for #{path}: #{inspect(reason)}")
    end
  end

  defp configured_name do
    :fermix_core
    |> Application.get_env(:agent, [])
    |> Keyword.get(:name)
    |> normalize()
  end

  defp normalize(name) when is_binary(name) do
    case String.trim(name) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize(_other), do: nil
end
