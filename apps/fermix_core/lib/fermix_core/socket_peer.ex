defmodule FermixCore.SocketPeer do
  @moduledoc """
  Which process is on the other end of a local (Unix-domain) socket, and whether
  the daemon itself started it.

  The daemon's local sockets have no per-request auth: their trust boundary is
  the 0600 socket file, so every process running as the owner can connect. That
  is right for a person at a terminal. A process the daemon started — a shell
  tool's command, a coding harness, a plugin runtime — runs on the agent's
  behalf, so a prompt it sends is not an attended one (SIDE-V1).

  The answer comes from the kernel (the socket's peer pid) and the process table,
  never from anything the peer says about itself. The peer is placed from two
  starting points over one table: its own parent chain, and its process group's
  leader. Every command the daemon runs leads its own process group
  (`FermixCore.CommandHost`), and a job the command backgrounds keeps that group
  after the job's parent exits and it is reparented to init, so `(fermix ask … &)`
  is still placed beneath the daemon.

  A group member whose leader has also exited is placed by its controlling
  terminal, which it loses when its session's leader exits. With one, it is the
  last command of a person's terminal pipeline. Without one it is `:detached`:
  nobody is watching it, whoever started it. That covers a job a coding harness's
  command left behind. Claude Code runs every command in a session of its own and
  does not reap what it backgrounds, so the job also outlives CommandHost's sweep,
  which reaches only the harness's own group.

  It raises the bar rather than authenticating anyone. A process that makes
  itself the leader of a new process group or session (`set -m`, `setsid`,
  `setpgrp`) is placed by its own parent chain alone, and once that parent exits
  it reads as independent, like any launchd or systemd job. So does a process
  started through launchd, systemd, `open`, or a terminal app driven by
  `osascript`. CommandHost's end-of-command group sweep does not help there: it
  kills a process, not a prompt the daemon has already accepted.
  """

  alias FermixCore.CommandRunner

  @typedoc """
  Whether the peer runs beneath the daemon's own OS process, is detached (no
  group leader and no terminal left to place it by), or neither.
  """
  @type caller :: :daemon_descendant | :detached | :independent

  @typedoc """
  Each process's parent pid, process-group id and whether it has a controlling
  terminal, keyed by pid.
  """
  @type process_table :: %{integer() => {integer(), integer(), boolean()}}

  # macOS ships ps at this system path; a PATH lookup could resolve a
  # user-writable directory first and let a same-user process answer.
  @ps "/bin/ps"
  @ps_timeout_ms 5_000
  @proc "/proc"
  # A real process tree is a few dozen levels deep at most; a longer chain is a
  # corrupt table, and the walk refuses rather than guessing.
  @max_depth 64

  @doc """
  Classify the peer of an accepted local `socket` against the daemon's own OS
  process, `daemon_os_pid`. `os` is the platform-injection seam.
  """
  @spec classify(:inet.socket(), pos_integer(), {atom(), atom()}) ::
          {:ok, caller()} | {:error, term()}
  def classify(socket, daemon_os_pid, os \\ :os.type())
      when is_integer(daemon_os_pid) and daemon_os_pid > 0 and is_tuple(os) do
    with {:ok, peer} <- peer_os_pid(socket, os),
         {:ok, table} <- process_table(os) do
      classify_pid(peer, daemon_os_pid, table)
    end
  end

  @doc """
  The OS pid of the process on the other end of a connected local `socket`, as the
  kernel recorded it. `os` is the platform-injection seam.
  """
  @spec peer_os_pid(:inet.socket(), {atom(), atom()}) :: {:ok, pos_integer()} | {:error, term()}
  def peer_os_pid(socket, os \\ :os.type()) when is_tuple(os) do
    with {:ok, {level, name, size}} <- peer_pid_option(os),
         {:ok, [{:raw, ^level, ^name, value}]} <-
           :inet.getopts(socket, [{:raw, level, name, size}]) do
      decode_pid(value)
    else
      # No value at all: the kernel keeps no peer for a socket whose client has
      # already hung up (macOS), and inet drops the failed option from the reply.
      {:ok, []} -> {:error, :peer_closed}
      {:ok, other} -> {:error, {:unexpected_peer_option, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Classify `pid` against `daemon_os_pid` over a process `table`.

  The peer's own parent chain is walked first. A peer that does not lead its
  process group is then placed by that group's leader, the leader itself
  included; never by another member of the group, which could be the daemon's
  own helper when one runner starts both the daemon and the client.

  Strict: the daemon's own process is not its own descendant. A pid missing from
  the table is an error, never a verdict, because a process that is gone cannot
  be placed. A leader missing from the table (it exited, as the first command of
  a terminal pipeline does) places nothing, and the member is then placed by its
  controlling terminal: independent with one, `:detached` without.
  """
  @spec classify_pid(integer(), pos_integer(), process_table()) ::
          {:ok, caller()} | {:error, term()}
  def classify_pid(pid, daemon_os_pid, table)
      when is_integer(pid) and is_integer(daemon_os_pid) and is_map(table) do
    case Map.fetch(table, pid) do
      {:ok, entry} -> place(pid, entry, daemon_os_pid, table)
      :error -> {:error, {:peer_not_running, pid}}
    end
  end

  defp place(pid, {parent, group, terminal?}, daemon_os_pid, table) do
    case walk(parent, daemon_os_pid, table, @max_depth) do
      {:ok, :independent} when group != pid ->
        place_by_group(group, terminal?, daemon_os_pid, table)

      verdict ->
        verdict
    end
  end

  defp place_by_group(group, terminal?, daemon_os_pid, table) do
    case {Map.has_key?(table, group), terminal?} do
      {true, _terminal?} -> walk(group, daemon_os_pid, table, @max_depth)
      {false, true} -> {:ok, :independent}
      {false, false} -> {:ok, :detached}
    end
  end

  defp walk(daemon_os_pid, daemon_os_pid, _table, _left), do: {:ok, :daemon_descendant}
  defp walk(_pid, _daemon_os_pid, _table, 0), do: {:error, :process_tree_too_deep}

  defp walk(pid, daemon_os_pid, table, left) do
    case Map.fetch(table, pid) do
      {:ok, {parent, _group, _terminal?}} -> walk(parent, daemon_os_pid, table, left - 1)
      :error -> {:ok, :independent}
    end
  end

  # macOS: SOL_LOCAL (0), LOCAL_PEERPID (2), a pid_t.
  defp peer_pid_option({:unix, :darwin}), do: {:ok, {0, 2, 4}}
  # Linux: SOL_SOCKET (1), SO_PEERCRED (17), a struct ucred {pid, uid, gid}.
  defp peer_pid_option({:unix, :linux}), do: {:ok, {1, 17, 12}}
  defp peer_pid_option(os), do: {:error, {:unsupported_os, os}}

  # A peer in another pid namespace (a container sharing the socket file) reads
  # as pid 0, and is refused here rather than placed.
  defp decode_pid(<<pid::native-signed-32, _rest::binary>>) when pid > 0, do: {:ok, pid}
  defp decode_pid(value), do: {:error, {:invalid_peer_pid, value}}

  # macOS has no /proc, so one ps run lists every process.
  defp process_table({:unix, :darwin}), do: ps_table()
  # Linux reads the kernel's own /proc: no spawn, and no dependency on procps,
  # which minimal installs and containers do not ship.
  defp process_table({:unix, :linux}), do: proc_table()
  defp process_table(os), do: {:error, {:unsupported_os, os}}

  defp ps_table do
    args = ["-A", "-o", "pid=,ppid=,pgid=,tdev="]

    case CommandRunner.run(@ps, args, timeout_ms: @ps_timeout_ms) do
      # CommandRunner reports output past its cap as exit 124, so this goes first.
      {:ok, %{truncated?: true}} -> {:error, :process_table_truncated}
      {:ok, %{exit: 0, stdout: out}} -> parse_ps(out)
      {:ok, %{exit: code, stdout: out}} -> {:error, {:ps_failed, code, String.slice(out, 0, 200)}}
      {:error, reason} -> {:error, {:ps_failed, reason}}
    end
  end

  defp parse_ps(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, %{}}, fn line, {:ok, table} ->
      line |> String.split() |> parse_row(&ps_tdev/1) |> put_row(line, table)
    end)
  end

  # ps prints a controlling terminal as `major/minor`, and `??` for none.
  defp ps_tdev("??"), do: {:ok, false}
  defp ps_tdev(tdev), do: if(tdev =~ ~r/\A\d+\/\d+\z/, do: {:ok, true}, else: :error)

  defp proc_table do
    case File.ls(@proc) do
      {:ok, names} -> names |> Enum.filter(&(&1 =~ ~r/\A\d+\z/)) |> read_stats()
      {:error, reason} -> {:error, {:proc_unreadable, reason}}
    end
  end

  defp read_stats(pid_names) do
    Enum.reduce_while(pid_names, {:ok, %{}}, fn name, {:ok, table} ->
      case File.read(Path.join([@proc, name, "stat"])) do
        {:ok, stat} -> stat |> stat_fields() |> parse_row(&proc_tty_nr/1) |> put_row(stat, table)
        # It exited after the listing, or belongs to another account under
        # hidepid: either way this account cannot place it, as ps would not list it.
        {:error, reason} when reason in [:enoent, :esrch, :eacces] -> {:cont, {:ok, table}}
        {:error, reason} -> {:halt, {:error, {:proc_unreadable, name, reason}}}
      end
    end)
  end

  # `pid (comm) state ppid pgrp session tty_nr …`: comm may hold spaces and
  # parentheses, so the fields after it are read past the LAST ")".
  defp stat_fields(stat) do
    [pid_text | _rest] = String.split(stat, " ", parts: 2)

    case stat |> String.split(")") |> List.last() |> String.split() do
      [_state, parent_text, group_text, _session, tty_text | _more] ->
        [pid_text, parent_text, group_text, tty_text]

      _malformed ->
        :malformed
    end
  end

  # /proc's tty_nr is 0 for a process with no controlling terminal.
  defp proc_tty_nr(tty_text) do
    case Integer.parse(tty_text) do
      {tty_nr, ""} -> {:ok, tty_nr != 0}
      _malformed -> :error
    end
  end

  defp parse_row([pid_text, parent_text, group_text, terminal_text], decode_terminal) do
    with {pid, ""} <- Integer.parse(pid_text),
         {parent, ""} <- Integer.parse(parent_text),
         {group, ""} <- Integer.parse(group_text),
         {:ok, terminal?} <- decode_terminal.(terminal_text) do
      {:ok, pid, {parent, group, terminal?}}
    else
      _malformed -> :error
    end
  end

  defp parse_row(_fields, _decode_terminal), do: :error

  defp put_row({:ok, pid, entry}, _source, table), do: {:cont, {:ok, Map.put(table, pid, entry)}}
  defp put_row(:error, source, _table), do: {:halt, {:error, {:unparseable_process_row, source}}}
end
