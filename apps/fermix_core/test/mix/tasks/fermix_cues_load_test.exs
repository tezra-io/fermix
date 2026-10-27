defmodule Mix.Tasks.Fermix.Cues.LoadTest.Door do
  @moduledoc false
  # A door on loopback that answers like the cue door and tells the test what it got.
  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(test_pid), do: test_pid

  @impl Plug
  def call(conn, test_pid) do
    {:ok, body, conn} = read_body(conn)
    send(test_pid, {:door, conn.request_path, get_req_header(conn, "authorization"), body})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, ~s({"results":[{"index":0,"id":"x","status":"accepted"}]}))
  end
end

defmodule Mix.Tasks.Fermix.Cues.LoadTest do
  # async: false — FERMIX_HOME, the Mix shell and the stub writer are global.
  use ExUnit.Case, async: false

  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.SecretWriterStub
  alias Mix.Tasks.Fermix.Cues.Load

  @port 4590
  @from ~U[2026-10-17 12:00:00Z]
  @to ~U[2026-10-17 12:00:30Z]

  setup do
    home = System.get_env("FERMIX_HOME")
    writer = Application.get_env(:fermix_core, :secret_writer)
    shell = Mix.shell()

    tmp = SafeRm.make_tmp_dir!("cues_load_task_home")
    System.put_env("FERMIX_HOME", tmp)
    Application.put_env(:fermix_core, :secret_writer, SecretWriterStub)
    SecretWriterStub.reset()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      case home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      Application.put_env(:fermix_core, :secret_writer, writer)
      SecretWriterStub.reset()
      Mix.shell(shell)
      SafeRm.rm_rf!(tmp)
    end)

    write_config(tmp, ["push-a", "push-b"])

    for ref <- ["push-a", "push-b"] do
      :ok = SecretWriterStub.put({:cue_source, ref, :token}, "tok-" <> ref, store: :file)
    end

    {:ok, home: tmp, traces: SafeRm.make_tmp_dir!("cues_load_task_traces")}
  end

  defp write_config(home, refs, extra \\ "") do
    sources =
      Enum.map_join(refs, "\n", fn ref ->
        """
        [fermix_core.cues.sources.#{ref}]
        kind = "local_push"
        token = "@file"
        """
      end)

    File.write!(Path.join(home, "config.toml"), """
    [fermix_core.cues]
    door_port = #{@port}

    #{sources}

    [fermix_core.cues.sources.push-off]
    kind = "local_push"
    enabled = false
    token = "@file"

    [fermix_core.cues.sources.gh-hooks]
    preset = "github"
    secret = "@file"
    #{extra}
    """)
  end

  # A clock per process: each source's sender keeps its own time, so the
  # schedule each one follows is exact and nothing waits on a real clock.
  defp clock_opts(extra) do
    Keyword.merge(
      [
        monotonic_ms: fn -> Process.get(:fake_ms, 0) end,
        sleep: fn ms -> Process.put(:fake_ms, Process.get(:fake_ms, 0) + ms) end,
        wall_clock: fn -> @from end,
        probe: fn @port -> :ok end,
        run_id: "r1"
      ],
      extra
    )
  end

  defp accepting_post(test_pid, latency_ms \\ 4) do
    fn url, headers, body ->
      Process.put(:fake_ms, Process.get(:fake_ms, 0) + latency_ms)
      send(test_pid, {:posted, url, headers, Jason.decode!(body)})
      {:ok, 200, ~s({"results":[{"index":0,"id":"x","status":"accepted"}]})}
    end
  end

  defp posted do
    receive do
      {:posted, _url, _headers, _event} = post -> [post | posted()]
    after
      0 -> []
    end
  end

  defp output do
    Stream.repeatedly(fn ->
      receive do
        {:mix_shell, _kind, [line]} -> line
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(&(&1 != nil))
    |> Enum.join("\n")
  end

  describe "pushing" do
    test "sends rate × seconds CloudEvents to each source's door path with its token", ctx do
      opts = clock_opts(post: accepting_post(self()), trace_dir: ctx.traces)

      assert :ok = Load.execute(["--rate", "3", "--seconds", "2"], opts)

      posts = posted()
      assert length(posts) == 12

      for ref <- ["push-a", "push-b"] do
        mine = Enum.filter(posts, fn {:posted, url, _h, _e} -> String.ends_with?(url, ref) end)
        assert length(mine) == 6

        for {:posted, url, headers, event} <- mine do
          assert url == "http://127.0.0.1:#{@port}/cues/v1/#{ref}"
          assert {"authorization", "Bearer tok-" <> ref} in headers
          assert {"content-type", "application/cloudevents+json"} in headers
          assert %{"specversion" => "1.0", "source" => "fermix.cues.load"} = event
        end
      end

      ids = Enum.map(posts, fn {:posted, _url, _h, event} -> event["id"] end)
      assert length(Enum.uniq(ids)) == 12

      text = output()
      assert text =~ ~r/push-a\s+6\s+6\s+0\s+0\s+4\s+4\s+4\s+4/
      assert text =~ ~r/all\s+12\s+12\s+0\s+0/
      assert text =~ "Refused: none."
      assert text =~ "0 ms behind its schedule"
      assert text =~ "Not measured: the latency of job and reminder claims"
    end

    test "--sources narrows to the named sources", ctx do
      opts = clock_opts(post: accepting_post(self()), trace_dir: ctx.traces)

      assert :ok = Load.execute(["--sources", "push-b", "--rate", "1", "--seconds", "2"], opts)

      assert_received {:posted, "http://127.0.0.1:4590/cues/v1/push-b", _h,
                       %{"data" => %{"n" => 0}}}

      assert_received {:posted, "http://127.0.0.1:4590/cues/v1/push-b", _h,
                       %{"data" => %{"n" => 1}}}

      refute_received {:posted, _, _, _}
    end

    test "counts each refusal by the door's own status and exits non-zero", ctx do
      answers = [
        {:ok, 429, ~s({"results":[{"index":0,"id":"x","status":"rate_limited"}]})},
        {:ok, 503, ~s({"error":"The door is busy; try again shortly."})},
        {:error, %{reason: :econnreset}},
        {:ok, 200, ~s({"results":[{"index":0,"id":"x","status":"accepted"}]})}
      ]

      post = fn _url, _headers, _body ->
        n = Process.get(:n, 0)
        Process.put(:n, n + 1)
        Enum.at(answers, n)
      end

      opts = clock_opts(post: post, trace_dir: ctx.traces)

      assert_raise Mix.Error, "3 of 4 items were not accepted; see above.", fn ->
        Load.execute(["--sources", "push-a", "--rate", "2", "--seconds", "2"], opts)
      end

      text = output()
      assert text =~ "Refused: http 503 1, rate_limited 1, transport :econnreset 1"
      assert text =~ ~r/push-a\s+4\s+1\s+3\s+0/
    end

    test "a door that falls behind stops the sending 30 s after the planned end", ctx do
      opts = clock_opts(post: accepting_post(self(), 20_000), trace_dir: ctx.traces)

      assert_raise Mix.Error, "8 of 10 items were not accepted; see above.", fn ->
        Load.execute(["--sources", "push-a", "--rate", "10", "--seconds", "1"], opts)
      end

      assert_received {:posted, _url, _h, %{"data" => %{"n" => 0}}}
      assert_received {:posted, _url, _h, %{"data" => %{"n" => 1}}}
      refute_received {:posted, _, _, _}

      text = output()
      assert text =~ ~r/push-a\s+2\s+2\s+0\s+8\s+20000/
      assert text =~ "19900 ms behind its schedule"
    end

    test "refuses before sending anything when nothing answers on the door's port", ctx do
      opts =
        clock_opts(
          post: accepting_post(self()),
          trace_dir: ctx.traces,
          probe: fn @port -> {:error, :econnrefused} end
        )

      assert_raise Mix.Error,
                   ~r/Nothing answers on 127\.0\.0\.1:4590.*start the development/,
                   fn ->
                     Load.execute([], opts)
                   end

      refute_received {:posted, _, _, _}
    end
  end

  # The real client path: the probe and the POST go through the egress policy to
  # a listener on 127.0.0.1, so what the tests above inject is what really runs.
  test "posts through the engine's own HTTP client to a door on loopback", ctx do
    {:ok, _apps} = Application.ensure_all_started(:req)

    door =
      start_supervised!(
        {Bandit, plug: {__MODULE__.Door, self()}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(door)
    write_config(ctx.home, ["push-a"], "")
    File.write!(Path.join(ctx.home, "config.toml"), real_port(ctx.home, port))

    opts =
      clock_opts(trace_dir: ctx.traces)
      |> Keyword.delete(:probe)

    assert :ok = Load.execute(["--rate", "2", "--seconds", "1"], opts)

    for n <- 0..1 do
      assert_received {:door, "/cues/v1/push-a", ["Bearer tok-push-a"], body}
      assert %{"id" => "load-r1-push-a-" <> index} = Jason.decode!(body)
      assert index in ["0", "1"], "unexpected event #{n}: #{body}"
    end

    assert output() =~ ~r/all\s+2\s+2\s+0\s+0/
  end

  defp real_port(home, port) do
    home
    |> Path.join("config.toml")
    |> File.read!()
    |> String.replace("door_port = #{@port}", "door_port = #{port}")
  end

  describe "the plan" do
    test "takes every enabled local_push source, never a disabled or webhook one" do
      plan = Load.plan!([], run_id: "r1")

      assert Enum.map(plan.sources, & &1.ref) == ["push-a", "push-b"]
      assert Enum.map(plan.sources, & &1.token) == ["tok-push-a", "tok-push-b"]
      assert %{port: @port, rate: 10, seconds: 30} = plan
    end

    test "refuses a source that is not an enabled local_push source" do
      for ref <- ["push-off", "gh-hooks", "nope"] do
        assert_raise Mix.Error, ~r/#{ref}.*is not an enabled local_push source/, fn ->
          Load.plan!(["--sources", ref])
        end
      end
    end

    test "refuses more than five sources", ctx do
      refs = for n <- 1..6, do: "push-#{n}"
      write_config(ctx.home, refs)
      for ref <- refs, do: SecretWriterStub.put({:cue_source, ref, :token}, "t", store: :file)

      assert_raise Mix.Error, ~r/At most 5 sources/, fn -> Load.plan!([]) end
    end

    test "refuses a home with no enabled local_push source", ctx do
      write_config(ctx.home, [])

      assert_raise Mix.Error, ~r/There is no enabled local_push source/, fn -> Load.plan!([]) end
    end

    test "refuses rates and durations out of bounds, and stray arguments" do
      for args <- [["--rate", "0"], ["--rate", "11"], ["--seconds", "0"], ["--seconds", "601"]] do
        assert_raise Mix.Error, ~r/must be from/, fn -> Load.plan!(args) end
      end

      assert_raise Mix.Error, ~r/usage:/, fn -> Load.plan!(["push-a"]) end
      assert_raise Mix.Error, ~r/usage:/, fn -> Load.plan!(["--speed", "3"]) end
    end

    test "refuses a source whose token cannot be read" do
      SecretWriterStub.reset()

      assert_raise Mix.Error, ~r/token of push-a could not be read.*mix fermix.cues.secret/, fn ->
        Load.plan!([])
      end
    end
  end

  describe "the daemon's traces" do
    defp trace_plan, do: %{sources: [%{ref: "push-a"}, %{ref: "push-b"}]}

    defp write_trace(dir, date, rows) do
      day = Path.join(dir, date)
      File.mkdir_p!(day)
      File.write!(Path.join(day, "agent_event.jsonl"), Enum.join(rows, "\n") <> "\n")
    end

    defp lifecycle(ts, ref, accept_ms) do
      Jason.encode!(%{
        "ts" => ts,
        "type" => "agent_event",
        "agent" => "cues",
        "event" => "cue_lifecycle",
        "phase" => "accepted",
        "source_ref" => ref,
        "accept_ms" => accept_ms
      })
    end

    defp timeout(ts, name) do
      Jason.encode!(%{"ts" => ts, "event" => "timeout", "agent" => name, "ms" => 5000})
    end

    test "reads the accept times of these sources and every Repo timeout in the window", ctx do
      write_trace(ctx.traces, "2026-10-17", [
        lifecycle("2026-10-17T12:00:01Z", "push-a", 7),
        lifecycle("2026-10-17T12:00:02Z", "push-b", 3),
        lifecycle("2026-10-17T12:00:03Z", "push-a", 5),
        lifecycle("2026-10-17T12:00:03Z", "other-source", 900),
        lifecycle("2026-10-17T11:59:00Z", "push-a", 800),
        lifecycle("2026-10-17T12:00:40Z", "push-a", 700),
        timeout("2026-10-17T12:00:05Z", "repo_call"),
        timeout("2026-10-17T12:00:06Z", "provider_call"),
        timeout("2026-10-17T13:00:00Z", "repo_call"),
        "not json"
      ])

      traced = Load.traced(trace_plan(), %{from: @from, to: @to}, trace_dir: ctx.traces)

      assert Enum.sort(traced.accept_ms) == [3, 5, 7]
      assert traced.repo_timeouts == 1
      assert traced.unreadable == 1
      assert traced.files == 1
    end

    test "reads both days of a window that crosses midnight", ctx do
      write_trace(ctx.traces, "2026-10-17", [lifecycle("2026-10-17T23:59:59Z", "push-a", 2)])
      write_trace(ctx.traces, "2026-10-18", [lifecycle("2026-10-18T00:00:01Z", "push-a", 4)])

      window = %{from: ~U[2026-10-17 23:59:50Z], to: ~U[2026-10-18 00:00:10Z]}
      traced = Load.traced(trace_plan(), window, trace_dir: ctx.traces)

      assert Enum.sort(traced.accept_ms) == [2, 4]
      assert traced.files == 2
    end

    test "says when no trace file covers the window", ctx do
      opts = clock_opts(post: accepting_post(self()), trace_dir: ctx.traces)

      assert :ok = Load.execute(["--sources", "push-a", "--rate", "1", "--seconds", "1"], opts)
      assert output() =~ "Daemon side: no trace file for this window"
    end
  end

  test "percentiles are nearest-rank over what was measured" do
    assert Load.percentiles([]) == ["-", "-", "-", "-"]
    assert Load.percentiles(Enum.to_list(1..100)) == [50, 90, 99, 100]
    assert Load.percentiles([9, 1, 5]) == [5, 9, 9, 9]
  end
end
