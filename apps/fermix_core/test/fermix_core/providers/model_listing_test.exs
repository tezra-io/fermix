defmodule FermixCore.Providers.ModelListingTest do
  use ExUnit.Case, async: true

  alias FermixCore.Providers.ModelListing

  describe "live?/1" do
    test "only ollama and openrouter have live listings" do
      assert ModelListing.live?(:ollama)
      assert ModelListing.live?(:openrouter)
      refute ModelListing.live?(:openai)
      refute ModelListing.live?(:anthropic)
    end
  end

  describe "live_models/2 — :ollama" do
    test "lists installed models from the native /api/tags with size labels" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.request_path == "/api/tags"

        Req.Test.json(conn, %{
          "models" => [
            %{"name" => "qwen3:32b", "details" => %{"parameter_size" => "32.8B"}},
            %{"name" => "tinyllama:1b"}
          ]
        })
      end)

      assert {:ok, models} =
               ModelListing.live_models(:ollama,
                 base_url: "http://localhost:11434/v1",
                 req_options: [plug: {Req.Test, __MODULE__}]
               )

      assert [
               %{id: "qwen3:32b", label: "qwen3:32b (32.8B)", context_window: 128_000},
               %{id: "tinyllama:1b", label: "tinyllama:1b", context_window: nil}
             ] = models
    end

    test "reports a connection-refused server as a readable error" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, reason} =
               ModelListing.live_models(:ollama,
                 base_url: "http://localhost:11434/v1",
                 req_options: [plug: {Req.Test, __MODULE__}]
               )

      assert reason =~ "connection refused"
    end
  end

  describe "live_models/2 — :openrouter" do
    test "filters to tool-capable models and sorts newest first" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.request_path == "/api/v1/models"

        Req.Test.json(conn, %{
          "data" => [
            %{
              "id" => "old/tooler",
              "name" => "Old Tooler",
              "context_length" => 100_000,
              "created" => 100,
              "supported_parameters" => ["tools"]
            },
            %{
              "id" => "new/tooler",
              "name" => "New Tooler",
              "context_length" => 200_000,
              "created" => 200,
              "supported_parameters" => ["tools", "reasoning"]
            },
            %{
              "id" => "chat/only",
              "name" => "Chat Only",
              "created" => 300,
              "supported_parameters" => ["temperature"]
            },
            %{"id" => "no/params-field", "created" => 50}
          ]
        })
      end)

      assert {:ok, models} =
               ModelListing.live_models(:openrouter,
                 req_options: [plug: {Req.Test, __MODULE__}]
               )

      assert Enum.map(models, & &1.id) == ["new/tooler", "old/tooler", "no/params-field"]
      assert [%{label: "New Tooler", context_window: 200_000} | _rest] = models
    end

    test "reports non-200 upstream answers as a readable error" do
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "down") end)

      assert {:error, reason} =
               ModelListing.live_models(:openrouter, req_options: [plug: {Req.Test, __MODULE__}])

      assert reason =~ "HTTP 503"
    end
  end

  test "live_models/2 raises for providers without a live listing" do
    assert_raise ArgumentError, ~r/no live model listing for :openai/, fn ->
      ModelListing.live_models(:openai, [])
    end
  end
end
