defmodule FermixCore.Release.Tree do
  @moduledoc false

  import Bitwise

  @max_depth 32
  @max_entries 30_000
  @max_symlink_hops 64
  @chunk_bytes 64 * 1024

  @type entry :: %{
          optional(:target) => String.t(),
          absolute: String.t(),
          path: String.t(),
          type: :directory | :file | :symlink,
          mode: non_neg_integer()
        }

  @spec scan(String.t(), keyword()) :: {:ok, [entry()]} | {:error, term()}
  def scan(root, opts \\ []) when is_binary(root) and is_list(opts) do
    excluded = Keyword.get(opts, :exclude, []) |> MapSet.new()
    expanded = Path.expand(root)

    with true <- Path.type(root) == :absolute,
         true <- File.dir?(expanded),
         {:ok, nodes, _count} <- walk(expanded, expanded, 0, 0, [], excluded) do
      {:ok, Enum.sort_by(nodes, & &1.path)}
    else
      false -> {:error, :invalid_release_root}
      {:error, _reason} = error -> error
    end
  end

  @spec digest([entry()]) :: {:ok, String.t()} | {:error, term()}
  def digest(nodes) when is_list(nodes) do
    Enum.reduce_while(nodes, {:ok, :crypto.hash_init(:sha256)}, fn node, {:ok, hash} ->
      case digest_record(node) do
        {:ok, record} -> {:cont, {:ok, :crypto.hash_update(hash, record)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, hash} -> {:ok, hash |> :crypto.hash_final() |> Base.encode16(case: :lower)}
      {:error, _reason} = error -> error
    end
  end

  @spec file_sha256(String.t()) :: {:ok, String.t()} | {:error, term()}
  def file_sha256(path) when is_binary(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} -> hash_open_file(io)
      {:error, reason} -> {:error, {:file_read_failed, reason}}
    end
  end

  defp walk(_root, _dir, depth, _count, _nodes, _excluded) when depth > @max_depth,
    do: {:error, :release_tree_too_deep}

  defp walk(root, dir, depth, count, nodes, excluded) do
    case File.ls(dir) do
      {:ok, names} -> walk_names(Enum.sort(names), root, dir, depth, count, nodes, excluded)
      {:error, reason} -> {:error, {:directory_read_failed, relative(root, dir), reason}}
    end
  end

  defp walk_names(names, root, dir, depth, count, nodes, excluded) do
    Enum.reduce_while(names, {:ok, nodes, count}, fn name, {:ok, acc, seen} ->
      if seen >= @max_entries do
        {:halt, {:error, :release_tree_too_large}}
      else
        path = Path.join(dir, name)
        rel = relative(root, path)
        step_node(path, rel, root, depth, seen + 1, acc, excluded)
      end
    end)
  end

  defp step_node(path, rel, root, depth, count, nodes, excluded) do
    case File.lstat(path, time: :posix) do
      {:ok, %{type: :directory, mode: mode}} ->
        node = %{absolute: path, path: rel, type: :directory, mode: band(mode, 0o7777)}
        next_nodes = maybe_add(node, nodes, excluded)
        continue_walk(root, path, depth + 1, count, next_nodes, excluded)

      {:ok, %{type: :regular, mode: mode}} ->
        node = %{absolute: path, path: rel, type: :file, mode: band(mode, 0o7777)}
        {:cont, {:ok, maybe_add(node, nodes, excluded), count}}

      {:ok, %{type: :symlink}} ->
        continue_symlink(path, rel, root, count, nodes, excluded)

      {:ok, %{type: type}} ->
        {:halt, {:error, {:unsupported_tree_entry, rel, type}}}

      {:error, reason} ->
        {:halt, {:error, {:entry_stat_failed, rel, reason}}}
    end
  end

  defp continue_walk(root, path, depth, count, nodes, excluded) do
    case walk(root, path, depth, count, nodes, excluded) do
      {:ok, next_nodes, next_count} -> {:cont, {:ok, next_nodes, next_count}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp continue_symlink(path, rel, root, count, nodes, excluded) do
    with {:ok, target} <- File.read_link(path),
         :ok <- relative_symlink_target(target, rel),
         {:ok, canonical_root} <- canonical_host_path(root),
         {:ok, target_path} <- initial_symlink_target(path, target, root, canonical_root),
         {:ok, _resolved} <- resolve_release_path(target_path, canonical_root) do
      node = %{
        absolute: path,
        path: rel,
        type: :symlink,
        mode: 0o777,
        target: target
      }

      {:cont, {:ok, maybe_add(node, nodes, excluded), count}}
    else
      {:error, :escape} -> {:halt, {:error, {:symlink_escapes_root, rel}}}
      {:error, :enoent} -> {:halt, {:error, {:symlink_target_missing, rel}}}
      {:error, :absolute_target} -> {:halt, {:error, {:symlink_absolute_target, rel}}}
      {:error, :resolution_limit} -> {:halt, {:error, {:symlink_resolution_limit, rel}}}
      {:error, {:symlink_absolute_target, ^rel}} = error -> {:halt, error}
      {:error, reason} -> {:halt, {:error, {:symlink_validation_failed, rel, reason}}}
    end
  end

  defp initial_symlink_target(path, target, root, canonical_root) do
    expanded = Path.expand(target, Path.dirname(path))

    if inside_root?(root, expanded) do
      {:ok, Path.join(canonical_root, Path.relative_to(expanded, root))}
    else
      {:error, :escape}
    end
  end

  defp resolve_release_path(path, root) do
    relative = Path.relative_to(path, root)

    if relative == ".." or String.starts_with?(relative, "../") do
      {:error, :escape}
    else
      resolve_release_components(root, path_components(relative), root, 0)
    end
  end

  defp resolve_release_components(current, [], _root, _hops), do: {:ok, current}

  defp resolve_release_components(current, [part | rest], root, hops) do
    candidate = Path.join(current, part)

    case File.lstat(candidate) do
      {:ok, %{type: :symlink}} -> follow_release_symlink(candidate, rest, root, hops)
      {:ok, _stat} -> resolve_release_components(candidate, rest, root, hops)
      {:error, reason} -> {:error, reason}
    end
  end

  defp follow_release_symlink(_candidate, _rest, _root, hops)
       when hops >= @max_symlink_hops,
       do: {:error, :resolution_limit}

  defp follow_release_symlink(candidate, rest, root, hops) do
    with {:ok, target} <- File.read_link(candidate),
         false <- Path.type(target) == :absolute,
         expanded = Path.expand(target, Path.dirname(candidate)),
         true <- inside_root?(root, expanded) do
      components = path_components(Path.relative_to(expanded, root)) ++ rest
      resolve_release_components(root, components, root, hops + 1)
    else
      true -> {:error, :absolute_target}
      false -> {:error, :escape}
      {:error, reason} -> {:error, reason}
    end
  end

  defp canonical_host_path(path) do
    resolve_host_components("/", path |> Path.expand() |> path_components(), 0)
  end

  defp resolve_host_components(current, [], _hops), do: {:ok, current}

  defp resolve_host_components(_current, _parts, hops) when hops >= @max_symlink_hops,
    do: {:error, :resolution_limit}

  defp resolve_host_components(current, [part | rest], hops) do
    candidate = Path.join(current, part)

    case File.lstat(candidate) do
      {:ok, %{type: :symlink}} -> follow_host_symlink(candidate, rest, hops)
      {:ok, _stat} -> resolve_host_components(candidate, rest, hops)
      {:error, reason} -> {:error, reason}
    end
  end

  defp follow_host_symlink(candidate, rest, hops) do
    case File.read_link(candidate) do
      {:ok, target} ->
        expanded = Path.expand(target, Path.dirname(candidate))
        resolve_host_components("/", path_components(expanded) ++ rest, hops + 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp path_components(path), do: Enum.reject(Path.split(path), &(&1 in ["/", "."]))

  defp relative_symlink_target(target, rel) do
    if Path.type(target) == :absolute,
      do: {:error, {:symlink_absolute_target, rel}},
      else: :ok
  end

  defp maybe_add(node, nodes, excluded) do
    if MapSet.member?(excluded, node.path), do: nodes, else: [node | nodes]
  end

  defp digest_record(%{type: :directory} = node) do
    {:ok, ["directory\0", node.path, "\0", mode(node.mode), "\n"]}
  end

  defp digest_record(%{type: :file} = node) do
    case file_sha256(node.absolute) do
      {:ok, digest} -> {:ok, ["file\0", node.path, "\0", mode(node.mode), "\0", digest, "\n"]}
      {:error, reason} -> {:error, {:tree_digest_failed, node.path, reason}}
    end
  end

  defp digest_record(%{type: :symlink} = node) do
    {:ok, ["symlink\0", node.path, "\0", mode(node.mode), "\0", node.target, "\n"]}
  end

  defp hash_open_file(io) do
    result = hash_chunks(io, :crypto.hash_init(:sha256))
    close_result = File.close(io)

    case {result, close_result} do
      {{:ok, hash}, :ok} ->
        {:ok, hash |> :crypto.hash_final() |> Base.encode16(case: :lower)}

      {{:error, _reason} = error, :ok} ->
        error

      {{:ok, _hash}, {:error, reason}} ->
        {:error, {:file_close_failed, reason}}

      {{:error, reason}, {:error, close_reason}} ->
        {:error, {:file_read_and_close_failed, reason, close_reason}}
    end
  end

  defp hash_chunks(io, hash) do
    case IO.binread(io, @chunk_bytes) do
      :eof -> {:ok, hash}
      {:error, reason} -> {:error, {:file_read_failed, reason}}
      chunk -> hash_chunks(io, :crypto.hash_update(hash, chunk))
    end
  end

  defp inside_root?(root, path), do: path == root or String.starts_with?(path, root <> "/")
  defp relative(root, path), do: Path.relative_to(path, root)
  defp mode(value), do: value |> Integer.to_string(8) |> String.pad_leading(4, "0")
end
