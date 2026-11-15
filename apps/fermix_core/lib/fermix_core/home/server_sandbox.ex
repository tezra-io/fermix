defmodule FermixCore.Home.ServerSandbox do
  @moduledoc """
  That an Always On server left out the machine settings it inherited from
  the computer its home came from, and took its own sandbox setting, open
  (M97 §4, `Setup.MachineFile.migration/3`): recorded once, when the boot's
  migration did it (`Setup.ConfigStore.migrate_machine_file/2`), so the
  server's summary tells it once, as a notice
  (`Management.HomeSummary`, `server_sandbox:<at>`), for a week after.

  `<home>/device/server_sandbox.json`, `0600` under a `0700` directory:
  `{"v": 1, "at": "2031-06-01T09:00:00Z"}`. `device/` stays on this machine
  (`Home.DeviceLocal`). A record that exists is kept as it is: the event
  happened once.
  """

  @file_name "server_sandbox.json"
  @version 1

  @doc "Where the record lives under `home`."
  @spec path(Path.t()) :: Path.t()
  def path(home) when is_binary(home) and home != "", do: Path.join([home, "device", @file_name])

  @doc "Records that the migration left the inherited settings out at `at`, once."
  @spec record(Path.t(), DateTime.t()) :: :ok | {:error, term()}
  def record(home, %DateTime{} = at) when is_binary(home) and home != "" do
    file = path(home)

    if File.exists?(file) do
      :ok
    else
      contents =
        Jason.encode!(%{
          "v" => @version,
          "at" => at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        })

      write(file, contents)
    end
  end

  @doc "When it was recorded, `:absent` when it never was, or why it cannot be read."
  @spec read(Path.t()) :: {:ok, DateTime.t()} | :absent | {:error, term()}
  def read(home) when is_binary(home) and home != "" do
    file = path(home)

    with {:ok, contents} <- File.read(file),
         {:ok, %{"v" => @version, "at" => text}} <- Jason.decode(contents),
         {:ok, at, _offset} <- DateTime.from_iso8601(text) do
      {:ok, at}
    else
      {:error, :enoent} -> :absent
      {:error, reason} when is_atom(reason) -> {:error, {:file, file, reason}}
      _not_ours -> {:error, {:invalid_record, file}}
    end
  end

  defp write(file, contents) do
    dir = Path.dirname(file)
    tmp = file <> ".tmp"

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700),
         :ok <- File.write(tmp, contents),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, file) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, {:file, file, reason}}
    end
  end
end
