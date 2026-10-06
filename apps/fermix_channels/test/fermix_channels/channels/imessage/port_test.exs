defmodule FermixChannels.Channels.IMessage.PortTest do
  @moduledoc """
  `IMessage.Port` against a fake helper script (MILESTONE_54 §5.1, §16): the
  `initialize` handshake, the protocol-mismatch refusal, request ids and
  timeouts, `busy`, exit-status classes and the single degraded/recovered
  transport transitions.

  The fake is a POSIX `sh` script written into a per-test home: it answers by
  method, records each spawn in `<home>/spawns`, exits with `<home>/exit_code`
  when that file exists and answers `initialize` with `<home>/protocol_version`.
  It uses only shell builtins, so nothing on PATH is involved.
  """
  use ExUnit.Case, async: false

  alias FermixChannels.Channels.IMessage.Port, as: HelperPort
  alias FermixTestSupport.SafeRm

  @script """
  #!/bin/sh
  home="$3"
  echo spawn >> "$home/spawns"
  if [ -f "$home/exit_code" ]; then
    read code < "$home/exit_code"
    exit "$code"
  fi
  version=1
  if [ -f "$home/protocol_version" ]; then
    read version < "$home/protocol_version"
  fi
  while IFS= read -r line; do
    id=${line#*\\"id\\":}
    id=${id%%,*}
    method=${line#*\\"method\\":\\"}
    method=${method%%\\"*}
    case "$method" in
      initialize)
        printf '{"id":%s,"result":{"protocol_version":%s,"helper_version":"0.0.0-test","macos_version":"27.0","bundle_id":"io.tezra.fermix.messages","db_generation":{"inode":7,"birth_time":"2026-09-01T00:00:00Z"}}}\\n' "$id" "$version" ;;
      probe)
        printf '{"id":%s,"result":{"db":"readable","echo":"%s"}}\\n' "$id" "$home" ;;
      watch.subscribe)
        printf '{"id":%s,"result":{"started_at_rowid":10,"replay_skipped":0}}\\n' "$id"
        printf '{"event":"watch.overflow","params":{"dropped":3,"resume_after_rowid":12}}\\n' ;;
      messages.after)
        printf '{"id":%s,"error":{"kind":"busy","message":"more than 32 outstanding requests","data":{}}}\\n' "$id" ;;
      policy.set)
        printf '{"id":%s,"error":{"kind":"teleported","message":"?","data":{}}}\\n' "$id" ;;
      grant)
        exit 75 ;;
      policy.get)
        : ;;
      shutdown)
        printf '{"id":%s,"result":{}}\\n' "$id"
        exit 0 ;;
      *)
        printf '{"id":%s,"result":{}}\\n' "$id" ;;
    esac
  done
  exit 0
  """

  setup do
    home = SafeRm.make_tmp_dir!("imessage-port")
    executable = Path.join(home, "fermix-messages")
    File.write!(executable, @script)
    File.chmod!(executable, 0o755)
    on_exit(fn -> SafeRm.rm_rf!(home) end)

    %{home: home, executable: executable}
  end

  defp start_port(ctx, extra \\ []) do
    opts =
      Keyword.merge(
        [
          name: :"imessage_port_#{System.unique_integer([:positive])}",
          executable: ctx.executable,
          home: ctx.home,
          backoff_initial_ms: 10,
          backoff_max_ms: 20
        ],
        extra
      )

    HelperPort.start_link(opts)
  end

  defp spawns(home) do
    case File.read(Path.join(home, "spawns")) do
      {:ok, body} -> body |> String.split("\n", trim: true) |> length()
      {:error, :enoent} -> 0
    end
  end

  # The handler runs in the emitting process, so `self()` there is the emitter:
  # the test pins every event to the Port under test, never to a neighbour.
  defp attach_transport_events do
    test_pid = self()
    handler_id = "imessage-port-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:fermix, :channel, :transport],
        fn _event, measurements, metadata, _config ->
          if metadata.channel == :imessage do
            send(test_pid, {:transport, self(), metadata.status, measurements, metadata})
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  describe "the initialize handshake" do
    test "answers requests by id and names the home it serves", ctx do
      {:ok, port} = start_port(ctx)

      assert {:ok, %{"db" => "readable", "echo" => home}} =
               HelperPort.call(port, "probe", %{}, 2_000)

      assert home == ctx.home
      assert HelperPort.home(port) == {:ok, ctx.home}
      assert %{status: :up, failures: 0} = HelperPort.status(port)
      assert spawns(ctx.home) == 1
    end

    test "a protocol mismatch refuses to start with that class", ctx do
      File.write!(Path.join(ctx.home, "protocol_version"), "2\n")
      Process.flag(:trap_exit, true)

      assert {:error, :helper_protocol_mismatch} = start_port(ctx)
      assert spawns(ctx.home) == 1
    end

    test "attach answers the handshake and forwards notifications in wire order", ctx do
      {:ok, port} = start_port(ctx)

      assert {:ok, %{"protocol_version" => 1, "db_generation" => %{"inode" => 7}}} =
               HelperPort.attach(port, self())

      assert {:ok, %{"started_at_rowid" => 10}} =
               HelperPort.call(port, "watch.subscribe", %{"since_rowid" => nil}, 2_000)

      assert_receive {:imessage_event, "watch.overflow", %{"dropped" => 3}}
    end
  end

  describe "requests" do
    test "an unanswered request times out with a typed error and the port stays up", ctx do
      {:ok, port} = start_port(ctx)

      assert {:error, {:request_timeout, _message, %{"method" => "policy.get"}}} =
               HelperPort.call(port, "policy.get", %{}, 50)

      assert {:ok, _probe} = HelperPort.call(port, "probe", %{}, 2_000)
    end

    test "the helper's busy is surfaced as its closed kind", ctx do
      {:ok, port} = start_port(ctx)

      assert {:error, {:busy, "more than 32 outstanding requests", %{}}} =
               HelperPort.call(port, "messages.after", %{}, 2_000)
    end

    test "more outstanding requests than the cap are refused as busy without being sent", ctx do
      {:ok, port} = start_port(ctx, max_outstanding: 1)
      task = Task.async(fn -> HelperPort.call(port, "policy.get", %{}, 1_000) end)

      assert_eventually(fn -> HelperPort.status(port).outstanding == 1 end)
      assert {:error, {:busy, _message, %{}}} = HelperPort.call(port, "probe", %{}, 1_000)
      assert {:error, {:request_timeout, _, _}} = Task.await(task)
    end

    test "an unknown error kind reaches the caller as a protocol error", ctx do
      {:ok, port} = start_port(ctx)

      assert {:error, {:protocol_error, _message, %{"kind" => "teleported"}}} =
               HelperPort.call(port, "policy.set", %{}, 2_000)
    end

    test "an unknown method never reaches the helper", ctx do
      {:ok, port} = start_port(ctx)

      assert {:error, {:protocol_error, _message, %{"method" => "messages.delete"}}} =
               HelperPort.call(port, "messages.delete", %{}, 2_000)
    end

    test "a port that is not running answers helper_unavailable" do
      assert {:error, {:helper_unavailable, _message, %{}}} =
               HelperPort.call(:imessage_port_not_running, "probe", %{}, 100)
    end
  end

  describe "exit status and restart" do
    test "a usage exit (64) is never retried and degrades once", ctx do
      attach_transport_events()
      File.write!(Path.join(ctx.home, "exit_code"), "64\n")

      {:ok, port} = start_port(ctx)

      assert_receive {:transport, ^port, :degraded, %{consecutive_failures: 1},
                      %{error_class: :helper_exit}}

      assert %{status: :failed, class: {:helper_exit, 64}} = HelperPort.status(port)
      assert spawns(ctx.home) == 1

      assert {:error, {:helper_unavailable, _message, %{"class" => "helper_exit 64"}}} =
               HelperPort.call(port, "probe", %{}, 100)
    end

    test "every disclaim exit class (70-72) is never retried", ctx do
      for code <- [70, 71, 72] do
        File.write!(Path.join(ctx.home, "exit_code"), "#{code}\n")
        {:ok, port} = start_port(ctx)

        assert %{status: :failed, class: {:helper_exit, ^code}} = HelperPort.status(port)
        GenServer.stop(port)
      end
    end

    test "a retryable exit backs off, degrades once, and recovers once", ctx do
      attach_transport_events()
      exit_code = Path.join(ctx.home, "exit_code")
      File.write!(exit_code, "75\n")

      {:ok, port} = start_port(ctx)
      assert HelperPort.attach(port, self()) |> elem(0) == :error

      assert_receive {:transport, ^port, :degraded, %{consecutive_failures: 1},
                      %{error_class: :helper_exit}}

      assert_eventually(fn -> spawns(ctx.home) >= 3 end)
      SafeRm.rm!(exit_code)

      assert_receive {:imessage_helper, :up, %{"protocol_version" => 1}}

      assert_receive {:transport, ^port, :recovered, %{consecutive_failures: failures},
                      %{error_class: :none}}

      assert failures >= 3
      refute_received {:transport, ^port, :degraded, _, _}
      assert %{status: :up, failures: 0} = HelperPort.status(port)
    end

    test "a helper that dies mid-request fails the caller and restarts", ctx do
      {:ok, port} = start_port(ctx)
      {:ok, _handshake} = HelperPort.attach(port, self())

      assert {:error, {:helper_unavailable, _message, %{"class" => "helper_exit 75"}}} =
               HelperPort.call(port, "grant", %{"service" => "automation"}, 2_000)

      assert_receive {:imessage_helper, :down, {:helper_exit, 75}}
      assert_receive {:imessage_helper, :up, _handshake}
      assert {:ok, _probe} = HelperPort.call(port, "probe", %{}, 2_000)
    end

    test "a missing executable backs off as helper_missing", ctx do
      {:ok, port} = start_port(ctx, executable: Path.join(ctx.home, "absent"))

      assert %{status: :backoff, class: :helper_missing} = HelperPort.status(port)
    end
  end

  test "stopping the port shuts the helper down", ctx do
    {:ok, port} = start_port(ctx)
    assert :ok = GenServer.stop(port)
    refute Process.alive?(port)
  end

  defp assert_eventually(fun, attempts \\ 200)

  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(5)
      assert_eventually(fun, attempts - 1)
    end
  end
end
