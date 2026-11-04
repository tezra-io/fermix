defmodule FermixCore.Sandbox.SocketReachTest do
  # Fermix's sockets never answer a command it confines, whichever kernel holds
  # the rule: on macOS the Seatbelt profile refuses the connect, and on Linux,
  # where Landlock cannot, the socket refuses the peer (`SocketPeer.admit/2`).
  # The command is the agent's own shell tool call, run through this
  # platform's real sandbox. The same client run unconfined is answered, so a
  # refusal is the sandbox's, never a socket that answers nobody.
  use ExUnit.Case, async: false

  alias Fermix.CLI.Daemon
  alias FermixCore.Management.Protocol
  alias FermixCore.Realtime.LocalVoiceSocket
  alias FermixCore.Sandbox.Config
  alias FermixCore.Tools.Shell

  @context %{agent_name: "test_agent", conversation_key: :test}

  # Connects to the socket, sends the request file's bytes, and says what came
  # of it: the connect refused (with its errno), an answer, or a close.
  @client """
  import socket, sys
  path, request = sys.argv[1], open(sys.argv[2], "rb").read()
  client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
  client.settimeout(10)
  try:
      client.connect(path)
  except OSError as error:
      print("refused", error.errno)
      sys.exit(0)
  try:
      client.sendall(request)
      print("answered" if client.recv(1) else "closed")
  except OSError:
      print("closed")
  """

  setup do
    sandbox = Application.get_env(:fermix_core, :sandbox)
    previous_home = System.get_env("FERMIX_HOME")
    # Short names throughout: a socket path must fit macOS's 104 bytes.
    home = FermixTestSupport.SafeRm.make_tmp_dir!("sr")
    workspace = Path.join(home, "workspace")
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "client.py"), @client)

    System.put_env("FERMIX_HOME", home)

    Application.put_env(
      :fermix_core,
      :sandbox,
      Config.normalize(mode: :strict, workspace_root: workspace)
    )

    on_exit(fn ->
      case sandbox do
        nil -> Application.delete_env(:fermix_core, :sandbox)
        value -> Application.put_env(:fermix_core, :sandbox, value)
      end

      case previous_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      FermixTestSupport.SafeRm.rm_rf!(home)
    end)

    tasks = start_supervised!({Task.Supervisor, name: :"socket_reach_tasks_#{inspect(self())}"})
    %{home: home, workspace: workspace, tasks: tasks}
  end

  test "the agent's shell command gets no answer from the daemon's socket", ctx do
    socket = Path.join(ctx.home, "d.sock")

    start_supervised!(
      {Daemon, name: :socket_reach_daemon, socket_path: socket, task_supervisor: ctx.tasks}
    )

    request =
      Jason.encode!(%{
        "request_id" => "reach-1",
        "protocol_version" => Protocol.protocol_version(),
        "method" => "hello",
        "params" => %{}
      })

    File.write!(Path.join(ctx.workspace, "d.req"), <<byte_size(request)::32, request::binary>>)
    assert_no_answer_from_the_sandbox(ctx, socket, "d.req")
  end

  test "the agent's shell command gets no answer from the voice socket", ctx do
    socket = Path.join(ctx.home, "r.sock")

    start_supervised!(
      {LocalVoiceSocket,
       name: :socket_reach_voice,
       socket_path: socket,
       task_supervisor: ctx.tasks,
       session_starter: fn _opts -> {:error, :not_in_this_test} end}
    )

    File.write!(
      Path.join(ctx.workspace, "r.req"),
      ~s({"type":"client_hello","protocol_version":1}\n)
    )

    assert_no_answer_from_the_sandbox(ctx, socket, "r.req")
  end

  defp assert_no_answer_from_the_sandbox(ctx, socket, request) do
    python = System.find_executable("python3") || flunk("python3 is required on this host")
    script = Path.join(ctx.workspace, "client.py")

    assert {"answered\n", 0} =
             System.cmd(python, [script, socket, Path.join(ctx.workspace, request)])

    command = "python3 client.py '#{socket}' '#{request}'"
    assert {:ok, result} = Shell.execute(%{"command" => command}, @context)
    assert String.trim(result.output) == confined_outcome()
  end

  # Seatbelt refuses the connect itself (EPERM); on Linux the connect succeeds
  # and the socket closes it unanswered.
  defp confined_outcome do
    case :os.type() do
      {:unix, :darwin} -> "refused 1"
      {:unix, :linux} -> "closed"
    end
  end
end
