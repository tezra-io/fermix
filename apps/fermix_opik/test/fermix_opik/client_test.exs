defmodule FermixOpik.ClientTest do
  use ExUnit.Case, async: false

  alias FermixOpik.Client

  defmodule StubReq do
    @moduledoc false
    # Client.send_trace runs synchronously in the caller, so this executes in the
    # test process — `self()` is the test pid.
    def post(url, opts) do
      send(self(), {:post, url, opts[:json], opts[:headers]})
      Process.get(:stub_response, {:ok, %{status: 204, body: ""}})
    end
  end

  defmodule TransportReq do
    @moduledoc false
    # Exercise Req's actual retry pipeline; only the transport and sleep are fake.
    def post(url, opts) do
      Req.post(url, Keyword.merge(opts, adapter: &respond/1, retry_delay: fn _ -> 0 end))
    end

    defp respond(request) do
      send(self(), {:request, request.url.path, IO.iodata_to_binary(request.body)})
      [response | rest] = Process.get(:transport_responses)
      Process.put(:transport_responses, rest)

      case response do
        status when is_integer(status) -> {request, Req.Response.new(status: status, body: "")}
        exception -> {request, exception}
      end
    end
  end

  @config %{base_url: "http://localhost:5173/api", api_key: nil, workspace: nil}

  @closed %{
    trace: %{id: "t1", project_name: "fermix", name: "agent:main"},
    spans: [%{id: "s1", trace_id: "t1", type: "llm"}]
  }

  test "posts trace then spans to the batch endpoints" do
    assert :ok = Client.send_trace(@config, @closed, req_module: StubReq)

    assert_receive {:post, "http://localhost:5173/api/v1/private/traces/batch", %{traces: [_]}, _}
    assert_receive {:post, "http://localhost:5173/api/v1/private/spans/batch", %{spans: [_]}, _}
  end

  test "skips the spans call when there are no spans" do
    assert :ok = Client.send_trace(@config, %{trace: %{id: "t1"}, spans: []}, req_module: StubReq)

    assert_receive {:post, _traces_url, %{traces: [_]}, _}
    refute_receive {:post, _spans_url, %{spans: _}, _}
  end

  test "sends cloud auth headers when configured" do
    config = %{base_url: "https://x/api", api_key: "secret", workspace: "ws"}
    Client.send_trace(config, @closed, req_module: StubReq)

    assert_receive {:post, _url, _body, headers}
    assert {"authorization", "secret"} in headers
    assert {"comet-workspace", "ws"} in headers
  end

  test "surfaces a non-2xx response as an error and stops" do
    Process.put(:stub_response, {:ok, %{status: 422, body: %{"error" => "bad"}}})

    assert {:error, {:http, 422}} = Client.send_trace(@config, @closed, req_module: StubReq)
    # the trace POST failed, so spans are never attempted
    assert_receive {:post, _traces_url, %{traces: [_]}, _}
    refute_receive {:post, _spans_url, %{spans: _}, _}
  end

  @tag capture_log: true
  test "retries a transient trace upload with the same payload before sending spans" do
    for status <- [408, 429, 500, 502, 503, 504] do
      Process.put(:transport_responses, [status, 204, 204])

      assert :ok = Client.send_trace(@config, @closed, req_module: TransportReq)
      assert_receive {:request, "/api/v1/private/traces/batch", body}
      assert_receive {:request, "/api/v1/private/traces/batch", ^body}
      assert Jason.decode!(body) == %{"traces" => [Jason.decode!(Jason.encode!(@closed.trace))]}
      assert_receive {:request, "/api/v1/private/spans/batch", _body}
      assert Process.get(:transport_responses) == []
    end
  end

  @tag capture_log: true
  test "retries only the spans when the trace upload already succeeded" do
    Process.put(:transport_responses, [204, 500, 204])

    assert :ok = Client.send_trace(@config, @closed, req_module: TransportReq)
    assert_receive {:request, "/api/v1/private/traces/batch", _body}
    assert_receive {:request, "/api/v1/private/spans/batch", body}
    assert_receive {:request, "/api/v1/private/spans/batch", ^body}
    refute_receive {:request, _, _}
  end

  @tag capture_log: true
  test "retries a transport timeout with the same trace id" do
    Process.put(:transport_responses, [%Req.TransportError{reason: :timeout}, 204, 204])

    assert :ok = Client.send_trace(@config, @closed, req_module: TransportReq)
    assert_receive {:request, "/api/v1/private/traces/batch", body}
    assert_receive {:request, "/api/v1/private/traces/batch", ^body}
    assert_receive {:request, "/api/v1/private/spans/batch", _body}
  end

  @tag capture_log: true
  test "persistent trace upload failure stops after three attempts without sending spans" do
    Process.put(:transport_responses, [500, 500, 500, 204])

    assert {:error, {:http, 500}} = Client.send_trace(@config, @closed, req_module: TransportReq)
    for _ <- 1..3, do: assert_receive({:request, "/api/v1/private/traces/batch", _body})
    assert Process.get(:transport_responses) == [204]
    refute_receive {:request, _, _}
  end

  @tag capture_log: true
  test "persistent span upload failure returns an error after three attempts" do
    Process.put(:transport_responses, [204, 503, 503, 503, 204])

    assert {:error, {:http, 503}} = Client.send_trace(@config, @closed, req_module: TransportReq)
    assert_receive {:request, "/api/v1/private/traces/batch", _body}
    for _ <- 1..3, do: assert_receive({:request, "/api/v1/private/spans/batch", _body})
    assert Process.get(:transport_responses) == [204]
    refute_receive {:request, _, _}
  end

  @tag capture_log: true
  test "permanent rejection is attempted once and never sends spans" do
    for status <- [400, 401, 403, 404, 422] do
      Process.put(:transport_responses, [status, 204])

      assert {:error, {:http, ^status}} =
               Client.send_trace(@config, @closed, req_module: TransportReq)

      assert_receive {:request, "/api/v1/private/traces/batch", _body}
      assert Process.get(:transport_responses) == [204]
      refute_receive {:request, _, _}
    end
  end
end
