defmodule FermixCore.Home.ReadGrants do
  @moduledoc """
  The folders a desktop lets its primary read beyond its sandbox's own read
  scope (M75 §11), each one the owner approved on a `device` card
  (`device_action` `grant_read`), and each one the owner can see and remove
  on the desktop (`device.grants.list`, `device.grants.remove`,
  `FermixCore.Management.DeviceGrants`).

  They live in `<home>/device/read_grants.json` on the desktop, device-local
  (a move never carries them) and private: the folder `0700`, the file `0600`,
  written whole through a temporary file and a rename. Only the desktop
  executor's `read_file` and `list_directory` read them, anew for every
  request, so a grant removed holds for the next one; they widen nothing else
  (no command, no tool of this engine), and the sandbox's protected paths stay
  closed inside them. At most 64 folders; a folder already held is not added
  twice.
  """

  @version 1
  @max_grants 64
  @dir_mode 0o700
  @file_mode 0o600

  @typedoc "One granted folder: its canonical path and when the owner granted it."
  @type grant :: %{path: String.t(), granted_at: String.t()}

  @doc "Where the grants of the home at `home` live."
  @spec path(Path.t()) :: Path.t()
  def path(home) when is_binary(home) and home != "",
    do: Path.join([home, "device", "read_grants.json"])

  @doc "The most folders one desktop holds."
  @spec max_grants() :: pos_integer()
  def max_grants, do: @max_grants

  @doc "The granted folders' paths, oldest first; none when the file does not exist."
  @spec folders(Path.t()) :: {:ok, [String.t()]} | {:error, term()}
  def folders(home) do
    with {:ok, grants} <- list(home), do: {:ok, Enum.map(grants, & &1.path)}
  end

  @doc "The grants, oldest first; none when the file does not exist."
  @spec list(Path.t()) :: {:ok, [grant()]} | {:error, term()}
  def list(home) do
    file = path(home)

    case File.read(file) do
      {:ok, contents} -> decode(contents, file)
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, {:file, file, reason}}
    end
  end

  @doc """
  Records `folder` (an absolute, canonical path) as granted at `now`. A folder
  already held is left as it is; a 65th is refused (`:too_many_grants`).
  """
  @spec add(Path.t(), String.t(), DateTime.t()) ::
          :ok | {:error, :too_many_grants | term()}
  def add(home, folder, %DateTime{} = now) when is_binary(folder) do
    "/" <> _rest = folder

    with {:ok, grants} <- list(home) do
      cond do
        Enum.any?(grants, &(&1.path == folder)) -> :ok
        length(grants) >= @max_grants -> {:error, :too_many_grants}
        true -> write(home, grants ++ [%{path: folder, granted_at: iso(now)}])
      end
    end
  end

  @doc """
  Removes the grant held under any of `names` (one folder, as it was listed or
  by another name for it), and answers the grants left; `:not_granted` when no
  grant is held under any of them.
  """
  @spec remove(Path.t(), [String.t(), ...]) :: {:ok, [grant()]} | {:error, :not_granted | term()}
  def remove(home, [_ | _] = names) do
    true = Enum.all?(names, &is_binary/1)

    with {:ok, grants} <- list(home),
         {[_ | _], kept} <- Enum.split_with(grants, &(&1.path in names)),
         :ok <- write(home, kept) do
      {:ok, kept}
    else
      {[], _kept} -> {:error, :not_granted}
      {:error, _reason} = error -> error
    end
  end

  defp decode(contents, file) do
    case Jason.decode(contents) do
      {:ok, %{"v" => @version, "grants" => grants}} when is_list(grants) ->
        grants(grants, file)

      _invalid ->
        {:error, {:invalid_read_grants, file}}
    end
  end

  defp grants(entries, file) do
    if Enum.all?(entries, &valid_entry?/1),
      do: {:ok, Enum.map(entries, &%{path: &1["path"], granted_at: &1["granted_at"]})},
      else: {:error, {:invalid_read_grants, file}}
  end

  defp valid_entry?(%{"path" => "/" <> _rest = path, "granted_at" => at})
       when is_binary(path) and is_binary(at),
       do: true

  defp valid_entry?(_entry), do: false

  defp write(home, grants) do
    file = path(home)
    dir = Path.dirname(file)
    tmp = file <> ".tmp"

    body =
      Jason.encode!(%{
        "v" => @version,
        "grants" => Enum.map(grants, &%{"path" => &1.path, "granted_at" => &1.granted_at})
      })

    with :ok <- file_op(File.mkdir_p(dir), dir),
         :ok <- file_op(File.chmod(dir, @dir_mode), dir),
         :ok <- file_op(File.write(tmp, body), tmp),
         :ok <- file_op(File.chmod(tmp, @file_mode), tmp),
         :ok <- file_op(File.rename(tmp, file), file) do
      :ok
    else
      {:error, _reason} = error ->
        _ = File.rm(tmp)
        error
    end
  end

  defp file_op(:ok, _path), do: :ok
  defp file_op({:error, reason}, path), do: {:error, {:file, path, reason}}

  defp iso(now), do: now |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
