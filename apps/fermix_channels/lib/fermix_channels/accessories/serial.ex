defmodule FermixChannels.Accessories.Serial do
  @moduledoc """
  The USB serial transport under an accessory link (M91 §05), on macOS: one
  `fermix_serial` helper process per open port, and one more per enumeration.

  The helper is a small C port program (`apps/fermix_nif/c_src/fermix_serial.c`
  holds its contract) that `fermix_nif`'s Makefile builds beside the `disclaim`
  shim into `priv/fermix_serial`, on a native macOS build with `cc` and in the
  release's macOS cross-builds with `zig cc`. It speaks `{:packet, 4}`:

    * `list` sends one `P` packet per USB serial port and a closing `Z` with the
      count, read from the IORegistry alone (no device is opened);
    * `open <path>` opens the port exclusively, in raw mode, in the control-line
      order the accessory needs (PROTOCOL.md, "Opening the port"): RTS cleared
      while DTR is still high, then DTR, then nothing more. It answers `O` with
      the lines `:cleared`, or `:absent` on a device without them (a
      pseudo-terminal), or `E` with a refusal, and then relays: `D` bytes from
      the port, an `E` when the port goes, and each packet written to it.

  ## Why a helper of our own

  A serial library from Hex was the other choice, and the maintained one,
  `circuits_uart` (1.7.0, read from its published source, not added), does not
  fit the release:

    * Its Makefile links `-framework CoreFoundation -framework IOKit` on a Mac,
      and its macOS enumeration includes `<IOKit/IOKitLib.h>`. The release
      cross-builds macOS on Linux with `zig cc`, which has neither header nor
      framework: `zig cc -target aarch64-macos` fails on both, even on a Mac.
    * It builds with `elixir_make`, so Burrito's NIF recompile
      (`Burrito.Steps.Patch.RecompileNIFs`) would rebuild it with a `CC` of
      `zig cc ... -dynamic -shared ...`, and its port executable,
      `priv/circuits_uart`, would come out a shared library.
    * Its open takes `flock` and flushes, with no `TIOCEXCL` and the lines left
      as macOS sets them at open, so the safe order would be two more calls
      after the open, and its port program would spawn without the disclaim
      shim.

  `fermix_serial` loads IOKit and CoreFoundation with `dlopen` at run time and
  links no framework, so it cross-builds like the shim, under the same strict
  flags (`SERIAL_CFLAGS`, and ci.yml's `disclaim-shim` job).

  ## The process

  Spawned through the `disclaim` exec shim on macOS, so the helper is its own
  TCC responsible process (`spawn_plan/3`); a missing shim or helper, or any
  other OS, is `{:error, {:unavailable, reason}}`, the reason a sentence the
  caller logs, and there is no undisclaimed spawn. The environment is not passed on.

  `open/2` opens the port in the caller's process, which owns it and receives
  its messages. The port stays linked to the owner: an unlinked port outlives
  the process that opened it, and the helper would keep the device. When the
  owner goes, the port closes, the helper reads the end of its stdin, closes
  the device and exits. The helper never exits while the daemon may still write
  to it: after any `E` it has already closed the device and reads its stdin
  until the port closes, so a write never meets a closed pipe, whose EPIPE
  would end a linked owner. An owner that traps exits has the port's
  `{:EXIT, port, reason}` recognised by `message/2`, and taken by every
  teardown, so nothing of a closed handle is left behind.

  Writes never suspend the owner: the port's busy limits are off, and `write/2`
  refuses `{:error, :write_backlog}` once more than `:max_backlog_bytes` are
  queued for the helper. A write is sent in packets of at most 16,384 bytes,
  each of which the helper writes whole within 2 s or ends the handle with
  `:write_stall`.

  `close/1` returns once the helper is gone: SIGTERM to its process group, then
  its exit status (an exit status arrives only after the process has exited and
  its descriptors closed), SIGKILL if that has not come within 2 s. So when it
  returns, the port is free for a reopen or a firmware installer. It unlinks the
  port just before the signal: a helper killed with bytes still queued for it
  fails the port's next write with EPIPE, and the port's `:DOWN` then stands in
  for the exit status.

  `message/2` answers the transport's messages, and these `{:closed, reason}`s
  beyond `:vanished` and `:write_stall`: `{:io_error, code}` (the helper's own
  words), `{:exit, status}` (the helper ended without saying why),
  `{:port_exit, reason}` (the port itself failed, for an owner that traps
  exits) and `{:protocol_error, tag}` (a packet the contract does not have).
  """

  @behaviour FermixChannels.Accessories.Transport

  require Logger

  alias FermixChannels.Accessories.Transport
  alias FermixCore.ProcessGroup

  @enforce_keys [:port, :path, :os_pid, :modem_lines, :max_backlog_bytes]
  defstruct @enforce_keys

  @typedoc "An open port: the helper's port, the device path and its control lines."
  @type t :: %__MODULE__{
          port: port(),
          path: String.t(),
          os_pid: pos_integer() | nil,
          modem_lines: :cleared | :absent,
          max_backlog_bytes: non_neg_integer()
        }

  @open_timeout_ms 5_000
  @list_timeout_ms 3_000
  @max_backlog_bytes 65_536
  @exit_wait_ms 2_000
  @max_packet_bytes 16_384
  @max_path_bytes 1_024
  @max_serial_bytes 255
  @max_ports 64
  # 64 ports of at most 1,293 bytes on the wire each, and the closing packet.
  @max_list_bytes 131_072
  @shim_exits [70, 71, 72, 74, 75]

  @port_options [
    :binary,
    {:packet, 4},
    :exit_status,
    :use_stdio,
    :hide,
    {:busy_limits_port, :disabled}
  ]

  @not_macos "the accessory serial transport is macOS-only"
  @helper_missing "the fermix_serial helper is not in this build: rebuild fermix " <>
                    "(mix compile) or reinstall"
  @shim_missing "the macOS disclaim shim is not built: rebuild fermix (mix compile) or reinstall"

  @doc "Where the build puts the helper: `fermix_nif`'s `priv/fermix_serial`."
  @spec helper_path() :: Path.t()
  def helper_path, do: Application.app_dir(:fermix_nif, "priv/fermix_serial")

  @doc """
  The spawn target and argv for the helper (`nil` for a missing helper or
  shim): on macOS through the `disclaim` exec shim. Any other OS, a missing
  helper and a missing shim refuse; there is no undisclaimed spawn. The
  pattern of `FermixCore.Tools.PlaceSearch.AppleMaps.spawn_plan/3`, for a
  helper that exists only on macOS.
  """
  @spec spawn_plan(Path.t() | nil, {atom(), atom()}, Path.t() | nil) ::
          {:ok, {Path.t(), [String.t()]}} | {:error, String.t()}
  def spawn_plan(_helper, os_type, _shim) when os_type != {:unix, :darwin},
    do: {:error, @not_macos}

  def spawn_plan(nil, _os_type, _shim), do: {:error, @helper_missing}
  def spawn_plan(_helper, _os_type, nil), do: {:error, @shim_missing}

  def spawn_plan(helper, _os_type, shim) when is_binary(helper) and is_binary(shim),
    do: {:ok, {shim, [helper]}}

  @doc """
  The ports attached now, from the IORegistry alone. `opts` may name
  `:helper_path`, `:shim_path`, `:os_type` and `:list_timeout_ms` (default
  #{@list_timeout_ms}) for a test.
  """
  @impl true
  @spec enumerate(keyword()) :: {:ok, [Transport.port_info()]} | {:error, term()}
  def enumerate(opts) when is_list(opts) do
    timeout_ms = positive!(opts, :list_timeout_ms, @list_timeout_ms)

    with {:ok, {executable, args}} <- plan(["list"], opts, :enumerate),
         {:ok, port, os_pid} <- spawn_helper(executable, args) do
      deadline = System.monotonic_time(:millisecond) + timeout_ms
      port |> collect_list(deadline, [], 0) |> finish_list(port, os_pid)
    end
  end

  @doc """
  Opens `path` for the calling process alone. `opts` may name `:helper_path`,
  `:shim_path`, `:os_type`, `:open_timeout_ms` (default #{@open_timeout_ms})
  and `:max_backlog_bytes` (default #{@max_backlog_bytes}).
  """
  @impl true
  @spec open(String.t(), keyword()) :: {:ok, t()} | {:error, Transport.open_error()}
  def open(path, opts) when is_binary(path) and is_list(opts) do
    timeout_ms = positive!(opts, :open_timeout_ms, @open_timeout_ms)
    backlog = positive!(opts, :max_backlog_bytes, @max_backlog_bytes)

    with :ok <- check_path(path),
         {:ok, {executable, args}} <- plan(["open", path], opts, :open),
         {:ok, port, os_pid} <- spawn_open(executable, args) do
      await_open(port, %{path: path, os_pid: os_pid, backlog: backlog}, timeout_ms)
    end
  end

  @doc """
  Queues `data` for the port, in order, unless more than the handle's backlog
  bound is already queued (`{:error, :write_backlog}`) or the port is closed.
  """
  @impl true
  @spec write(t(), iodata()) :: :ok | {:error, :write_backlog | :closed}
  def write(%__MODULE__{port: port, max_backlog_bytes: bound}, data)
      when is_binary(data) or is_list(data) do
    case :erlang.port_info(port, :queue_size) do
      {:queue_size, queued} when queued > bound -> {:error, :write_backlog}
      {:queue_size, _queued} -> send_packets(port, IO.iodata_to_binary(data))
      :undefined -> {:error, :closed}
    end
  end

  @doc "Ends the helper and closes the port; returns once the device is free. Idempotent."
  @impl true
  @spec close(t()) :: :ok
  def close(%__MODULE__{port: port, os_pid: os_pid}), do: stop(port, os_pid)

  @doc "Whether a message the owner received is this handle's, and what it says."
  @impl true
  @spec message(t(), term()) :: {:data, binary()} | {:closed, Transport.close_reason()} | :unknown
  def message(%__MODULE__{port: port}, {port, {:data, <<"D", bytes::binary>>}}),
    do: {:data, bytes}

  # The helper closed the device before it said why, and ends once its stdin does.
  def message(%__MODULE__{port: port}, {port, {:data, <<"E", code::binary>>}}) do
    release(port, true)
    {:closed, close_reason(code)}
  end

  def message(%__MODULE__{port: port, os_pid: os_pid}, {port, {:data, packet}}) do
    stop(port, os_pid)
    {:closed, {:protocol_error, packet_tag(packet)}}
  end

  def message(%__MODULE__{port: port}, {port, {:exit_status, status}}) do
    release(port, true)
    {:closed, {:exit, status}}
  end

  def message(%__MODULE__{port: port}, {:EXIT, port, reason}) do
    release(port, false)
    {:closed, {:port_exit, reason}}
  end

  def message(%__MODULE__{}, _message), do: :unknown

  @doc """
  The `list` packets, in order, as ports (pure). Every packet must be a well
  formed `P`, at most #{@max_ports}, then exactly one `Z` with their count:
  anything else fails the whole listing, never a partial one.
  """
  @spec decode_list([binary()]) :: {:ok, [Transport.port_info()]} | {:error, {:bad_list, term()}}
  def decode_list(packets) when is_list(packets), do: decode_packets(packets, [], 0)

  # -- the plan ----------------------------------------------------------------

  defp plan(command, opts, site) do
    helper = Keyword.get_lazy(opts, :helper_path, &helper_path/0)
    shim = Keyword.get_lazy(opts, :shim_path, &shim_path/0)
    os_type = Keyword.get_lazy(opts, :os_type, &:os.type/0)

    case spawn_plan(present(helper), os_type, present(shim)) do
      {:ok, {executable, args}} -> {:ok, {executable, args ++ command}}
      {:error, reason} -> unavailable(site, "#{reason} (helper #{helper}, disclaim shim #{shim})")
    end
  end

  defp shim_path, do: Application.app_dir(:fermix_nif, "priv/disclaim")

  defp present(path) when is_binary(path), do: if(File.regular?(path), do: path, else: nil)

  # Said by the caller, not here: the reason travels in the error, and the
  # watcher logs an enumeration failure once per change, so a build without the
  # helper is one line, not one a poll. No state is kept here.
  defp unavailable(site, reason), do: {:error, {:unavailable, "#{site}: #{reason}"}}

  defp check_path(path) do
    if byte_size(path) in 1..@max_path_bytes and not String.contains?(path, <<0>>),
      do: :ok,
      else: {:error, {:open_failed, :bad_path}}
  end

  defp positive!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      other -> raise ArgumentError, "#{key} must be a positive integer, got: #{inspect(other)}"
    end
  end

  # -- the process --------------------------------------------------------------

  defp spawn_helper(executable, args) do
    options = [{:args, args}, {:env, unset_environment()} | @port_options]
    port = Port.open({:spawn_executable, executable}, options)
    {:ok, port, os_pid(port)}
  rescue
    # A file that is present but cannot be run: Port.open raises the spawn's
    # errno (`eacces`, `enoexec`), or ArgumentError for a path it rejects.
    error in [ArgumentError, ErlangError] ->
      Logger.warning("fermix_serial could not be started: #{Exception.message(error)}")
      {:error, {:spawn_failed, Exception.message(error)}}
  end

  defp spawn_open(executable, args) do
    case spawn_helper(executable, args) do
      {:ok, port, os_pid} -> {:ok, port, os_pid}
      {:error, reason} -> {:error, {:open_failed, reason}}
    end
  end

  # A helper that exited at once has closed its port before its pid is read,
  # and Port.info/2 answers nil; its packets and exit status are still in the
  # mailbox and end the call there.
  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      nil -> nil
    end
  end

  # The helper needs nothing from the daemon's environment, which may carry
  # secrets, so every inherited variable is unset for it.
  defp unset_environment do
    Enum.map(System.get_env(), fn {name, _value} -> {String.to_charlist(name), false} end)
  end

  defp await_open(port, opened, timeout_ms) do
    receive do
      {^port, {:data, <<"O", lines>>}} when lines in [0, 1] ->
        {:ok, handle(port, opened, lines)}

      {^port, {:data, <<"E", code::binary>>}} ->
        release(port, true)
        {:error, refusal(code)}

      {^port, {:data, packet}} ->
        stop(port, opened.os_pid)
        {:error, {:open_failed, {:protocol_error, packet_tag(packet)}}}

      {^port, {:exit_status, status}} ->
        release(port, true)
        {:error, {:open_failed, exit_failure(status)}}
    after
      timeout_ms ->
        stop(port, opened.os_pid)
        {:error, {:open_failed, :timeout}}
    end
  end

  defp handle(port, opened, lines) do
    %__MODULE__{
      port: port,
      path: opened.path,
      os_pid: opened.os_pid,
      modem_lines: if(lines == 1, do: :cleared, else: :absent),
      max_backlog_bytes: opened.backlog
    }
  end

  defp refusal("busy"), do: :busy
  defp refusal("not_found"), do: :not_found
  defp refusal("permission"), do: :permission
  defp refusal(code), do: {:open_failed, code}

  defp exit_failure(status) when status in @shim_exits, do: {:disclaim, status}
  defp exit_failure(status), do: {:exit, status}

  defp close_reason("vanished"), do: :vanished
  defp close_reason("write_stall"), do: :write_stall
  defp close_reason(code), do: {:io_error, code}

  defp packet_tag(<<tag, _rest::binary>>), do: <<tag>>
  defp packet_tag(<<>>), do: :empty

  defp send_packets(_port, <<>>), do: :ok

  defp send_packets(port, <<packet::binary-size(@max_packet_bytes), rest::binary>>) do
    with :ok <- command(port, packet), do: send_packets(port, rest)
  end

  defp send_packets(port, packet), do: command(port, packet)

  defp command(port, packet) do
    Port.command(port, packet)
    :ok
  rescue
    ArgumentError -> {:error, :closed}
  end

  # -- teardown -------------------------------------------------------------------

  # Ends a helper that may still hold the device and proves it gone. Killing a
  # helper with bytes still queued for it fails the port's next write with
  # EPIPE, and that exit would end a linked owner, so the port is first
  # unlinked and monitored: its exit status, or its `:DOWN`, arrives only once
  # the helper has exited (its descriptors close as it exits). An exit signal
  # the link had already delivered is taken by `release/2`.
  defp stop(port, os_pid) do
    if Port.info(port) != nil do
      monitor = Port.monitor(port)
      Process.unlink(port)
      end_helper(port, monitor, os_pid)
      Port.demonitor(monitor, [:flush])
    end

    release(port, false)
  end

  defp end_helper(port, monitor, os_pid) do
    signal(os_pid, :sigterm)

    if gone?(port, monitor) do
      true
    else
      signal(os_pid, :sigkill)
      gone?(port, monitor) or unended(os_pid)
    end
  end

  defp signal(nil, _signal), do: :ok
  defp signal(os_pid, signal), do: ProcessGroup.signal(os_pid, signal)

  defp gone?(port, monitor) do
    receive do
      {^port, {:exit_status, _status}} -> true
      {:DOWN, ^monitor, :port, ^port, _reason} -> true
    after
      @exit_wait_ms -> false
    end
  end

  defp unended(os_pid) do
    Logger.error(
      "fermix_serial (pid #{inspect(os_pid)}) did not exit #{@exit_wait_ms} ms after SIGKILL; " <>
        "closing its port"
    )

    false
  end

  # Closes the port and takes every message it left, so nothing more of the
  # handle reaches the owner. A port still linked to an owner that traps exits
  # sends it an exit signal as it closes, whether this closed it or it closed
  # itself (`exit_due?`): that is waited for and taken. One the link delivered
  # before `stop/2` unlinked it is taken either way.
  defp release(port, exit_due?) do
    close_port(port)
    take_exit_signal(port, if(exit_due? and trapping_exits?(), do: @exit_wait_ms, else: 0))
    flush(port)
  end

  # A port whose helper exited closes itself; closing it again raises.
  defp close_port(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp trapping_exits? do
    {:trap_exit, trapping?} = Process.info(self(), :trap_exit)
    trapping?
  end

  defp take_exit_signal(port, wait_ms) do
    receive do
      {:EXIT, ^port, _reason} -> :ok
    after
      wait_ms -> :ok
    end
  end

  defp flush(port) do
    receive do
      {^port, _message} -> flush(port)
    after
      0 -> :ok
    end
  end

  # -- listing --------------------------------------------------------------------

  # One receive loop, bounded by the call's deadline and by the bytes received.
  defp collect_list(port, deadline, packets, bytes) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, packet}} ->
        more_list(port, deadline, [packet | packets], bytes + 4 + byte_size(packet))

      {^port, {:exit_status, status}} ->
        {:exited, status, Enum.reverse(packets)}
    after
      remaining -> :timeout
    end
  end

  defp more_list(_port, _deadline, _packets, bytes) when bytes > @max_list_bytes, do: :too_large
  defp more_list(port, deadline, packets, bytes), do: collect_list(port, deadline, packets, bytes)

  defp finish_list({:exited, 0, packets}, port, _os_pid) do
    release(port, true)
    decode_list(packets)
  end

  defp finish_list({:exited, status, packets}, port, _os_pid) do
    release(port, true)
    {:error, {:enumerate_failed, list_failure(status, packets)}}
  end

  defp finish_list(failure, port, os_pid) when failure in [:timeout, :too_large] do
    stop(port, os_pid)
    {:error, {:enumerate_failed, failure}}
  end

  defp list_failure(status, _packets) when status in @shim_exits, do: {:disclaim, status}

  defp list_failure(status, packets) do
    case List.last(packets) do
      <<"E", code::binary>> -> code
      _other -> {:exit, status}
    end
  end

  # -- decoding (pure) ------------------------------------------------------------

  defp decode_packets([<<"Z", count::16>>], ports, seen) when count == seen,
    do: {:ok, Enum.reverse(ports)}

  defp decode_packets([<<"Z", count::16>>], _ports, seen),
    do: {:error, {:bad_list, {:count, count, seen}}}

  defp decode_packets([<<"P", body::binary>> | rest], ports, seen) when seen < @max_ports do
    case decode_port(body) do
      {:ok, port} -> decode_packets(rest, [port | ports], seen + 1)
      {:error, why} -> {:error, {:bad_list, why}}
    end
  end

  defp decode_packets([<<"P", _body::binary>> | _rest], _ports, _seen),
    do: {:error, {:bad_list, :too_many_ports}}

  defp decode_packets([], _ports, _seen), do: {:error, {:bad_list, :unterminated}}

  defp decode_packets([packet | _rest], _ports, _seen),
    do: {:error, {:bad_list, {:packet, packet_tag(packet)}}}

  defp decode_port(
         <<flags, vid::16, pid::16, path_len::16, path::binary-size(path_len), serial_len::16,
           serial::binary-size(serial_len)>>
       ) do
    with :ok <- check_flags(flags, vid, pid, serial),
         :ok <- check_text(path, 1, @max_path_bytes, :path),
         :ok <- check_text(serial, 0, @max_serial_bytes, :serial) do
      ids? = Bitwise.band(flags, 1) == 1

      {:ok,
       %{
         path: path,
         vendor_id: if(ids?, do: vid),
         product_id: if(ids?, do: pid),
         serial: if(Bitwise.band(flags, 2) == 2, do: serial)
       }}
    end
  end

  defp decode_port(_body), do: {:error, :malformed_port}

  defp check_flags(flags, _vid, _pid, _serial) when flags > 3, do: {:error, {:flags, flags}}

  defp check_flags(flags, vid, pid, _serial) when Bitwise.band(flags, 1) == 0 and vid + pid > 0,
    do: {:error, :ids_without_flag}

  defp check_flags(flags, _vid, _pid, serial) when Bitwise.band(flags, 2) == 0 and serial != "",
    do: {:error, :serial_without_flag}

  defp check_flags(_flags, _vid, _pid, _serial), do: :ok

  defp check_text(text, min, max, field) do
    if byte_size(text) in min..max and String.valid?(text) and not String.contains?(text, <<0>>),
      do: :ok,
      else: {:error, {:bad_text, field}}
  end
end
