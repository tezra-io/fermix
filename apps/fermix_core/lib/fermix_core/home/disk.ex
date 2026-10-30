defmodule FermixCore.Home.Disk do
  @moduledoc """
  Free space on the disk that holds a home (M75), for the checks that refuse
  by number before a capture or a move fills it: a snapshot capture
  (`Snapshot.write/4`), the move's readiness report
  (`FermixCore.Home.MoveReadiness`) and a candidate taking a move's offer.

  A capture holds one copy of the home in its staging directory and the
  encrypted snapshot beside it, so it needs about twice the home's bytes, plus
  a floor of #{div(536_870_912, 1_048_576)} MiB so the disk is not left full for
  the engine's own writes (`capture_need/1`). A candidate holds the arriving
  stream and the restored home: twice the stream's bytes plus the same floor.

  The space is read with POSIX `df -Pk` through `FermixCore.CommandRunner`,
  on the nearest directory that exists. `opts[:supervised]` is the caller's
  world, as every `CommandRunner` caller passes it: a tree-less CLI verb passes
  `false`.
  """

  alias FermixCore.CommandRunner

  @df_timeout_ms 5_000
  @floor_bytes 536_870_912
  # A `df -P` line: the filesystem (whose name may hold spaces, as an SMB
  # share's does), the size, used and available 1024-byte blocks, the capacity
  # (`-` where the filesystem has no size), and the mount point, which starts
  # with `/` and may hold spaces too. The filesystem is matched as short as it
  # can be, so the first run of three numbers and a capacity names the columns.
  @df_line ~r/^.+?\s+\d+\s+\d+\s+(\d+)\s+(?:\d+%|-)\s+\/.*$/

  @type free_bytes :: (Path.t() -> {:ok, non_neg_integer()} | {:error, term()})

  @doc "The bytes a capture of a home of `home_bytes` needs free: twice it, plus the floor."
  @spec capture_need(non_neg_integer()) :: pos_integer()
  def capture_need(home_bytes) when is_integer(home_bytes) and home_bytes >= 0,
    do: 2 * home_bytes + @floor_bytes

  @doc "The space left on the filesystem that holds `dir`, in bytes."
  @spec free_bytes(Path.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def free_bytes(dir, opts \\ []) when is_binary(dir) and is_list(opts) do
    case System.find_executable("df") do
      nil -> {:error, :df_unavailable}
      df -> run_df(df, existing_ancestor(Path.expand(dir)), opts)
    end
  end

  @doc """
  A size as a sentence names it, in whole units: GiB from one GiB up, MiB
  below, rounded up.
  """
  @spec gib(non_neg_integer()) :: String.t()
  def gib(bytes) when is_integer(bytes) and bytes >= 1_073_741_824,
    do: "#{div(bytes + 1_073_741_823, 1_073_741_824)} GiB"

  def gib(bytes) when is_integer(bytes) and bytes >= 0,
    do: "#{div(bytes + 1_048_575, 1_048_576)} MiB"

  defp run_df(df, dir, opts) do
    run_opts =
      opts
      |> Keyword.take([:supervised])
      |> Keyword.put(:timeout_ms, @df_timeout_ms)

    case CommandRunner.run(df, ["-Pk", dir], run_opts) do
      {:ok, %{exit: 0, stdout: out}} -> parse(out)
      {:ok, %{exit: code}} -> {:error, {:df_failed, code}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The space left, in bytes, from `df -Pk` output: the available column of the
  line after the header, read so that a space in the filesystem's name or in
  its mount point moves no column.
  """
  @spec parse(String.t()) :: {:ok, non_neg_integer()} | {:error, :df_unparseable}
  def parse(out) when is_binary(out) do
    with [_header, line | _rest] <- String.split(out, "\n", trim: true),
         [_line, available] <- Regex.run(@df_line, String.trim(line)) do
      {:ok, String.to_integer(available) * 1_024}
    else
      _other -> {:error, :df_unparseable}
    end
  end

  # `df` needs a path that exists; free space belongs to the filesystem, so
  # the nearest existing ancestor answers for a directory not made yet.
  defp existing_ancestor(path) do
    parent = Path.dirname(path)

    cond do
      File.exists?(path) -> path
      parent == path -> path
      true -> existing_ancestor(parent)
    end
  end
end
