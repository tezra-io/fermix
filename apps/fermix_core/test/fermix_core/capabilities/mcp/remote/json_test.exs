defmodule FermixCore.Capabilities.MCP.Remote.JsonTest do
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.MCP.Remote.Json
  alias FermixCore.Capabilities.MCP.Remote.Limits

  defp nest(0), do: %{"leaf" => 1}
  defp nest(n), do: %{"a" => nest(n - 1)}

  describe "encode/1" do
    test "encodes a payload within bounds" do
      assert {:ok, encoded} = Json.encode(%{"method" => "tools/list"})
      assert Jason.decode!(encoded) == %{"method" => "tools/list"}
    end

    test "refuses a payload deeper than the request depth bound" do
      deep = nest(Limits.max_request_depth() + 2)

      assert {:error, {:request_depth, _found, _max}} = Json.encode(deep)
    end

    test "refuses a payload larger than the request byte bound" do
      big = %{"blob" => String.duplicate("x", Limits.max_request_bytes() + 1)}

      assert {:error, {:request_bytes, _size, _max}} = Json.encode(big)
    end
  end

  describe "decode/2" do
    test "decodes within an explicit budget" do
      assert {:ok, %{"a" => 1}} = Json.decode(~s({"a":1}), max_bytes: 100, max_depth: 8)
    end

    test "refuses a payload over the caller's byte budget" do
      assert {:error, {:payload_bytes, _size, 4}} =
               Json.decode(~s({"a":1}), max_bytes: 4, max_depth: 8)
    end

    test "refuses a payload over the caller's depth budget" do
      raw = Jason.encode!(nest(10))

      assert {:error, {:payload_depth, _found, 4}} =
               Json.decode(raw, max_bytes: 10_000, max_depth: 4)
    end

    test "refuses a payload over the caller's node budget" do
      raw = Jason.encode!(Enum.map(1..50, & &1))

      assert {:error, {:payload_nodes, _found, 10}} =
               Json.decode(raw, max_bytes: 10_000, max_depth: 8, max_nodes: 10)
    end

    # The raw body is exactly where user or attacker content lives; §11.1
    # forbids it reaching a log, trace, or status string.
    test "a malformed body never carries its bytes into the error" do
      assert {:error, :invalid_json} =
               Json.decode(~s({"canary":"SENSITIVE), max_bytes: 1_000, max_depth: 8)
    end
  end

  describe "structural measurement" do
    test "depth counts containers, with a scalar at 1" do
      assert Json.depth(1) == 1
      assert Json.depth(%{}) == 1
      assert Json.depth([]) == 1
      assert Json.depth(%{"a" => 1}) == 2
      assert Json.depth(%{"a" => %{"b" => 1}}) == 3
      assert Json.depth([[1]]) == 3
    end

    # Keys are not separate nodes — the value each key maps to is already
    # counted, so a wide map and a long list cost the same per entry.
    test "nodes counts containers and values alike" do
      assert Json.nodes(1) == 1
      assert Json.nodes(%{"a" => 1}) == 2
      assert Json.nodes(%{"a" => [1, 2]}) == 4
    end
  end
end
