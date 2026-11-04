defmodule FermixCore.Home.Archive.Manifest do
  @moduledoc """
  The first entry of a home archive, `manifest.json`: what the archive holds and
  how to check it.

      {"format": 1, "created_at": "…", "primary_epoch": 3, "engine_version": "…",
       "home_root": "/home/operator/.fermix", "host": "macos-aarch64",
       "files": [{"path": "config.toml", "bytes": 812, "sha256": "…", "mode": 384}],
       "links": [{"path": "plugins/installed/notes/current", "target": "1.0.0"}]}

  `home_root` is the absolute path the home had when it was archived, so a
  restore into another path can move the settings that named it, and `host` is
  the OS and architecture it was archived on, so a restore on another one can
  name the installed plugins built for the old one.

  `path` is relative to the home and is the only name a restore writes under:
  one that is absolute, empty, or has an empty, `.` or `..` segment is refused
  as `{:unsafe_path, path}`, and one on the device-local list
  (`FermixCore.Home.DeviceLocal`) as `{:device_local_entry, path}`, so a
  restore can never write outside its root or write `moved.json`. `mode` is
  the file's permission bits, `0` to `0o777`.

  `links` are the home's symbolic links, which a restore recreates as they
  were: an installed plugin's `current` names its version this way. A target
  must be relative and stay inside the home from the link's own directory
  (`safe_link?/2`), and no entry may lie beneath a link, so a restore never
  writes through one; anything else is `{:unsafe_link, path, target}`.

  The archive is bounded: at most 100,000 entries and 1 GiB of file content,
  refused beyond either by name (`{:too_many_files, count, max}`,
  `{:too_many_bytes, total, max}`). The byte bound keeps the tar well inside
  what one seal can hold (`FermixCore.Home.Archive.Seal`). A snapshot
  (`FermixCore.Home.Snapshot`) is encrypted a chunk at a time and lifts the
  byte bound (`decode/2` and `check_bounds/3` with `:infinity`); the entry
  bound holds for both.
  """

  alias FermixCore.BuildInfo
  alias FermixCore.Home.DeviceLocal
  alias FermixCore.Home.Epoch

  @format 1
  @max_files 100_000
  @max_total_bytes 1_073_741_824
  @max_path_bytes 4_096

  @type entry :: %{
          path: String.t(),
          bytes: non_neg_integer(),
          sha256: String.t(),
          mode: non_neg_integer()
        }
  @type link :: %{path: String.t(), target: String.t()}
  @type max_bytes :: pos_integer() | :infinity
  @type t :: %{
          format: pos_integer(),
          created_at: DateTime.t(),
          primary_epoch: pos_integer(),
          engine_version: String.t(),
          home_root: Path.t(),
          host: String.t(),
          files: [entry()],
          links: [link()]
        }
  @type error ::
          {:invalid_manifest, term()}
          | {:unsupported_format, term()}
          | {:unsafe_path, term()}
          | {:unsafe_link, String.t(), term()}
          | {:device_local_entry, String.t()}
          | {:too_many_files, pos_integer(), pos_integer()}
          | {:too_many_bytes, pos_integer(), pos_integer()}

  @doc "The most entries, files and links together, one archive may hold."
  @spec max_files() :: pos_integer()
  def max_files, do: @max_files

  @doc "The most bytes of file content one archive may hold."
  @spec max_total_bytes() :: pos_integer()
  def max_total_bytes, do: @max_total_bytes

  @doc """
  A manifest for `files` and `links`, stamped now with this engine's version.
  `header` names the home's `primary_epoch`, its `home_root` (absolute and
  normalized) and the `host` it was archived on, as the plugin installer names
  a target (`macos-aarch64`).
  """
  @spec new(%{primary_epoch: pos_integer(), home_root: Path.t(), host: String.t()}, [entry()], [
          link()
        ]) :: t()
  def new(%{primary_epoch: epoch, home_root: home_root, host: host}, files, links \\ [])
      when is_integer(epoch) and epoch >= 1 and is_list(files) and is_list(links) do
    unless absolute_root?(home_root) and host?(host),
      do: raise(ArgumentError, "invalid manifest header: #{inspect({home_root, host})}")

    %{
      format: @format,
      created_at: DateTime.truncate(DateTime.utc_now(), :second),
      primary_epoch: epoch,
      engine_version: BuildInfo.product_version(),
      home_root: home_root,
      host: host,
      files: files,
      links: links
    }
  end

  @doc "The manifest as the JSON the archive carries."
  @spec encode(t()) :: binary()
  def encode(%{format: @format, created_at: %DateTime{} = created_at} = manifest) do
    Jason.encode!(%{
      "format" => @format,
      "created_at" => DateTime.to_iso8601(created_at),
      "primary_epoch" => manifest.primary_epoch,
      "engine_version" => manifest.engine_version,
      "home_root" => manifest.home_root,
      "host" => manifest.host,
      "files" => Enum.map(manifest.files, &Map.take(&1, [:path, :bytes, :sha256, :mode])),
      "links" => Enum.map(manifest.links, &Map.take(&1, [:path, :target]))
    })
  end

  @doc """
  Reads the JSON an archive carries, refusing anything but a valid format-1
  manifest. `max_total_bytes` bounds the file content it may list: the
  archive's 1 GiB by default, `:infinity` for a snapshot.
  """
  @spec decode(binary(), max_bytes()) :: {:ok, t()} | {:error, error()}
  def decode(json, max_total_bytes \\ @max_total_bytes)
      when is_binary(json) and
             ((is_integer(max_total_bytes) and max_total_bytes > 0) or
                max_total_bytes == :infinity) do
    with {:ok, map} <- decode_json(json),
         :ok <- supported(Map.get(map, "format")),
         {:ok, header} <- header(map),
         {:ok, raw_files, raw_links} <- lists(map),
         {:ok, files} <- entries(raw_files, max_total_bytes),
         {:ok, links} <- links(raw_links, files) do
      {:ok, Map.merge(header, %{files: files, links: links})}
    end
  end

  @doc """
  Refuses an entry count beyond the bound, or a byte total beyond
  `max_total_bytes` (the archive's 1 GiB by default, `:infinity` for none).
  """
  @spec check_bounds(non_neg_integer(), non_neg_integer(), max_bytes()) ::
          :ok | {:error, {:too_many_files | :too_many_bytes, pos_integer(), pos_integer()}}
  def check_bounds(count, bytes, max_total_bytes \\ @max_total_bytes)
      when is_integer(count) and count >= 0 and is_integer(bytes) and bytes >= 0 do
    cond do
      count > @max_files ->
        {:error, {:too_many_files, count, @max_files}}

      max_total_bytes != :infinity and bytes > max_total_bytes ->
        {:error, {:too_many_bytes, bytes, max_total_bytes}}

      true ->
        :ok
    end
  end

  @doc """
  Whether `path` names a file inside a root and nowhere else: relative, valid
  UTF-8, no NUL, and no empty, `.` or `..` segment.
  """
  @spec safe_path?(term()) :: boolean()
  def safe_path?(path) when is_binary(path) and byte_size(path) in 1..@max_path_bytes do
    String.valid?(path) and not String.contains?(path, <<0>>) and
      path |> String.split("/") |> Enum.all?(&(&1 not in ["", ".", ".."]))
  end

  def safe_path?(_path), do: false

  @doc """
  Whether a link at `path` pointing at `target` stays inside the root: the
  target is relative, any `..` segments lead it and never climb above the
  root from the link's own directory, and every segment after them is a name.
  A `..` after a name could climb out through another link, so it is refused.
  """
  @spec safe_link?(String.t(), term()) :: boolean()
  def safe_link?(path, target) when is_binary(path) and is_binary(target) do
    safe_path?(path) and byte_size(target) in 1..@max_path_bytes and String.valid?(target) and
      not String.contains?(target, <<0>>) and stays_inside?(path, target)
  end

  def safe_link?(_path, _target), do: false

  defp stays_inside?(path, target) do
    depth = length(String.split(path, "/")) - 1
    {ups, names} = target |> String.split("/") |> Enum.split_while(&(&1 == ".."))
    length(ups) <= depth and Enum.all?(names, &(&1 not in ["", ".", ".."]))
  end

  defp decode_json(json) do
    case Jason.decode(json) do
      {:ok, %{} = map} -> {:ok, map}
      {:ok, other} -> {:error, {:invalid_manifest, {:not_an_object, other}}}
      {:error, %Jason.DecodeError{} = error} -> {:error, {:invalid_manifest, error}}
    end
  end

  defp supported(@format), do: :ok
  defp supported(format), do: {:error, {:unsupported_format, format}}

  defp header(
         %{
           "created_at" => created_at,
           "primary_epoch" => epoch,
           "engine_version" => version,
           "home_root" => root,
           "host" => host
         } = map
       )
       when is_binary(created_at) and is_integer(epoch) and epoch >= 1 and is_binary(version) do
    cond do
      epoch > Epoch.max_epoch() -> {:error, {:invalid_manifest, {:primary_epoch, epoch}}}
      not absolute_root?(root) -> {:error, {:invalid_manifest, {:home_root, root}}}
      not host?(host) -> {:error, {:invalid_manifest, {:host, host}}}
      true -> header_at(map, DateTime.from_iso8601(created_at))
    end
  end

  defp header(map),
    do: {:error, {:invalid_manifest, {:header, Map.drop(map, ["files", "links"])}}}

  defp header_at(map, {:ok, at, 0}) do
    {:ok,
     %{
       format: @format,
       created_at: at,
       primary_epoch: map["primary_epoch"],
       engine_version: map["engine_version"],
       home_root: map["home_root"],
       host: map["host"]
     }}
  end

  defp header_at(map, other),
    do: {:error, {:invalid_manifest, {:created_at, map["created_at"], other}}}

  defp host?(host), do: is_binary(host) and String.match?(host, ~r/\A[a-z0-9_]+-[a-z0-9_]+\z/)

  # An absolute, already-normalized path: what `Path.expand/1` leaves as it is.
  defp absolute_root?(root) do
    is_binary(root) and String.valid?(root) and not String.contains?(root, <<0>>) and
      Path.type(root) == :absolute and Path.expand(root) == root
  end

  defp lists(%{"files" => files, "links" => links}) when is_list(files) and is_list(links) do
    case check_bounds(length(files) + length(links), 0) do
      :ok -> {:ok, files, links}
      {:error, _reason} = error -> error
    end
  end

  defp lists(map), do: {:error, {:invalid_manifest, {:lists, Map.take(map, ["files", "links"])}}}

  defp entries(raw_files, max_total_bytes) do
    raw_files
    |> Enum.reduce_while({:ok, [], MapSet.new(), 0}, &add_entry(&1, &2, max_total_bytes))
    |> finish()
  end

  defp add_entry(raw, {:ok, acc, seen, total}, max_total_bytes) do
    with {:ok, entry} <- entry(raw),
         :ok <- unseen(entry.path, seen),
         :ok <- check_bounds(0, total + entry.bytes, max_total_bytes) do
      {:cont, {:ok, [entry | acc], MapSet.put(seen, entry.path), total + entry.bytes}}
    else
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp finish({:ok, acc, _seen, _total}), do: {:ok, Enum.reverse(acc)}
  defp finish({:error, _reason} = error), do: error

  defp entry(%{"path" => path, "bytes" => bytes, "sha256" => sha256, "mode" => mode} = raw)
       when is_integer(bytes) and bytes >= 0 and is_binary(sha256) and is_integer(mode) and
              mode in 0..0o777 do
    cond do
      not sha256?(sha256) -> {:error, {:invalid_manifest, {:entry, raw}}}
      not safe_path?(path) -> {:error, {:unsafe_path, path}}
      DeviceLocal.excluded?(path) -> {:error, {:device_local_entry, path}}
      true -> {:ok, %{path: path, bytes: bytes, sha256: sha256, mode: mode}}
    end
  end

  defp entry(raw), do: {:error, {:invalid_manifest, {:entry, raw}}}

  defp sha256?(value),
    do: byte_size(value) == 64 and String.match?(value, ~r/\A[0-9a-f]+\z/)

  defp links(raw_links, files) do
    seen = MapSet.new(files, & &1.path)

    raw_links
    |> Enum.reduce_while({:ok, [], seen, 0}, &add_link/2)
    |> finish()
    |> no_entry_beneath_a_link(files)
  end

  defp add_link(raw, {:ok, acc, seen, total}) do
    with {:ok, link} <- link(raw),
         :ok <- unseen(link.path, seen) do
      {:cont, {:ok, [link | acc], MapSet.put(seen, link.path), total}}
    else
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp link(%{"path" => path, "target" => target}) do
    cond do
      not safe_path?(path) -> {:error, {:unsafe_path, path}}
      DeviceLocal.excluded?(path) -> {:error, {:device_local_entry, path}}
      not safe_link?(path, target) -> {:error, {:unsafe_link, path, target}}
      true -> {:ok, %{path: path, target: target}}
    end
  end

  defp link(raw), do: {:error, {:invalid_manifest, {:link, raw}}}

  defp no_entry_beneath_a_link({:ok, links} = ok, files) do
    by_path = Map.new(links, &{&1.path, &1})

    case Enum.find(Enum.map(files, & &1.path) ++ Map.keys(by_path), &beneath_link(&1, by_path)) do
      nil -> ok
      path -> link_error(beneath_link(path, by_path))
    end
  end

  defp no_entry_beneath_a_link({:error, _reason} = error, _files), do: error

  defp beneath_link(path, by_path) do
    path
    |> String.split("/")
    |> Enum.drop(-1)
    |> Enum.scan(&(&2 <> "/" <> &1))
    |> Enum.find_value(&Map.get(by_path, &1))
  end

  defp link_error(link), do: {:error, {:unsafe_link, link.path, link.target}}

  defp unseen(path, seen) do
    if MapSet.member?(seen, path),
      do: {:error, {:invalid_manifest, {:duplicate_path, path}}},
      else: :ok
  end
end
