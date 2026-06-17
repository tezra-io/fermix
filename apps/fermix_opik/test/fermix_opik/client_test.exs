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
end
