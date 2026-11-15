defmodule FermixTestSupport.CraftedSnapshot do
  @moduledoc """
  A snapshot stream (`FermixCore.Home.Snapshot.Format`) of the home at a root
  whose manifest says what a test states, not what this engine writes:
  another home format, none at all (an engine before home formats), another
  engine version (M97 D16). `Snapshot.write/4` never writes one, so a move's,
  a move back's and Restore here's staging are tested against this. Each
  file is copied as it is (no `VACUUM INTO`), so a test home's database must
  be closed.
  """

  alias FermixCore.Home.Archive
  alias FermixCore.Home.Archive.Manifest
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Snapshot.Format

  @created_at ~U[2031-06-01 08:00:00Z]

  @doc """
  Writes the home at `root`, encrypted to `recipient` (a public half), to the
  new file `path`, and answers `path`. `opts`: `:home_format` (a number, or
  `:absent`; required), `:engine_version` (this engine's when absent) and
  `:host` (`linux-x86_64` when absent).
  """
  @spec write!(Path.t(), map(), Path.t(), keyword()) :: Path.t()
  def write!(path, recipient, root, opts) do
    {:ok, found, links} = Archive.collect(root, :infinity)
    {:ok, epoch} = Epoch.read(root)
    contents = Map.new(found, fn {rel, _stat} -> {rel, File.read!(Path.join(root, rel))} end)
    entries = for {rel, _stat} <- found, do: entry(rel, Map.fetch!(contents, rel))
    host = Keyword.get(opts, :host, "linux-x86_64")

    json =
      %{primary_epoch: epoch, home_root: root, host: host}
      |> Manifest.new(entries, links)
      |> stated(opts)

    {:ok, io} = File.open(path, [:write, :exclusive, :binary])

    try do
      stream!(io, recipient, epoch, [json | Enum.map(entries, &Map.fetch!(contents, &1.path))])
    after
      :ok = File.close(io)
    end

    path
  end

  defp entry(rel, bytes) do
    sha256 = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    %{path: rel, bytes: byte_size(bytes), sha256: sha256, mode: 0o600}
  end

  defp stated(manifest, opts) do
    map =
      manifest
      |> Manifest.encode()
      |> Jason.decode!()
      |> Map.put("engine_version", Keyword.get(opts, :engine_version, manifest.engine_version))

    case Keyword.fetch!(opts, :home_format) do
      :absent -> map |> Map.delete("home_format") |> Jason.encode!()
      format -> map |> Map.put("home_format", format) |> Jason.encode!()
    end
  end

  # The manifest, length first, then each file's bytes in the manifest's order.
  defp stream!(io, recipient, epoch, [json | files]) do
    emit = &IO.binwrite(io, &1)
    {:ok, writer} = Format.open_writer(recipient, %{created_at: @created_at, epoch: epoch}, emit)
    {:ok, writer} = Format.write(writer, [<<byte_size(json)::32>>, json])

    writer =
      Enum.reduce(files, writer, fn bytes, writer ->
        {:ok, writer} = Format.write(writer, bytes)
        writer
      end)

    {:ok, _written} = Format.finish(writer)
  end
end
