defmodule FermixCore.Plugins.Dist.TreeDigest do
  @moduledoc """
  `tree_digest_v2` — the unambiguous content digest of an extracted plugin tree
  (M27 §9.3).

  It replaces `Store.h1/1`, which hashed a concatenation of path and content
  with no separators or lengths: `{"ab", "c"}` and `{"a", "bc"}` collide there.
  This digest is what the provenance gate compares the *active installed tree*
  against, and it is bound to the publisher signature transitively (signature
  over the archive → archive bytes → snapshot → this digest). A collision would
  therefore let a different tree present a matching digest, so the framing here
  is explicit — a domain prefix, a file count, and a length prefix on every path
  and body.

      SHA-256(
        "fermix-plugin-tree-v2\\0"
        || u32be(file_count)
        || for each file, in bytewise path order:
             u32be(path_length) || path || u64be(content_length) || content
      )

  Two details are load-bearing and both are pinned by cross-language fixtures
  in `fermix-plugins/scripts/fixtures/tree_digest/`:

    * **Paths normalize to NFC** before they are encoded *or* sorted. macOS
      hands back decomposed (NFD) filenames, Linux hands back what was written;
      without normalization the same artifact hashes differently depending on
      which machine extracted it.
    * **Ordering is bytewise over the whole path**, not per path component. So
      `a` < `a.b` < `a/b` < `ab`, because `.` (0x2E) < `/` (0x2F) < `b` (0x62).

  Directories, empty directories, and filesystem metadata are excluded; safe
  extraction has already refused links and special entries.
  """

  @domain "fermix-plugin-tree-v2\0"

  @type file_map :: %{String.t() => binary()}

  @doc """
  Digest an in-memory `{relative_path => contents}` map — the verified snapshot
  the provenance gate holds, and the shape the golden fixtures use.
  """
  @spec digest_files(file_map()) :: {:ok, String.t()} | {:error, term()}
  def digest_files(files) when is_map(files) do
    with {:ok, normalized} <- normalize_paths(files) do
      {:ok, hash(normalized)}
    end
  end

  @doc """
  Digest a directory on disk. Used for the install-time record and for the
  tamper check against the active tree.
  """
  @spec digest_tree(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def digest_tree(root) when is_binary(root) do
    case File.dir?(root) do
      true -> root |> read_tree() |> digest_files()
      false -> {:error, {:tree_missing, root}}
    end
  end

  defp read_tree(root) do
    root
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.reject(&File.dir?/1)
    |> Map.new(fn path -> {Path.relative_to(path, root), File.read!(path)} end)
  end

  # Normalization can fail on a path that is not valid UTF-8. That is a corrupt
  # or hostile tree, not something to hash around.
  defp normalize_paths(files) do
    Enum.reduce_while(files, {:ok, []}, fn {path, contents}, {:ok, acc} ->
      case :unicode.characters_to_nfc_binary(path) do
        normalized when is_binary(normalized) -> {:cont, {:ok, [{normalized, contents} | acc]}}
        _error -> {:halt, {:error, {:invalid_path_encoding, path}}}
      end
    end)
  end

  defp hash(entries) do
    sorted = Enum.sort_by(entries, &elem(&1, 0), :asc)

    @domain
    |> then(&(:crypto.hash_init(:sha256) |> :crypto.hash_update(&1)))
    |> :crypto.hash_update(<<length(sorted)::unsigned-big-32>>)
    |> then(&Enum.reduce(sorted, &1, fn entry, acc -> update_entry(acc, entry) end))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp update_entry(acc, {path, contents}) do
    acc
    |> :crypto.hash_update(<<byte_size(path)::unsigned-big-32>>)
    |> :crypto.hash_update(path)
    |> :crypto.hash_update(<<byte_size(contents)::unsigned-big-64>>)
    |> :crypto.hash_update(contents)
  end
end
