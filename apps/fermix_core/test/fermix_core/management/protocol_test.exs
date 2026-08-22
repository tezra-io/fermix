defmodule FermixCore.Management.ProtocolTest do
  use ExUnit.Case, async: true

  alias FermixCore.Management.Protocol

  @valid_request %{
    "request_id" => "req-123",
    "protocol_version" => 1,
    "method" => "hello",
    "params" => %{}
  }

  test "publishes the initial N/N-1 compatibility window" do
    assert Protocol.protocol_version() == 1
    assert Protocol.supported_version_range() == {1, 1}
    assert Protocol.negotiate(1) == :ok
    assert Protocol.negotiate(0) == {:error, :client_too_old}
    assert Protocol.negotiate(2) == {:error, :daemon_too_old}
  end

  test "publishes the management-operations method and error catalogs" do
    assert Protocol.methods() == [
             "hello",
             "overview.get",
             "setup.session.create",
             "doctor.start",
             "doctor.get",
             "doctor.cancel",
             "logs.query",
             "lifecycle.prepare",
             "lifecycle.commit",
             "lifecycle.cancel",
             "diagnostics.build"
           ]

    assert Protocol.error_codes() == [
             "invalid_request",
             "invalid_params",
             "method_not_found",
             "client_too_old",
             "daemon_too_old",
             "internal_error",
             "unavailable",
             "busy",
             "lease_expired",
             "unknown_lease",
             "unknown_session",
             "cursor_expired"
           ]
  end

  test "every management operation error code renders a bounded public envelope" do
    for code <- ~w(busy lease_expired unknown_lease unknown_session cursor_expired) do
      atom = String.to_existing_atom(code)

      assert {:ok, %{"error" => error}} =
               Protocol.respond("req-1", {:error, atom, %{"operation" => "doctor"}})

      assert error["code"] == code
      assert is_binary(error["message"]) and error["message"] != ""
      refute error["message"] =~ "%{"
    end
  end

  test "decodes and normalizes a valid v1 request" do
    assert {:ok,
            {:v1,
             %{
               request_id: "req-123",
               protocol_version: 1,
               method: "hello",
               params: %{}
             }}} = Protocol.decode_request(Jason.encode!(@valid_request))
  end

  test "defaults omitted params to an empty object" do
    frame = @valid_request |> Map.delete("params") |> Jason.encode!()

    assert {:ok, {:v1, %{params: %{}}}} = Protocol.decode_request(frame)
  end

  test "keeps requests without a v1 marker on the v0 path" do
    frame = Jason.encode!(%{"method" => "status", "params" => %{"verbose" => true}})

    assert {:ok, {:v0, %{"method" => "status", "params" => %{"verbose" => true}}}} =
             Protocol.decode_request(frame)
  end

  test "does not fall back to v0 when either v1 marker is present" do
    for request <- [
          %{"request_id" => "req-123", "method" => "status"},
          %{"protocol_version" => 1, "method" => "status"}
        ] do
      assert {:error, {:v1, response}} = Protocol.decode_request(Jason.encode!(request))
      assert response["error"]["code"] == "invalid_request"
      refute Map.has_key?(response, "result")
    end
  end

  test "leaves undecodable and non-object JSON on the v0 invalid-request path" do
    assert {:error, :invalid_v0_request} = Protocol.decode_request("not-json")
    assert {:error, :invalid_v0_request} = Protocol.decode_request("[]")
  end

  test "rejects missing, empty, malformed, and oversized request IDs" do
    invalid_ids = [nil, "", "has spaces", "slash/value", String.duplicate("a", 129)]

    for request_id <- invalid_ids do
      request = put_or_delete(@valid_request, "request_id", request_id)

      assert {:error, {:v1, response}} = Protocol.decode_request(Jason.encode!(request))
      assert response["request_id"] == nil
      assert response["error"]["code"] == "invalid_request"
      assert response["error"]["details"] == %{"field" => "request_id"}
    end
  end

  test "rejects missing, malformed, old, and new protocol versions" do
    cases = [
      {nil, "invalid_request"},
      {"1", "invalid_request"},
      {0, "client_too_old"},
      {2, "daemon_too_old"}
    ]

    for {version, code} <- cases do
      request = put_or_delete(@valid_request, "protocol_version", version)

      assert {:error, {:v1, response}} = Protocol.decode_request(Jason.encode!(request))
      assert response["request_id"] == "req-123"
      assert response["error"]["code"] == code

      if code in ["client_too_old", "daemon_too_old"] do
        assert response["error"]["details"] == %{
                 "minimum_version" => 1,
                 "maximum_version" => 1
               }
      end
    end
  end

  test "rejects missing, empty, malformed, and oversized methods" do
    invalid_methods = [nil, "", "Hello", ".hello", "hello..again", String.duplicate("a", 129)]

    for method <- invalid_methods do
      request = put_or_delete(@valid_request, "method", method)

      assert {:error, {:v1, response}} = Protocol.decode_request(Jason.encode!(request))
      assert response["request_id"] == "req-123"
      assert response["error"]["code"] == "invalid_request"
      assert response["error"]["details"] == %{"field" => "method"}
    end
  end

  test "rejects non-object and oversized params" do
    for params <- [[], "invalid", 1, nil] do
      request = Map.put(@valid_request, "params", params)

      assert {:error, {:v1, response}} = Protocol.decode_request(Jason.encode!(request))
      assert response["error"]["code"] == "invalid_params"
      assert response["error"]["details"] == %{"field" => "params"}
    end

    request = Map.put(@valid_request, "params", %{"value" => String.duplicate("x", 65_537)})

    assert {:error, {:v1, response}} = Protocol.decode_request(Jason.encode!(request))
    assert response["error"]["code"] == "invalid_params"
    assert response["error"]["details"] == %{"field" => "params", "maximum_bytes" => 65_536}
  end

  test "rejects params that exceed structural JSON bounds" do
    deeply_nested = Enum.reduce(1..7, %{"leaf" => true}, &%{"level#{&1}" => &2})
    over_ceiling = Protocol.limits().max_json_collection_items + 1
    too_many_items = Map.new(1..over_ceiling, &{"item#{&1}", &1})

    for params <- [deeply_nested, too_many_items] do
      request = Map.put(@valid_request, "params", params)

      assert {:error, {:v1, response}} = Protocol.decode_request(Jason.encode!(request))
      assert response["error"]["code"] == "invalid_params"
      assert response["error"]["details"] == %{"field" => "params"}
    end
  end

  test "rejects unknown top-level fields" do
    request = Map.put(@valid_request, "extra", true)

    assert {:error, {:v1, response}} = Protocol.decode_request(Jason.encode!(request))
    assert response["error"]["code"] == "invalid_request"
    assert response["error"]["details"] == %{"field" => "extra"}
  end

  test "builds success and error responses with exactly one outcome" do
    assert {:ok, success} = Protocol.respond("req-123", {:ok, %{"ready" => true}})
    assert success == %{"request_id" => "req-123", "result" => %{"ready" => true}}
    refute Map.has_key?(success, "error")

    assert {:ok, error} =
             Protocol.respond("req-123", {:error, :method_not_found, %{"method" => "missing"}})

    assert error == %{
             "request_id" => "req-123",
             "error" => %{
               "code" => "method_not_found",
               "message" => "The requested management method is not available.",
               "details" => %{"method" => "missing"}
             }
           }

    refute Map.has_key?(error, "result")
  end

  test "rejects unknown errors and oversized public details" do
    assert {:error, :unknown_error_code} =
             Protocol.respond("req-123", {:error, :not_allowlisted, %{}})

    details = %{"value" => String.duplicate("x", 4_097)}

    assert {:error, {:error_details_too_large, size, 4_096}} =
             Protocol.respond("req-123", {:error, :internal_error, details})

    assert size > 4_096
  end

  test "rejects arbitrary internal terms in public results" do
    assert {:error, :invalid_result} =
             Protocol.respond("req-123", {:ok, %{"owner" => self()}})
  end

  test "never serializes arbitrary internal terms as public error details" do
    internal = {:failed, self(), make_ref(), {:secret, "authorization-token"}}

    assert {:error, :invalid_error_details} =
             Protocol.respond("req-123", {:error, :internal_error, %{"reason" => internal}})
  end

  # M34 §5 publishes a 500-entry `logs.query` ceiling and §6 a 500-entry
  # diagnostics tail. A collection ceiling below either turns every full page
  # into `internal_error` at the responder, which no direct-module test can see.
  test "a result may carry every entry the published bounds allow" do
    entries = for index <- 1..500, do: %{"time" => "t", "level" => "info", "n" => index}

    assert {:ok, response} =
             Protocol.respond("req-1", {:ok, %{"entries" => entries, "count" => 500}})

    assert length(response["result"]["entries"]) == 500
    assert Protocol.limits().max_json_collection_items >= 500
  end

  # `error_codes/0` is the published catalog: the schema enum, PROTOCOL.md, the
  # fixture-coverage gate and the client's accept-list all read it. A code that
  # `respond/2` can emit but the catalog omits is invisible to every one of them
  # and is rejected by the client as "not protocol v1".
  test "every emittable error code appears in the published catalog" do
    for code <- Protocol.error_codes() do
      assert {:ok, %{"error" => %{"code" => ^code}}} =
               Protocol.respond("req-1", {:error, String.to_existing_atom(code), %{}})
    end

    assert Protocol.error_codes() == Enum.uniq(Protocol.error_codes())
    assert length(Protocol.error_codes()) == map_size(Protocol.error_messages())
  end

  defp put_or_delete(map, key, nil), do: Map.delete(map, key)
  defp put_or_delete(map, key, value), do: Map.put(map, key, value)
end
