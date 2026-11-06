ExUnit.start()
Code.require_file("docker/audit_observer.exs", __DIR__)

defmodule FermixAuditObserverTest do
  use ExUnit.Case, async: false

  alias FermixCore.Agents.LifecycleTelemetry
  alias FermixCore.Trace.TelemetryHandler

  defp start_observer(opts \\ []) do
    test = self()

    writer = fn line ->
      send(test, {:line, line})
      :ok
    end

    fail = fn reason -> send(test, {:failed, reason}) end
    prefix = "audit-test-#{System.unique_integer([:positive])}"

    args = [
      run_id: "run-1",
      token: "private-token-123",
      prefix: prefix,
      write: writer,
      fail: fail
    ]

    {:ok, pid} = FermixAudit.Observer.start_link(Keyword.merge(args, opts))
    on_exit(fn -> TelemetryHandler.detach(prefix) end)
    pid
  end

  defp line do
    assert_receive {:line, "FERMIX_AUDIT_TRACE " <> json}, 2_000
    Jason.decode!(json)
  end

  test "streams correlated lifecycle, tool and provider events with ordered sequence" do
    pid = start_observer()
    assert %{"kind" => "start", "seq" => 1} = line()
    LifecycleTelemetry.agent_start("main", "agent", "session-a")

    FermixCore.Tools.Telemetry.exec(
      "browser",
      %{agent_name: "main", session_id: "session-a"},
      true,
      1
    )

    FermixCore.Providers.Telemetry.emit_call(%{agent: "main", provider: "fixture", model: "m"}, 2,
      session_id: "session-a"
    )

    assert :ok = FermixAudit.Observer.flush(pid)
    records = Enum.map(1..3, fn _ -> line() end)
    assert Enum.map(records, & &1["seq"]) == [2, 3, 4]
    assert Enum.map(records, & &1["type"]) == ["agent_event", "tool_exec", "llm_call"]
    assert Enum.all?(records, &(&1["data"]["session_id"] == "session-a"))
  end

  test "large captured provider content is preserved and true excess fails explicitly" do
    Process.flag(:trap_exit, true)
    previous = Application.fetch_env(:fermix_core, :telemetry)
    Application.put_env(:fermix_core, :telemetry, capture_content: true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:fermix_core, :telemetry, value)
        :error -> Application.delete_env(:fermix_core, :telemetry)
      end
    end)

    pid = start_observer()
    line()
    content = String.duplicate("a", 200_000)

    FermixCore.Providers.Telemetry.emit_call(
      %{agent: "main", provider: "fixture"},
      1,
      input: content
    )

    assert %{"kind" => "event", "data" => %{"input" => ^content}} = line()
    too_large = String.duplicate("b", 12 * 1024 * 1024 + 1)

    FermixCore.Providers.Telemetry.emit_call(
      %{agent: "main", provider: "fixture"},
      1,
      input: too_large
    )

    assert %{"kind" => "error", "reason" => "overflow"} = line()
    assert_receive {:failed, :overflow}, 2_000
    assert_receive {:EXIT, ^pid, _}, 2_000
  end

  test "total stream cap fails before the collector limit" do
    Process.flag(:trap_exit, true)
    pid = start_observer()
    line()
    content = String.duplicate("c", 10 * 1024 * 1024)

    for _ <- 1..3 do
      FermixCore.Providers.Telemetry.emit_call(%{agent: "main", content: content}, 1)
      assert %{"kind" => "event"} = line()
    end

    FermixCore.Providers.Telemetry.emit_call(%{agent: "main", content: content}, 1)
    assert %{"kind" => "error", "reason" => "overflow"} = line()
    assert_receive {:failed, :overflow}, 2_000
    assert_receive {:EXIT, ^pid, _}, 2_000
  end

  test "invalid public options are rejected" do
    assert {:error, :invalid_options} =
             FermixAudit.Observer.start_link(
               run_id: "r",
               token: "token-token",
               prefix: "p",
               max_events: 0
             )

    assert {:error, :invalid_options} =
             FermixAudit.Observer.start_link(
               run_id: "r",
               token: "token-token",
               prefix: "p",
               socket_path: "relative.sock"
             )

    assert {:error, :invalid_options} =
             FermixAudit.Observer.start_link(
               run_id: "r",
               token: "token-token",
               prefix: "p",
               max_events: 100_001
             )

    assert {:error, :invalid_options} =
             FermixAudit.Observer.start_link(
               run_id: "r",
               token: "token-token",
               prefix: "p",
               admit: :not_a_function
             )
  end

  test "missing event cannot satisfy a required correlated witness" do
    pid = start_observer()
    line()
    assert :ok = FermixAudit.Observer.flush(pid)
    refute_receive {:line, _}, 0
  end

  test "overflow reports failure instead of silently discarding" do
    Process.flag(:trap_exit, true)
    pid = start_observer(max_events: 1)
    line()
    FermixCore.Tools.Telemetry.exec("browser", %{agent_name: "main"}, true, 1)
    FermixCore.Tools.Telemetry.exec("browser", %{agent_name: "main"}, true, 1)
    assert %{"kind" => "event", "seq" => 2} = line()
    assert %{"kind" => "error", "seq" => 3, "reason" => "overflow"} = line()
    assert_receive {:failed, :overflow}, 2_000
    assert_receive {:EXIT, ^pid, _}, 2_000
  end

  test "private checkpoint follows preceding events and refuses invalid or unauthorized peers" do
    path =
      Path.join(System.tmp_dir!(), "audit-observer-#{System.unique_integer([:positive])}.sock")

    pid = start_observer(socket_path: path, admit: fn _socket, _os -> :ok end)
    line()
    assert {:ok, %{mode: mode}} = File.stat(path)
    assert Bitwise.band(mode, 0o777) == 0o600
    FermixCore.Tools.Telemetry.exec("browser", %{agent_name: "main"}, true, 1)

    assert {:ok, socket} =
             :gen_tcp.connect(
               {:local, String.to_charlist(path)},
               0,
               [:binary, active: false, packet: :line],
               2_000
             )

    :ok = :gen_tcp.send(socket, ~s({"op":"checkpoint","nonce":"0123456789abcdef"}\n))
    assert {:ok, reply} = :gen_tcp.recv(socket, 0, 2_000)
    assert %{"seq" => 3, "nonce" => "0123456789abcdef"} = Jason.decode!(reply)
    :gen_tcp.close(socket)
    assert %{"kind" => "event", "seq" => 2} = line()
    assert %{"kind" => "checkpoint", "seq" => 3, "nonce" => "0123456789abcdef"} = line()

    assert {:ok, bad} =
             :gen_tcp.connect(
               {:local, String.to_charlist(path)},
               0,
               [:binary, active: false, packet: :line],
               2_000
             )

    :ok = :gen_tcp.send(bad, ~s({"op":"checkpoint","nonce":"bad"}\n))
    assert {:error, :closed} = :gen_tcp.recv(bad, 0, 2_000)
    :gen_tcp.close(bad)
    GenServer.stop(pid)
    other = path <> ".refused"
    denied = start_observer(socket_path: other, admit: fn _socket, _os -> {:error, :denied} end)
    line()

    assert {:ok, refused} =
             :gen_tcp.connect(
               {:local, String.to_charlist(other)},
               0,
               [:binary, active: false, packet: :line],
               2_000
             )

    :ok = :gen_tcp.send(refused, ~s({"op":"checkpoint","nonce":"0123456789abcdef"}\n))
    assert {:error, :closed} = :gen_tcp.recv(refused, 0, 2_000)
    :gen_tcp.close(refused)
    GenServer.stop(denied)
  end

  test "a stream write failure terminates the observer" do
    Process.flag(:trap_exit, true)
    parent = self()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    writer = fn line ->
      case Agent.get_and_update(counter, fn n -> {n, n + 1} end) do
        0 ->
          send(parent, {:line, line})
          :ok

        _ ->
          {:error, :closed}
      end
    end

    pid = start_observer(write: writer)
    line()
    FermixCore.Tools.Telemetry.exec("browser", %{agent_name: "main"}, true, 1)
    assert_receive {:failed, :write_failed}, 2_000
    assert_receive {:EXIT, ^pid, _}, 2_000
  end

  test "write failure and token exposure fail closed" do
    Process.flag(:trap_exit, true)
    parent = self()
    writer = fn _ -> {:error, :closed} end

    assert {:error, _} =
             FermixAudit.Observer.start_link(
               run_id: "run-2",
               token: "private-token-123",
               prefix: "bad-writer",
               write: writer,
               fail: fn reason -> send(parent, {:failed, reason}) end
             )

    assert_receive {:failed, :write_failed}, 2_000
    pid = start_observer()
    line()

    FermixCore.Tools.Telemetry.exec("browser", %{agent_name: "main"}, true, 1,
      metadata: %{detail: "private-token-123"}
    )

    assert %{"kind" => "error", "reason" => "token_exposure"} = line()
    assert_receive {:failed, :token_exposure}, 2_000
    assert_receive {:EXIT, ^pid, _}, 2_000
  end
end
