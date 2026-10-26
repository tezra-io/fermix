defmodule FermixCore.Cues.DoorTest do
  # async: false — Buckets owns named tables, and the sources are app env.
  use ExUnit.Case, async: false

  import Plug.Conn, only: [put_req_header: 3, get_resp_header: 2]
  import Plug.Test

  alias FermixCore.Cues.Buckets
  alias FermixCore.Cues.Config
  alias FermixCore.Cues.Door
  alias FermixCore.Cues.Door.Router
  alias FermixCore.Cues.Ingest
  alias FermixCore.Cues.Item
  alias FermixCore.Cues.Supervisor, as: CuesSupervisor
  alias FermixCore.Cues.Sweeper
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesSql
  alias FermixTestSupport.CueFixtures
  alias FermixTestSupport.SecretWriterStub

  @token "tok-home-alerts"
  @now ~U[2026-10-10 12:00:00Z]
  @structured "application/cloudevents+json"
  @batch "application/cloudevents-batch+json"
  @wait_ms 10_000
  @no_timer &__MODULE__.no_timer/2

  setup do
    cues = Application.get_env(:fermix_core, :cues)
    writer = Application.get_env(:fermix_core, :secret_writer)
    profile = Application.get_env(:fermix_core, :profile)

    Application.put_env(:fermix_core, :secret_writer, SecretWriterStub)
    Application.delete_env(:fermix_core, :profile)
    SecretWriterStub.reset()

    Application.put_env(
      :fermix_core,
      :cues,
      Config.normalize(%{
        "sources" => %{
          "home-alerts" => %{"kind" => "local_push", "token" => "@keyring", "daily_budget" => 40},
          "off-alerts" => %{"kind" => "local_push", "token" => "@keyring", "enabled" => false},
          "eng-blogs" => %{"preset" => "rss", "url" => "https://example.org/feed.xml"}
        }
      })
    )

    :ok = SecretWriterStub.put({:cue_source, "home-alerts", :token}, @token, store: :keyring)
    :ok = SecretWriterStub.put({:cue_source, "off-alerts", :token}, @token, store: :keyring)

    on_exit(fn ->
      restore(:cues, cues)
      restore(:secret_writer, writer)
      restore(:profile, profile)
      SecretWriterStub.reset()
    end)

    start_supervised!(Buckets)
    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore(key, value), do: Application.put_env(:fermix_core, key, value)

  # An ingest stand-in: tells the test what it was given and accepts every item.
  defp router_opts(overrides \\ []) do
    test = self()

    ingest = fn source, entries, opts ->
      send(test, {:ingest, source, entries, opts})

      {:ok,
       Enum.map(entries, fn
         %Item{} -> :accepted
         {:error, reason} when reason == :stale -> :stale
         {:error, {:invalid, _message} = invalid} -> invalid
       end)}
    end

    Keyword.merge(
      [ingest: ingest, clock: fn -> 0 end, now: fn -> @now end],
      overrides
    )
  end

  defp event(overrides \\ %{}) do
    Map.merge(
      %{
        "specversion" => "1.0",
        "id" => "evt-1",
        "source" => "urn:example:host-alpha",
        "type" => "com.example.disk.alert",
        "time" => "2026-10-10T11:59:00Z",
        "data" => %{"disk" => "/dev/sda", "free_pct" => 3}
      },
      overrides
    )
  end

  defp push(body, opts \\ []) do
    path = Keyword.get(opts, :path, "/cues/v1/home-alerts")

    headers =
      Keyword.get(opts, :headers, [
        {"content-type", @structured},
        {"content-length", Integer.to_string(byte_size(body))},
        {"authorization", "Bearer " <> @token}
      ])

    conn =
      Enum.reduce(headers, conn(Keyword.get(opts, :method, :post), path, body), fn {key, value},
                                                                                   acc ->
        put_req_header(acc, key, value)
      end)

    Router.call(conn, Router.init(Keyword.get(opts, :router_opts, router_opts())))
  end

  defp headers(overrides) do
    base = %{
      "content-type" => @structured,
      "authorization" => "Bearer " <> @token
    }

    Enum.reject(Map.merge(base, Map.new(overrides)), fn {_key, value} -> is_nil(value) end)
  end

  defp with_length(headers, body),
    do: [{"content-length", Integer.to_string(byte_size(body))} | headers]

  defp json(conn), do: Jason.decode!(conn.resp_body)

  describe "local push" do
    test "an event is accepted and handed to ingest with the source's budget" do
      conn = push(Jason.encode!(event()))

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]

      assert json(conn) == %{
               "results" => [%{"index" => 0, "id" => "evt-1", "status" => "accepted"}]
             }

      assert_received {:ingest, %{ref: "home-alerts", daily_budget: 40}, [item], opts}
      assert item.type == "com.example.disk.alert"
      assert item.item_id =~ ~r/^ce_/
      assert opts[:now] == @now
      assert is_function(opts[:admit], 1)
    end

    test "the admit function spends the source's bucket" do
      _conn = push(Jason.encode!(event()))
      assert_received {:ingest, _source, _entries, opts}

      assert opts[:admit].(30) == 30
      assert Buckets.tokens("home-alerts", 0) == 70
    end

    test "a batch is answered per event, in order" do
      body = Jason.encode!([event(%{"id" => "a"}), event(%{"id" => "b", "specversion" => "9"})])
      conn = push(body, headers: with_length(headers(%{"content-type" => @batch}), body))

      assert conn.status == 200
      assert [%{"id" => "a", "status" => "accepted"}, second] = json(conn)["results"]
      assert %{"index" => 1, "id" => "b", "status" => "invalid", "reason" => reason} = second
      assert reason =~ "specversion"
    end

    test "C29: a bad token is 401, stores nothing and is counted" do
      body = Jason.encode!(event())
      conn = push(body, headers: with_length(headers(%{"authorization" => "Bearer nope"}), body))

      assert conn.status == 401
      refute_received {:ingest, _source, _entries, _opts}
      assert Buckets.take_rejects() == %{"home-alerts" => %{unauthorized: 1}}
    end

    # A token needs no body to check, so a client without the token never
    # takes one of the source's read slots (a departure from §6.7's order).
    test "a bad token is refused before its body takes a read slot" do
      tokens = for _n <- 1..4, do: elem(Buckets.acquire(:read, "home-alerts"), 1)
      on_exit(fn -> Enum.each(tokens, &Buckets.release/1) end)
      body = Jason.encode!(event())

      conn = push(body, headers: with_length(headers(%{"authorization" => "Bearer nope"}), body))
      assert conn.status == 401

      # The right token gets past the check and then waits on the read slots.
      assert push(body).status == 503
      refute_received {:ingest, _source, _entries, _opts}
    end

    test "a missing or malformed bearer is 401" do
      body = Jason.encode!(event())

      for auth <- [nil, "Basic dG9r", "Bearer ", @token] do
        conn = push(body, headers: with_length(headers(%{"authorization" => auth}), body))
        assert conn.status == 401
      end

      refute_received {:ingest, _source, _entries, _opts}
    end

    test "C29: a 70 KiB item is invalid on its own line and nothing is accepted" do
      body = Jason.encode!(event(%{"data" => String.duplicate("a", 70 * 1024)}))
      conn = push(body)

      assert conn.status == 200
      assert [%{"status" => "invalid", "reason" => reason}] = json(conn)["results"]
      assert reason =~ "64 KiB"
      assert_received {:ingest, _source, [{:error, {:invalid, _message}}], _opts}
    end

    test "C29: a repeated JSON key is 400 and stores nothing" do
      body = ~s({"specversion":"1.0","id":"a","id":"b","source":"s","type":"t"})
      conn = push(body)

      assert conn.status == 400
      assert json(conn)["error"] =~ "repeats a key"
      refute_received {:ingest, _source, _entries, _opts}
    end

    test "a body that is not JSON is 400" do
      assert push("{nope").status == 400
    end

    test "C29: a wrong content type is 415" do
      body = Jason.encode!(event())

      for type <- ["application/json", nil] do
        conn = push(body, headers: with_length(headers(%{"content-type" => type}), body))
        assert conn.status == 415
      end

      refute_received {:ingest, _source, _entries, _opts}
    end

    test "C29: over the rate limit is 429 with one coalesced count" do
      assert Buckets.admit("home-alerts", 100, 0) == 100

      conn = push(Jason.encode!(event()))

      assert conn.status == 429
      refute_received {:ingest, _source, _entries, _opts}
      assert Buckets.take_rejects() == %{"home-alerts" => %{rate_limited: 1}}
    end

    # Through the real `Cues.Ingest` (on a temp Repo): the door's `:admit`
    # spends the source's bucket, and what it does not admit is rate_limited.
    test "C29: past the bucket, real ingest answers rate_limited per event and spends it" do
      ctx = CueFixtures.start_repo("door_rate")

      ingest = fn source, entries, opts ->
        Ingest.accept(source, entries, Keyword.put(opts, :repo, ctx.repo))
      end

      assert Buckets.admit("home-alerts", 99, 0) == 99

      events = for id <- ~w(a b c), do: event(%{"id" => id})
      body = Jason.encode!(events)

      conn =
        push(body,
          headers: with_length(headers(%{"content-type" => @batch}), body),
          router_opts: router_opts(ingest: ingest)
        )

      assert conn.status == 200

      assert Enum.map(json(conn)["results"], & &1["status"]) ==
               ~w(accepted rate_limited rate_limited)

      assert Buckets.tokens("home-alerts", 0) == 0

      # Spent: the next request is refused at the door.
      assert push(Jason.encode!(event(%{"id" => "d"})), router_opts: router_opts(ingest: ingest)).status ==
               429
    end

    test "a request none of whose events got past the budget is 429 with its rows" do
      ingest = fn _source, entries, _opts ->
        {:ok, Enum.map(entries, fn _ -> :over_budget end)}
      end

      conn = push(Jason.encode!(event()), router_opts: router_opts(ingest: ingest))

      assert conn.status == 429
      assert [%{"status" => "over_budget"}] = json(conn)["results"]
    end

    test "C29: a Funnel-marked request is 401" do
      body = Jason.encode!(event())

      conn =
        push(body,
          headers: with_length(headers(%{"tailscale-funnel-request" => "?1"}), body)
        )

      assert conn.status == 401
      refute_received {:ingest, _source, _entries, _opts}
    end

    test "an unknown, disabled or non-local-push source is 401; only a configured one is counted" do
      body = Jason.encode!(event())

      for ref <- ["nope", "off-alerts", "eng-blogs"] do
        assert push(body, path: "/cues/v1/#{ref}").status == 401
      end

      refute_received {:ingest, _source, _entries, _opts}

      assert Buckets.take_rejects() == %{
               "off-alerts" => %{unauthorized: 1},
               "eng-blogs" => %{unauthorized: 1}
             }
    end

    # M60 app surface §3.8 item 3: a source added before its token is stored is
    # refused like an unknown one, before any token is read.
    test "a local-push source waiting for its token is 401 and reads no token" do
      Application.put_env(
        :fermix_core,
        :cues,
        Config.normalize(%{"sources" => %{"new-alerts" => %{"kind" => "local_push"}}})
      )

      test = self()
      load = fn ref, field -> send(test, {:loaded, ref, field}) && {:ok, @token} end
      body = Jason.encode!(event())

      conn =
        conn(:post, "/cues/v1/new-alerts", body)
        |> put_req_header("content-type", @structured)
        |> put_req_header("content-length", Integer.to_string(byte_size(body)))
        |> put_req_header("authorization", "Bearer " <> @token)
        |> Router.call(Router.init(router_opts(load_secret: load)))

      assert conn.status == 401
      refute_received {:loaded, _ref, _field}
      refute_received {:ingest, _source, _entries, _opts}
    end

    test "a body over 1,000,000 bytes is 413 before it is read" do
      conn =
        push("{}",
          headers: [{"content-length", "1000001"} | headers(%{})]
        )

      assert conn.status == 413
    end

    test "a body without one Content-Length, or with a Transfer-Encoding, is 411" do
      body = Jason.encode!(event())
      assert push(body, headers: headers(%{})).status == 411

      chunked = [{"transfer-encoding", "chunked"} | with_length(headers(%{}), body)]
      assert push(body, headers: chunked).status == 411
    end

    test "a body shorter than its Content-Length is 400" do
      body = Jason.encode!(event())
      claimed = [{"content-length", Integer.to_string(byte_size(body) + 10)} | headers(%{})]
      assert push(body, headers: claimed).status == 400
    end

    test "past the read limit for the source the answer is 503" do
      for _ <- 1..4, do: {:ok, _token} = Buckets.acquire(:read, "home-alerts")

      conn = push(Jason.encode!(event()))
      assert conn.status == 503
      refute_received {:ingest, _source, _entries, _opts}
    end

    test "a second authenticated request in flight for the source is 429" do
      {:ok, _token} = Buckets.acquire(:auth, "home-alerts")
      assert push(Jason.encode!(event())).status == 429
    end

    test "every slot is given back once the request is answered" do
      _conn = push(Jason.encode!(event()))

      assert Buckets.counts() == %{
               read: %{all: 0, by_source: %{}},
               auth: %{all: 0, by_source: %{}}
             }
    end

    test "a token that cannot be read is 503, read once a minute at most" do
      test = self()

      load = fn _ref, :token ->
        send(test, :loaded)
        {:error, :missing_secret}
      end

      opts = router_opts(load_secret: load)
      body = Jason.encode!(event())

      assert push(body, router_opts: opts).status == 503
      assert push(body, router_opts: opts).status == 503
      assert_received :loaded
      refute_received :loaded
    end

    test "an ingest failure is 503 with Retry-After, an unknown outcome" do
      ingest = fn _source, _entries, _opts -> {:error, :repo_timeout} end
      conn = push(Jason.encode!(event()), router_opts: router_opts(ingest: ingest))

      assert conn.status == 503
      assert get_resp_header(conn, "retry-after") == ["5"]
      assert json(conn)["error"] =~ "retry with the same ids"
    end
  end

  describe "other paths" do
    test "an unknown path, another method and a hook path are 404" do
      body = Jason.encode!(event())

      assert push(body, path: "/").status == 404
      assert push(body, path: "/setup").status == 404
      assert push(body, path: "/cues/v1").status == 404
      assert push(body, method: :get).status == 404
      assert push(body, path: "/cues/hooks/home-alerts/abc123").status == 404
      refute_received {:ingest, _source, _entries, _opts}
    end
  end

  describe "the listener" do
    test "serves local push on a loopback port" do
      door = start_supervised!({Door, port: 0, router_opts: router_opts(), schedule: @no_timer})
      assert {:listening, {{127, 0, 0, 1}, port}} = Door.status(door)

      body = Jason.encode!(event())
      {status, response} = raw_post(port, "/cues/v1/home-alerts", body)

      assert status == 200
      assert %{"results" => [%{"status" => "accepted"}]} = Jason.decode!(response)
      assert_receive {:ingest, %{ref: "home-alerts"}, [_item], _opts}, @wait_ms

      {not_found, _body} = raw_post(port, "/dashboard", body)
      assert not_found == 404
    end

    test "a port in use leaves the door unavailable, and its supervisor up" do
      {:ok, blocker} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, reuseaddr: false)
      on_exit(fn -> :gen_tcp.close(blocker) end)
      {:ok, port} = :inet.port(blocker)

      test = self()
      schedule = fn message, delay -> send(test, {:scheduled, message, delay}) end

      # The real tree, with its own Buckets, no configured sources (the test
      # home's config would otherwise start a feed worker that reaches out), and
      # a sweeper that never ticks.
      :ok = stop_supervised(Buckets)

      supervisor =
        start_supervised!(
          {CuesSupervisor,
           door: [port: port, schedule: schedule],
           sources: [sources: fn -> [] end],
           sweeper: [timer?: false]}
        )

      # `which_children/1` lists the newest first. One for one over four
      # children: the live group (the live dispatcher's task supervisor before
      # it, rest for one, up before any stream hands it watchers), the intake
      # group (Buckets, the sources, the door, rest for one: all read Buckets'
      # tables), the filtering group (the dispatcher before its task
      # supervisor, rest for one: a dispatcher crash ends its calls) and the
      # sweeper. A door or source crash never reaches a filter call.
      children = Supervisor.which_children(supervisor)
      assert Enum.map(children, &elem(&1, 0)) == [Sweeper, :filtering, :intake, :live]
      {:live, live, :supervisor, _modules} = List.keyfind(children, :live, 0)

      assert Enum.map(Supervisor.which_children(live), &elem(&1, 0)) == [
               FermixCore.Cues.LiveFilters,
               FermixCore.Cues.LiveFilterSupervisor
             ]

      {:intake, intake, :supervisor, _modules} = List.keyfind(children, :intake, 0)
      {:filtering, filtering, :supervisor, _modules} = List.keyfind(children, :filtering, 0)
      intake_children = Supervisor.which_children(intake)

      assert Enum.map(intake_children, &elem(&1, 0)) == [
               Door,
               FermixCore.Cues.SourceManager,
               FermixCore.Cues.SourceSupervisor,
               Buckets
             ]

      assert Enum.map(Supervisor.which_children(filtering), &elem(&1, 0)) == [
               FermixCore.Cues.FilterSupervisor,
               FermixCore.Cues.Filters
             ]

      {Door, door, :worker, _modules} = List.keyfind(intake_children, Door, 0)

      assert Door.status(door) == {:unavailable, :address_in_use}
      assert Process.alive?(supervisor)
      assert_received {:scheduled, {:retry_listen, _token}, 1_000}

      # The retry finds the port still taken and backs off, still up.
      send(door, {:retry_listen, retry_token(door)})
      assert Door.status(door) == {:unavailable, :address_in_use}
      assert_received {:scheduled, {:retry_listen, _token}, 2_000}
    end

    test "a refused request's count is written by the door, one update per source" do
      test = self()
      writer = fn ref, counts, now -> send(test, {:rejects, ref, counts, now}) && :ok end

      door =
        start_supervised!(
          {Door,
           port: 0,
           router_opts: router_opts(),
           reject_writer: writer,
           now: fn -> @now end,
           schedule: @no_timer}
        )

      :ok = Buckets.record_reject("home-alerts", :unauthorized)
      :ok = Buckets.record_reject("home-alerts", :unauthorized)
      :ok = Buckets.record_reject("home-alerts", :rate_limited)

      assert :ok = Door.flush_rejects(door)
      assert_received {:rejects, "home-alerts", %{"unauthorized" => 2, "rate_limited" => 1}, @now}
      refute_received {:rejects, _ref, _counts, _now}
    end
  end

  describe "reject counts in memory.db" do
    test "the door's own writer adds them to the source's row in one update" do
      ctx = CueFixtures.start_repo("door_rejects")

      door =
        start_supervised!(
          {Door, port: 0, router_opts: router_opts(), repo: ctx.repo, schedule: @no_timer}
        )

      :ok = Buckets.record_reject("home-alerts", :unauthorized)
      :ok = Buckets.record_reject("home-alerts", :unauthorized)
      :ok = Buckets.record_reject("home-alerts", :rate_limited)
      assert :ok = Door.flush_rejects(door)

      assert {:ok, row} =
               Repo.cues_call(
                 CuesSql,
                 {:get_source, "home-alerts"},
                 server: ctx.repo
               )

      assert row.reject_counts == %{"unauthorized" => 2, "rate_limited" => 1}
    end
  end

  @doc false
  def no_timer(_message, _delay_ms), do: :ok

  defp retry_token(door), do: :sys.get_state(door).retry.token

  # One HTTP/1.1 request on a raw socket, read to the close.
  defp raw_post(port, path, body) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], @wait_ms)

    request = [
      "POST #{path} HTTP/1.1\r\n",
      "host: 127.0.0.1\r\n",
      "content-type: #{@structured}\r\n",
      "content-length: #{byte_size(body)}\r\n",
      "authorization: Bearer #{@token}\r\n",
      "connection: close\r\n\r\n",
      body
    ]

    :ok = :gen_tcp.send(socket, request)
    response = read_all(socket, [])
    :ok = :gen_tcp.close(socket)

    [head, response_body] = String.split(response, "\r\n\r\n", parts: 2)
    ["HTTP/1.1", status | _reason] = head |> String.split("\r\n") |> hd() |> String.split(" ")
    {String.to_integer(status), response_body}
  end

  defp read_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, @wait_ms) do
      {:ok, data} -> read_all(socket, [acc, data])
      {:error, :closed} -> IO.iodata_to_binary(acc)
    end
  end
end
