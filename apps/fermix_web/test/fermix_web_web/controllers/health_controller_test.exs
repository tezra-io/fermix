defmodule FermixWebWeb.HealthControllerTest do
  use FermixWebWeb.ConnCase

  describe "GET /health" do
    test "returns 200 with status ok", %{conn: conn} do
      conn = get(conn, ~p"/health")
      body = json_response(conn, 200)

      assert body["status"] == "ok"
      assert body["app"] == "fermix"
      assert body["version"] == "0.1.0"
      assert is_binary(body["timestamp"])
    end
  end
end
