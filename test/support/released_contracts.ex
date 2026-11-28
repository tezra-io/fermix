defmodule FermixTestSupport.ReleasedContracts do
  @moduledoc """
  The wire contracts each supported release's apps were built against, and the
  comparison that holds this engine to them, so an app that has not updated
  keeps working: the management protocol's *Rollout / rollback order* and the
  mobile protocol's *Where it stands*, executed.

  `test/released_contracts/<tag>/` is a byte copy, written once by
  `scripts/release/snapshot_released_contracts.py` from the tag itself, of
  each protocol's schema and golden fixtures as that release published them
  under `priv/`, which is the layout it keeps; its `SOURCE.json` records the
  tag, the commit and each file's SHA-256. One directory stands for each
  release whose apps this engine still serves in full. A release that leaves
  that window has its directory deleted in the change that stops serving it,
  the one way a break of a released app ships.

  The tests hold two directions. What a released app sends, this engine must
  take: its golden frames go through the live decoders. What this engine
  sends, a released app must still read: `shape_breaks/2` finds every field a
  release's goldens showed for a kind of message (a method's result, an event
  type) that this engine's goldens no longer carry, and every type there the
  release never showed, null included. This engine's goldens are held to what
  it sends by each protocol's own contract test, so the comparison reaches the
  engine through them.

  Not compared, by design: values, and so enum members; a field a release only
  ever showed as null, which says nothing about the type its app reads; the
  elements of a list it only showed empty. A new field, a new kind and an
  integer where a number was are not breaks: a released app ignores what it
  does not know, and reads an integer as a number.
  """

  @root Path.expand("../released_contracts", __DIR__)
  @null_only MapSet.new(["null"])

  @typedoc "A message kind (a method, an event type) and one golden body of it."
  @type sample :: {String.t(), term()}

  @doc "Every release with a snapshot, oldest first."
  @spec releases() :: [String.t()]
  def releases do
    @root
    |> Path.join("v*")
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
    |> Enum.map(&Path.basename/1)
    |> Enum.sort_by(&Version.parse!(String.trim_leading(&1, "v")), Version)
  end

  @doc "A release's snapshot, laid out as the release's `priv/` was."
  @spec dir(String.t()) :: String.t()
  def dir(release) when is_binary(release), do: Path.join(@root, release)

  @doc "One JSON file under `root` (a snapshot, or this engine's `priv/`)."
  @spec json(String.t(), String.t()) :: term()
  def json(root, file) when is_binary(root) and is_binary(file),
    do: root |> Path.join(file) |> File.read!() |> Jason.decode!()

  @doc "The lines of one JSONL file under `root`, undecoded."
  @spec lines(String.t(), String.t()) :: [String.t()]
  def lines(root, file) when is_binary(root) and is_binary(file),
    do: root |> Path.join(file) |> File.read!() |> String.split("\n", trim: true)

  @doc "The records of one JSONL file under `root`."
  @spec jsonl(String.t(), String.t()) :: [term()]
  def jsonl(root, file), do: root |> lines(file) |> Enum.map(&Jason.decode!/1)

  @doc """
  Where a release's snapshot is not the release's own bytes: a file whose
  digest is not the one `SOURCE.json` records, a file it does not list, and
  one it lists that is missing. Empty when the snapshot is intact.
  """
  @spec provenance_errors(String.t()) :: [String.t()]
  def provenance_errors(release) when is_binary(release) do
    root = dir(release)
    recorded = Map.new(json(root, "SOURCE.json")["files"], &{&1["path"], &1["sha256"]})

    present =
      root
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.reject(&File.dir?/1)
      |> MapSet.new(&Path.relative_to(&1, root))
      |> MapSet.delete("SOURCE.json")

    unlisted =
      for path <- Enum.sort(present),
          not Map.has_key?(recorded, path),
          do: "#{path} is not in SOURCE.json"

    damaged =
      recorded
      |> Enum.sort()
      |> Enum.map(fn {path, sha256} -> digest_error(root, path, sha256, present) end)
      |> Enum.reject(&is_nil/1)

    unlisted ++ damaged
  end

  defp digest_error(root, path, sha256, present) do
    cond do
      not MapSet.member?(present, path) -> "#{path} is missing"
      digest(Path.join(root, path)) != sha256 -> "#{path} is not the release's bytes"
      true -> nil
    end
  end

  defp digest(path), do: :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)

  @doc """
  Every way this engine's goldens (`current`) no longer read as a release's
  (`released`) did, one sentence each, sorted; empty when a released app reads
  everything this engine sends. See the moduledoc for what is compared.
  """
  @spec shape_breaks([sample()], [sample()]) :: [String.t()]
  def shape_breaks(released, current) when is_list(released) and is_list(current) do
    current = shapes(current)

    released
    |> shapes()
    |> Enum.sort()
    |> Enum.flat_map(fn {kind, paths} -> kind_breaks(kind, paths, Map.get(current, kind)) end)
  end

  defp kind_breaks(kind, _paths, nil), do: ["#{kind}: no longer sent"]

  defp kind_breaks(kind, paths, current) do
    paths
    |> Enum.sort()
    |> Enum.reject(fn {_path, types} -> types == @null_only end)
    |> Enum.flat_map(fn {path, types} ->
      case path_break(Map.get(current, path), types) do
        nil -> []
        reason -> ["#{kind} #{path}: #{reason}"]
      end
    end)
  end

  defp path_break(nil, _types), do: "gone"

  defp path_break(current, types) do
    readable = if "number" in types, do: MapSet.put(types, "integer"), else: types

    case current |> MapSet.difference(readable) |> Enum.sort() do
      [] ->
        nil

      new ->
        "now #{Enum.join(new, ", ")}, where the release showed #{Enum.join(Enum.sort(types), ", ")}"
    end
  end

  # Each kind's every path (`$` for the body, `.key` into an object, `[]` into
  # a list's elements), with the set of JSON types its samples showed there.
  defp shapes(samples) do
    Enum.reduce(samples, %{}, fn {kind, body}, acc ->
      Map.put(acc, kind, flatten(body, "$", Map.get(acc, kind, %{})))
    end)
  end

  defp flatten(value, path, acc) do
    acc = Map.update(acc, path, MapSet.new([type(value)]), &MapSet.put(&1, type(value)))
    children(value, path, acc)
  end

  defp children(map, path, acc) when is_map(map),
    do: Enum.reduce(map, acc, fn {key, value}, acc -> flatten(value, "#{path}.#{key}", acc) end)

  defp children(list, path, acc) when is_list(list),
    do: Enum.reduce(list, acc, &flatten(&1, path <> "[]", &2))

  defp children(_scalar, _path, acc), do: acc

  defp type(nil), do: "null"
  defp type(value) when is_boolean(value), do: "boolean"
  defp type(value) when is_integer(value), do: "integer"
  defp type(value) when is_float(value), do: "number"
  defp type(value) when is_binary(value), do: "string"
  defp type(value) when is_list(value), do: "list"
  defp type(value) when is_map(value), do: "object"
end
