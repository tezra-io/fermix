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

  How full the disk is (`usage/2`) is the reading for the disk warning of
  `home.status.summary` (M75 L14, "Your server's disk is 90% full."): the
  fraction in use, and whether it reached 85% (`nearly_full_at/0`), read with
  the home's directory on every machine.

  The space is read with POSIX `df -Pk` through `FermixCore.CommandRunner`,
  on the nearest directory that exists. `opts[:supervised]` is the caller's
  world, as every `CommandRunner` caller passes it: a tree-less CLI verb passes
  `false`.
  """

  alias FermixCore.CommandRunner

  @df_timeout_ms 5_000
  @floor_bytes 536_870_912
  @nearly_full_at 0.85
  # A `df -P` line: the filesystem (whose name may hold spaces, as an SMB
  # share's does), the size, used and available 1024-byte blocks, the capacity
  # (`-` where the filesystem has no size), and the mount point, which starts
  # with `/` and may hold spaces too. The filesystem is matched as short as it
  # can be, so the first run of three numbers and a capacity names the columns.
  @df_line ~r/^.+?\s+\d+\s+(\d+)\s+(\d+)\s+(?:\d+%|-)\s+\/.*$/

  @type free_bytes :: (Path.t() -> {:ok, non_neg_integer()} | {:error, term()})
  @type usage :: %{used: float(), nearly_full: boolean()}

  @doc "The bytes a capture of a home of `home_bytes` needs free: twice it, plus the floor."
  @spec capture_need(non_neg_integer()) :: pos_integer()
  def capture_need(home_bytes) when is_integer(home_bytes) and home_bytes >= 0,
    do: 2 * home_bytes + @floor_bytes

  @doc "The space left on the filesystem that holds `dir`, in bytes."
  @spec free_bytes(Path.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def free_bytes(dir, opts \\ []) when is_binary(dir) and is_list(opts) do
    with {:ok, out} <- df(dir, opts), do: parse(out)
  end

  @doc """
  How full the filesystem that holds `dir` is: `used`, the fraction of its
  space in use as `df` counts it (used over used plus available, so space kept
  back for root counts as used: the engine cannot write there), and
  `nearly_full`, whether that reached `nearly_full_at/0`, where the disk
  warning of `home.status.summary` starts. `opts` as `free_bytes/2`.
  """
  @spec usage(Path.t(), keyword()) :: {:ok, usage()} | {:error, term()}
  def usage(dir, opts \\ []) when is_binary(dir) and is_list(opts) do
    with {:ok, out} <- df(dir, opts), do: parse_usage(out)
  end

  @doc "The fraction in use at which a disk counts as nearly full (#{round(@nearly_full_at * 100)}%)."
  @spec nearly_full_at() :: float()
  def nearly_full_at, do: @nearly_full_at

  @doc """
  A size as a sentence names it, in whole units: GiB from one GiB up, MiB
  below, rounded up.
  """
  @spec gib(non_neg_integer()) :: String.t()
  def gib(bytes) when is_integer(bytes) and bytes >= 1_073_741_824,
    do: "#{div(bytes + 1_073_741_823, 1_073_741_824)} GiB"

  def gib(bytes) when is_integer(bytes) and bytes >= 0,
    do: "#{div(bytes + 1_048_575, 1_048_576)} MiB"

  defp df(dir, opts) do
    case System.find_executable("df") do
      nil -> {:error, :df_unavailable}
      df -> run_df(df, existing_ancestor(Path.expand(dir)), opts)
    end
  end

  defp run_df(df, dir, opts) do
    run_opts =
      opts
      |> Keyword.take([:supervised])
      |> Keyword.put(:timeout_ms, @df_timeout_ms)

    case CommandRunner.run(df, ["-Pk", dir], run_opts) do
      {:ok, %{exit: 0, stdout: out}} -> {:ok, out}
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
    with {:ok, _used, available} <- columns(out), do: {:ok, available * 1_024}
  end

  @doc """
  How full the filesystem is, from `df -Pk` output (`usage/2`): `{:error,
  :df_no_size}` for a filesystem with neither used nor available blocks.
  """
  @spec parse_usage(String.t()) :: {:ok, usage()} | {:error, :df_unparseable | :df_no_size}
  def parse_usage(out) when is_binary(out) do
    case columns(out) do
      {:ok, 0, 0} -> {:error, :df_no_size}
      {:ok, used, available} -> {:ok, usage_of(used / (used + available))}
      {:error, reason} -> {:error, reason}
    end
  end

  defp usage_of(used), do: %{used: used, nearly_full: used >= @nearly_full_at}

  # The used and available columns of the line after the header, in blocks.
  defp columns(out) do
    with [_header, line | _rest] <- String.split(out, "\n", trim: true),
         [_line, used, available] <- Regex.run(@df_line, String.trim(line)) do
      {:ok, String.to_integer(used), String.to_integer(available)}
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
