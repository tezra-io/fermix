defmodule FermixCore.Meetings.Sidecar.Port do
  @moduledoc """
  Production `FermixCore.Meetings.Sidecar`: an Erlang Port to the
  `fermix-meetbot` binary, owned by the calling process.

  There is no GenServer here on purpose — the caller
  (`FermixCore.Meetings.SidecarSource`) already is one, and a second process
  between it and the port would only add a hop where a frame can be lost. The
  port is opened by the caller, so port messages land in the caller's mailbox
  and `handle_message/2` normalizes them.

  Framing is `{:packet, 4}` in both directions (see `Sidecar.Frame`). Note the
  absence of `:stderr_to_stdout`: the sidecar's stderr must stay off the data
  channel, because a single diagnostic line written there would be read as a
  length prefix and desync every frame after it.

  ## macOS disclaim

  The sidecar drives Chromium, and a GUI child spawned bare inherits fermix as
  its TCC *responsible process* — attributing its activity to a daemon whose
  identity changes path and cdhash on every release, which is how the App
  Management prompt re-fires per upgrade. So on macOS the binary is spawned
  through the `disclaim` exec shim (`fermix_nif` priv), which SETEXECs it in
  place (same pid, fds intact). A missing shim refuses loud; there is no
  undisclaimed spawn. `FermixCore.Browser.ChromeLauncher.spawn_plan/4` is the
  master copy of this rule — `spawn_plan/4` below is a deliberate ~15-line
  duplicate rather than a shared extraction, and both copies are pinned by
  their own failure-copy test.
  """

  @behaviour FermixCore.Meetings.Sidecar

  alias FermixCore.Meetings.Sidecar.Frame
  alias FermixCore.ProcessGroup
  alias FermixCore.Timeouts

  @typedoc "Port state, held by the owner process."
  @type state :: %{port: port(), os_pid: pos_integer(), owner: pid()}

  # The sidecar's own contract is to leave the meeting and exit within 2 s of
  # stdin EOF. This is how long we honor it before the group SIGKILL; there is
  # no SIGTERM step, because EOF already is the polite path.
  @eof_grace_ms 2_000

  @shim_missing_message "macOS disclaim shim is not built — rebuild fermix (mix compile) or reinstall"

  @impl true
  @spec launch(pid(), keyword()) :: {:ok, state()} | {:error, term()}
  def launch(owner, opts) when is_pid(owner) and is_list(opts) do
    binary_path = Keyword.fetch!(opts, :binary_path)
    profile_dir = Keyword.fetch!(opts, :profile_dir)
    timeout_ms = Keyword.get(opts, :handshake_timeout_ms, Timeouts.meetbot_handshake())
    args = Keyword.get(opts, :args, [])

    with :ok <- ensure_binary(binary_path),
         :ok <- ensure_profile_dir(profile_dir),
         {:ok, {executable, spawn_args}} <-
           spawn_plan(binary_path, args, :os.type(), disclaim_shim_path()),
         {:ok, state} <- open(owner, executable, spawn_args, Keyword.get(opts, :env, [])),
         :ok <- handshake(state, timeout_ms) do
      {:ok, state}
    end
  end

  @impl true
  @spec send_control(state(), map()) :: :ok | {:error, :closed}
  def send_control(%{port: port}, msg) when is_map(msg) do
    Port.command(port, Frame.encode_control(msg))
    :ok
  rescue
    # Port.command raises once the port is closed — the sidecar is gone.
    ArgumentError -> {:error, :closed}
  end

  @impl true
  @spec handle_message(state(), term()) :: FermixCore.Meetings.Sidecar.event()
  def handle_message(%{port: port} = state, {from, {:data, frame}}) when from == port do
    case handle_frame(state, frame) do
      {:control, msg} -> {:sidecar_control, msg}
      {:audio, pcm} -> {:sidecar_audio, pcm}
      {:protocol_error, reason} -> {:sidecar_exit, {:protocol_error, reason}}
    end
  end

  def handle_message(%{port: port}, {from, {:exit_status, status}}) when from == port,
    do: {:sidecar_exit, status}

  def handle_message(_state, _message), do: :ignore

  @doc """
  Decodes one wire frame. Pure delegation to `Frame.decode/1`, exposed because
  the owner may want the frame classification without the message wrapper.
  """
  @spec handle_frame(state(), binary()) ::
          {:control, map()} | {:audio, binary()} | {:protocol_error, Frame.decode_error()}
  def handle_frame(_state, frame) when is_binary(frame) do
    case Frame.decode(frame) do
      {:error, reason} -> {:protocol_error, reason}
      decoded -> decoded
    end
  end

  @impl true
  @spec stop(state()) :: :ok
  def stop(%{port: port, os_pid: os_pid}) do
    if Port.info(port) do
      close(port)
      _ = await_exit(port, @eof_grace_ms)
    end

    # Unconditional, even when the direct child already exited: the sidecar is a
    # process-group leader and Playwright's Chromium descendants only die with
    # the group. `:esrch` on an empty group is silent success.
    ProcessGroup.signal(os_pid, :sigkill)
    flush(port)
    :ok
  end

  @doc """
  Computes the spawn target and argv. Exposed for tests; see the moduledoc for
  why macOS never spawns the sidecar directly.
  """
  @spec spawn_plan(String.t(), [String.t()], {atom(), atom()}, String.t() | nil) ::
          {:ok, {String.t(), [String.t()]}} | {:error, {:disclaim_shim_missing, String.t()}}
  def spawn_plan(_binary_path, _args, {:unix, :darwin}, nil),
    do: {:error, {:disclaim_shim_missing, @shim_missing_message}}

  def spawn_plan(binary_path, args, {:unix, :darwin}, shim) when is_binary(shim),
    do: {:ok, {shim, [binary_path | args]}}

  def spawn_plan(binary_path, args, _os_type, _shim), do: {:ok, {binary_path, args}}

  defp open(owner, executable, args, env) do
    port =
      Port.open({:spawn_executable, executable}, [
        {:packet, 4},
        :binary,
        :exit_status,
        {:args, args},
        {:env, env}
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    {:ok, %{port: port, os_pid: os_pid, owner: owner}}
  rescue
    # A present but non-executable file: Port.open refuses with ArgumentError.
    ArgumentError -> {:error, {:spawn_failed, executable}}
  end

  # `hello` MUST be the first frame. Anything else — including a valid but
  # premature control message — is a sidecar that does not speak this protocol.
  defp handshake(%{port: port} = state, timeout_ms) do
    receive do
      {^port, {:data, frame}} -> check_hello(state, Frame.decode(frame))
      {^port, {:exit_status, status}} -> refuse(state, {:sidecar_exited, status})
    after
      timeout_ms ->
        stop(state)
        {:error, {:handshake_timeout, timeout_ms}}
    end
  end

  defp check_hello(state, {:control, %{"type" => "hello"} = hello}),
    do: check_version(state, hello)

  defp check_hello(state, {:control, %{"type" => type}}),
    do: refuse(state, {:protocol_error, {:hello_expected, type}})

  defp check_hello(state, {:audio, _pcm}),
    do: refuse(state, {:protocol_error, {:hello_expected, :audio}})

  defp check_hello(state, {:error, reason}), do: refuse(state, {:protocol_error, reason})

  defp check_version(state, %{"protocol_version" => version}) when is_integer(version) do
    if version == Frame.protocol_version() do
      :ok
    else
      refuse(state, {:protocol_mismatch, %{daemon: Frame.protocol_version(), sidecar: version}})
    end
  end

  defp check_version(state, _hello),
    do: refuse(state, {:protocol_error, :hello_missing_protocol_version})

  defp refuse(state, reason) do
    stop(state)
    {:error, reason}
  end

  defp ensure_binary(path) do
    if File.regular?(path), do: :ok, else: {:error, {:sidecar_missing, path}}
  end

  # The profile holds the bot account's signed-in browser state; 0700 keeps it
  # readable only by the daemon's user. The daemon never reads inside it.
  defp ensure_profile_dir(dir) do
    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700) do
      :ok
    else
      {:error, reason} -> {:error, {:profile_dir_failed, dir, reason}}
    end
  end

  defp disclaim_shim_path do
    path = Application.app_dir(:fermix_nif, "priv/disclaim")
    if File.regular?(path), do: path, else: nil
  end

  defp close(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # The sidecar's polite-leave window. `Port.close/1` detaches the port, so a
  # still-running child's exit is no longer observable here — the grace is a
  # fixed window by design, and the `exit_status` clause catches only a child
  # that died before the close. Late frames are discarded either way: teardown
  # output must never be left in the owner's mailbox.
  defp await_exit(port, grace_ms) do
    receive do
      {^port, {:exit_status, _status}} -> true
      {^port, {:data, _discard}} -> await_exit(port, grace_ms)
    after
      grace_ms -> false
    end
  end

  defp flush(port) do
    receive do
      {^port, _anything} -> flush(port)
    after
      0 -> :ok
    end
  end
end
