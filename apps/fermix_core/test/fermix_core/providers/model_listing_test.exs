defmodule FermixCore.Providers.ModelListingTest do
  use ExUnit.Case, async: true

  alias FermixCore.Providers.ModelListing

  describe "live?/1" do
    test "only ollama, openrouter and venice have live listings" do
      assert ModelListing.live?(:ollama)
      assert ModelListing.live?(:openrouter)
      assert ModelListing.live?(:venice)
      refute ModelListing.live?(:openai)
      refute ModelListing.live?(:anthropic)
    end
  end

  describe "model_family/1" do
    test "is the first run of ASCII letters in the vendor's own name, downcased" do
      assert ModelListing.model_family("Kimi K3") == "kimi"
      assert ModelListing.model_family("Kimi K2.6") == "kimi"
      assert ModelListing.model_family("GPT-6 Astra") == "gpt"
      assert ModelListing.model_family("MiMo-V2.5") == "mimo"
      assert ModelListing.model_family("DeepSeek V4.1 Flash") == "deepseek"
    end

    test "a name with no letters has no family rather than raising" do
      assert ModelListing.model_family("4.6") == ""
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
    test "filters to tool-capable models and sorts by id so vendors cluster" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.request_path == "/api/v1/models"

        Req.Test.json(conn, %{
          "data" => [
            %{
              "id" => "openai/gpt-x",
              "name" => "GPT X",
              "context_length" => 100_000,
              "created" => 300,
              "supported_parameters" => ["tools"]
            },
            %{
              "id" => "anthropic/opus",
              "name" => "Opus",
              "context_length" => 200_000,
              "created" => 100,
              "supported_parameters" => ["tools", "reasoning"]
            },
            %{
              "id" => "anthropic/sonnet",
              "name" => "Sonnet",
              "context_length" => 200_000,
              "created" => 200,
              "supported_parameters" => ["tools"]
            },
            %{
              "id" => "chat/only",
              "name" => "Chat Only",
              "created" => 400,
              "supported_parameters" => ["temperature"]
            },
            %{"id" => "openai/no-params", "created" => 50}
          ]
        })
      end)

      assert {:ok, models} =
               ModelListing.live_models(:openrouter,
                 req_options: [plug: {Req.Test, __MODULE__}]
               )

      # Sorted by id (NOT by `created`): anthropic/* cluster, then openai/*;
      # the non-tool-capable "chat/only" is filtered out.
      assert Enum.map(models, & &1.id) == [
               "anthropic/opus",
               "anthropic/sonnet",
               "openai/gpt-x",
               "openai/no-params"
             ]

      assert [%{label: "Opus", context_window: 200_000} | _rest] = models
    end

    test "reports non-200 upstream answers as a readable error" do
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "down") end)

      assert {:error, reason} =
               ModelListing.live_models(:openrouter, req_options: [plug: {Req.Test, __MODULE__}])

      assert reason =~ "HTTP 503"
    end
  end

  # M49 §3.3. The fixture is a trimmed recording of the real
  # `GET /models?type=text` shape (2026-09-19): one model per rule rather than
  # the 117 the endpoint serves.
  describe "live_models/2 — :venice" do
    test "keeps tool-capable models, orders by family then newest, and ties on id" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.request_path == "/api/v1/models"
        assert conn.query_string == "type=text"

        Req.Test.json(conn, %{"data" => venice_models(), "object" => "list", "type" => "text"})
      end)

      assert {:ok, models} =
               ModelListing.live_models(:venice, req_options: [plug: {Req.Test, __MODULE__}])

      # Families ascending (claude, deepseek, gpt, kimi); newest first inside
      # each; the two same-day DeepSeek entries fall back to id order.
      assert Enum.map(models, & &1.id) == [
               "claude-opus-5",
               "deepseek-v4-1",
               "deepseek-v4-1-flash",
               "gpt-6-astra",
               "e2ee-kimi-k3-p",
               "kimi-k3",
               "kimi-k2-6"
             ]
    end

    test "the label carries the vendor's name and the privacy tier, TEE included" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{"data" => venice_models()})
      end)

      assert {:ok, models} =
               ModelListing.live_models(:venice, req_options: [plug: {Req.Test, __MODULE__}])

      labels = Map.new(models, &{&1.id, &1.label})

      assert labels["kimi-k3"] == "Kimi K3 · Private"
      assert labels["e2ee-kimi-k3-p"] == "Kimi K3 · Private (TEE)"
      assert labels["claude-opus-5"] == "Claude Opus 5 · Anonymized"
      assert labels["gpt-6-astra"] == "GPT-6 Astra · Anonymized"
    end

    test "context_window comes from context_length, and an absent one stays absent" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{"data" => venice_models()})
      end)

      assert {:ok, models} =
               ModelListing.live_models(:venice, req_options: [plug: {Req.Test, __MODULE__}])

      by_id = Map.new(models, &{&1.id, &1})

      assert by_id["kimi-k3"].context_window == 1_000_000
      assert by_id["claude-opus-5"].context_window == nil
    end

    # A model that cannot call tools cannot run the loop at all (Fermix sends
    # `tools` on every request), and a model whose tier cannot be read cannot be
    # labelled truthfully — offered unlabelled beside labelled neighbours it
    # would read as the private default.
    test "drops the tool-less models and the ones with no readable privacy tier" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{"data" => venice_models()})
      end)

      assert {:ok, models} =
               ModelListing.live_models(:venice, req_options: [plug: {Req.Test, __MODULE__}])

      ids = Enum.map(models, & &1.id)

      refute "hermes-3-llama" in ids
      refute "mystery-model" in ids
      refute "nameless-model" in ids
    end

    test "reports non-200 upstream answers as a readable error" do
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "down") end)

      assert {:error, reason} =
               ModelListing.live_models(:venice, req_options: [plug: {Req.Test, __MODULE__}])

      assert reason =~ "HTTP 503"
    end
  end

  test "live_models/2 raises for providers without a live listing" do
    assert_raise ArgumentError, ~r/no live model listing for :openai/, fn ->
      ModelListing.live_models(:openai, [])
    end
  end

  defp venice_models do
    [
      venice_model("kimi-k3", "Kimi K3", "private", 1_784_160_000, context_length: 1_000_000),
      venice_model("kimi-k2-6", "Kimi K2.6", "private", 1_776_643_200, context_length: 256_000),
      venice_model("e2ee-kimi-k3-p", "Kimi K3", "private", 1_788_825_600,
        context_length: 1_000_000,
        tee: true
      ),
      venice_model("claude-opus-5", "Claude Opus 5", "anonymized", 1_780_000_000),
      venice_model("gpt-6-astra", "GPT-6 Astra", "anonymized", 1_781_000_000,
        context_length: 400_000
      ),
      # Same `created`, so the id breaks the tie deterministically.
      venice_model("deepseek-v4-1-flash", "DeepSeek V4.1 Flash", "private", 1_788_998_400,
        context_length: 1_000_000
      ),
      venice_model("deepseek-v4-1", "DeepSeek V4.1", "private", 1_788_998_400,
        context_length: 1_000_000
      ),
      venice_model("hermes-3-llama", "Hermes 3 Llama", "private", 1_700_000_000, tools: false),
      venice_model("mystery-model", "Mystery Model", "confidential", 1_790_000_000),
      %{
        "id" => "nameless-model",
        "created" => 1_790_000_000,
        "model_spec" => %{"privacy" => "private", "capabilities" => %{}}
      }
    ]
  end

  defp venice_model(id, name, privacy, created, opts \\ []) do
    spec = %{
      "name" => name,
      "privacy" => privacy,
      "capabilities" => %{
        "supportsFunctionCalling" => Keyword.get(opts, :tools, true),
        "supportsTeeAttestation" => Keyword.get(opts, :tee, false),
        "supportsVision" => true,
        "supportsMultipleImages" => true
      }
    }

    %{"id" => id, "created" => created, "object" => "model", "model_spec" => spec}
    |> put_context_length(Keyword.get(opts, :context_length))
  end

  defp put_context_length(model, nil), do: model
  defp put_context_length(model, length), do: Map.put(model, "context_length", length)
end
