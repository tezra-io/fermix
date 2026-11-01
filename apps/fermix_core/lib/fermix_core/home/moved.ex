defmodule FermixCore.Home.Moved do
  @moduledoc """
  The marker that retires a home as the primary: `<home>/moved.json`.

  It is written once, after the home's archive has left for another host, and
  records the epoch this copy was at, when it moved and where to. A home that
  carries it refuses to boot as the primary engine by name (`FermixCore.Home.Role`,
  M75 step 1) and may only run in the device role. One step removes it
  (`remove/1`): a return (Always On's move back to this computer), once the
  server it moved to carries its own marker and only just before this home's
  settings make it the primary again (`FermixCore.Home.Candidate.Activation`).
  Otherwise a home that should be primary again is restored from a snapshot
  into an empty root, which has no marker. Writing over an existing marker is
  refused, since the first move is the one that counts.
  """

  @filename "moved.json"
  @max_to_bytes 128

  @type marker :: %{epoch: pos_integer(), moved_at: DateTime.t(), to: String.t()}
  @type error ::
          {:invalid_marker, Path.t(), term()}
          | {:already_moved, marker()}
          | {:file, Path.t(), File.posix()}

  @doc "Where the marker lives under `root`."
  @spec path(Path.t()) :: Path.t()
  def path(root) when is_binary(root) and root != "", do: Path.join(root, @filename)

  @doc "The marker under `root`: `:absent` when the home never moved."
  @spec read(Path.t()) :: {:ok, marker()} | :absent | {:error, error()}
  def read(root) when is_binary(root) and root != "" do
    file = path(root)

    case File.read(file) do
      {:ok, contents} -> decode(contents, file)
      {:error, :enoent} -> :absent
      {:error, reason} -> {:error, {:file, file, reason}}
    end
  end

  @doc """
  Writes the marker under `root`, refusing when one already exists. `to` names
  the new primary for a person reading the refusal: 1 to #{@max_to_bytes}
  bytes of printable text with no control characters.
  """
  @spec write(Path.t(), marker()) :: :ok | {:error, error()}
  def write(root, %{epoch: epoch, moved_at: %DateTime{} = moved_at, to: to} = marker)
      when is_binary(root) and root != "" and is_integer(epoch) and epoch >= 1 and
             is_binary(to) do
    file = path(root)

    with :ok <- valid_to(to, file),
         :ok <- not_moved(read(root)),
         :ok <- exclusive_write(file, encode(epoch, moved_at, to)) do
      :ok
    else
      {:error, _reason} = error -> error
      {:already, existing} -> {:error, {:already_moved, existing}}
      _other -> {:error, {:invalid_marker, file, marker}}
    end
  end

  @doc """
  Removes the marker under `root`; an absent one is already removed. Only a
  return's activation calls it (see the moduledoc).
  """
  @spec remove(Path.t()) :: :ok | {:error, error()}
  def remove(root) when is_binary(root) and root != "" do
    file = path(root)

    case File.rm(file) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:file, file, reason}}
    end
  end

  defp valid_to(to, file) do
    printable? = String.valid?(to) and not Regex.match?(~r/[\p{Cc}]/u, to)

    if printable? and byte_size(to) in 1..@max_to_bytes,
      do: :ok,
      else: {:error, {:invalid_marker, file, {:to, to}}}
  end

  defp not_moved(:absent), do: :ok
  defp not_moved({:ok, existing}), do: {:already, existing}
  defp not_moved({:error, _reason} = error), do: error

  defp exclusive_write(file, contents) do
    case File.open(file, [:write, :exclusive, :binary]) do
      {:ok, io} -> write_and_close(io, file, contents)
      {:error, reason} -> {:error, {:file, file, reason}}
    end
  end

  defp write_and_close(io, file, contents) do
    written = IO.binwrite(io, contents)
    closed = File.close(io)

    case {written, closed} do
      {:ok, :ok} -> :ok
      {{:error, reason}, _closed} -> {:error, {:file, file, reason}}
      {:ok, {:error, reason}} -> {:error, {:file, file, reason}}
    end
  end

  defp encode(epoch, moved_at, to) do
    Jason.encode!(%{
      "epoch" => epoch,
      "moved_at" => DateTime.to_iso8601(moved_at),
      "to" => to
    }) <> "\n"
  end

  defp decode(contents, file) do
    with {:ok, %{"epoch" => epoch, "moved_at" => moved_at, "to" => to}}
         when is_integer(epoch) and epoch >= 1 and is_binary(moved_at) and is_binary(to) <-
           Jason.decode(contents),
         {:ok, at, _offset} <- DateTime.from_iso8601(moved_at),
         :ok <- valid_to(to, file) do
      {:ok, %{epoch: epoch, moved_at: at, to: to}}
    else
      {:error, {:invalid_marker, _file, _detail}} = error -> error
      other -> {:error, {:invalid_marker, file, other}}
    end
  end
end
