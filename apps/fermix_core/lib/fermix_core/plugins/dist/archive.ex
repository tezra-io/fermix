defmodule FermixCore.Plugins.Dist.Archive do
  @moduledoc """
  Extracts a plugin's `.tar.gz` artifact into a destination directory behind a
  path-traversal + link guard.

  A plugin artifact is fetched from outside the trust boundary, so before
  writing a single file we read the full member table and reject the **whole**
  archive if any member is unsafe:

    * an empty name,
    * an absolute path (`/etc/...`),
    * a path containing a `..` component,
    * a symlink or hardlink member, or
    * a declared uncompressed total over `#{div(100 * 1024 * 1024, 1024 * 1024)} MB`
      (a decompression-bomb / disk-exhaustion guard).

  The verbose tar table exposes each member's TYPE but not a link's target, so
  links are rejected outright — we cannot prove a link stays inside `dest`
  before extraction, so we never extract one. The table also carries each
  member's declared uncompressed size, which (in tar) is exactly the byte count
  that member writes to disk, so summing those sizes bounds total extracted
  bytes without a second decompression pass. Validation runs over the entire
  table first; a single bad member — or an oversized total — aborts the extract
  and nothing is written.

  This is the one genuinely new download primitive in plugin distribution — no
  archive extraction exists elsewhere in core (the binary upgrade swaps a single
  raw executable).
  """

  @typedoc "A `:erl_tar.table/2` verbose entry: `{name, type, size, mtime, mode, uid, gid}`."
  @type verbose_member ::
          {charlist(), atom(), non_neg_integer(), term(), term(), term(), term()}

  # Caps total declared uncompressed bytes. A plugin artifact is a manifest +
  # skills + (vendored) deps; 100 MB is far above any legitimate plugin and far
  # below a disk-exhausting bomb. Defense in depth behind cosign + first-party
  # curation — a signed artifact should never approach this.
  @max_uncompressed_bytes 100 * 1024 * 1024

  @doc """
  Extract `tarball` (a gzip-compressed tar) into `dest`, creating `dest` if
  needed. Returns `:ok`, or `{:error, reason}` where reason is one of
  `{:unsafe_member, kind, name}` (kind ∈ `:invalid_name | :absolute | :traversal | :link`),
  `{:archive_too_large, total_bytes}`, `{:tar_table_failed, _}`, or
  `{:extract_failed, _}`.
  """
  @spec extract(Path.t(), Path.t()) :: :ok | {:error, term()}
  def extract(tarball, dest) when is_binary(tarball) and is_binary(dest) do
    with {:ok, members} <- table(tarball),
         :ok <- validate_members(members) do
      File.mkdir_p!(dest)
      do_extract(tarball, dest)
    end
  end

  defp table(tarball) do
    case :erl_tar.table(String.to_charlist(tarball), [:compressed, :verbose]) do
      {:ok, members} -> {:ok, members}
      {:error, reason} -> {:error, {:tar_table_failed, reason}}
    end
  end

  defp do_extract(tarball, dest) do
    opts = [:compressed, {:cwd, String.to_charlist(dest)}]

    case :erl_tar.extract(String.to_charlist(tarball), opts) do
      :ok -> :ok
      {:error, reason} -> {:error, {:extract_failed, reason}}
    end
  end

  # Validate every member and accumulate declared uncompressed size, halting on
  # the first unsafe member or once the running total exceeds the cap.
  defp validate_members(members) do
    members
    |> Enum.reduce_while({:ok, 0}, fn member, {:ok, total} ->
      with :ok <- validate_member(member),
           {:ok, next} <- accumulate(total, member_size(member)) do
        {:cont, {:ok, next}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _total} -> :ok
      error -> error
    end
  end

  defp accumulate(total, size) do
    next = total + size
    if next > @max_uncompressed_bytes, do: {:error, {:archive_too_large, next}}, else: {:ok, next}
  end

  # The table is always read in :verbose mode (see table/1), so OTP gives a
  # uniform 7-tuple per member — there is no bare-charlist shape to handle.
  defp member_size({_name, _type, size, _mtime, _mode, _uid, _gid}), do: size

  defp validate_member({name, type, _size, _mtime, _mode, _uid, _gid}),
    do: classify(to_string(name), type)

  defp classify("", _type), do: {:error, {:unsafe_member, :invalid_name, ""}}

  defp classify(path, type) do
    cond do
      type in [:symlink, :link] -> {:error, {:unsafe_member, :link, path}}
      absolute?(path) -> {:error, {:unsafe_member, :absolute, path}}
      traversal?(path) -> {:error, {:unsafe_member, :traversal, path}}
      true -> :ok
    end
  end

  defp absolute?(path), do: String.starts_with?(path, "/")

  defp traversal?(path), do: path |> Path.split() |> Enum.any?(&(&1 == ".."))
end
