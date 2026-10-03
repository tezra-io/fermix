defmodule FermixCore.Providers.ModelListingTest do
  use ExUnit.Case, async: true

  alias FermixCore.Auth.ChatGPT
  alias FermixCore.Providers.ModelListing

  describe "live?/1" do
    test "only ollama, openrouter, venice and openai_codex have live listings" do
      assert ModelListing.live?(:ollama)
      assert ModelListing.live?(:openrouter)
      assert ModelListing.live?(:venice)
      assert ModelListing.live?(:openai_codex)
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

  # M57 §6.2: the signed-in account's own catalog, read with its bearer, in a
  # shape that is not the standard model list.
  describe "live_models/2 — :openai_codex" do
    defmodule ChatGPTTokens do
      @moduledoc false
      def get_token("chatgpt"), do: {:ok, "served-token"}
    end

    defp signed_in(_opts), do: :ok

    defp chatgpt_opts(extra \\ []) do
      Keyword.merge(
        [
          chatgpt_route_status: &signed_in/1,
          access_token: "plan-token",
          req_options: [plug: {Req.Test, __MODULE__}]
        ],
        extra
      )
    end

    defp chatgpt_model(slug, name, visibility),
      do: %{"slug" => slug, "display_name" => name, "visibility" => visibility}

    test "keeps the listed models in the server's order, slug as id and name as label" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.request_path == "/v1/models"
        assert ["Bearer plan-token"] = Plug.Conn.get_req_header(conn, "authorization")

        Req.Test.json(conn, %{
          "models" => [
            chatgpt_model("gpt-6.1-sol", "GPT-6.1 Sol", "list"),
            chatgpt_model("internal-eval", "Internal", "hide"),
            chatgpt_model("gpt-6-luna", "GPT-6 Luna", "list"),
            chatgpt_model("", "", "hide")
          ]
        })
      end)

      assert {:ok, models} = ModelListing.live_models(:openai_codex, chatgpt_opts())

      assert models == [
               %{id: "gpt-6.1-sol", label: "GPT-6.1 Sol", context_window: nil},
               %{id: "gpt-6-luna", label: "GPT-6 Luna", context_window: nil}
             ]
    end

    test "the bearer comes from the token server under the provider's chatgpt profile" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert ["Bearer served-token"] = Plug.Conn.get_req_header(conn, "authorization")
        Req.Test.json(conn, %{"models" => [chatgpt_model("gpt-6-luna", "GPT-6 Luna", "list")]})
      end)

      opts = chatgpt_opts(token_server: ChatGPTTokens) |> Keyword.delete(:access_token)

      assert {:ok, [%{id: "gpt-6-luna"}]} = ModelListing.live_models(:openai_codex, opts)
    end

    for {label, entry} <- [
          {"an empty slug", %{"slug" => "", "display_name" => "X", "visibility" => "list"}},
          {"a missing name", %{"slug" => "gpt-x", "visibility" => "list"}},
          {"an over-long name",
           %{
             "slug" => "gpt-x",
             "display_name" => String.duplicate("a", 201),
             "visibility" => "list"
           }}
        ] do
      test "a listed entry with #{label} fails the listing" do
        entry = unquote(Macro.escape(entry))

        Req.Test.stub(__MODULE__, fn conn ->
          Req.Test.json(conn, %{
            "models" => [chatgpt_model("gpt-6-luna", "GPT-6 Luna", "list"), entry]
          })
        end)

        assert {:error, reason} = ModelListing.live_models(:openai_codex, chatgpt_opts())
        assert reason =~ "no usable slug or name"
      end
    end

    test "the standard list shape is not this route's and fails" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{"object" => "list", "data" => [%{"id" => "gpt-6-luna"}]})
      end)

      assert {:error, reason} = ModelListing.live_models(:openai_codex, chatgpt_opts())
      assert reason =~ "unexpected response"
    end

    test "a refused listing says so, with no catalog answer" do
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 401, "{}") end)

      assert {:error, reason} = ModelListing.live_models(:openai_codex, chatgpt_opts())
      assert reason =~ "HTTP 401"
    end

    test "a sign-in that cannot carry a turn refuses with its own sentence" do
      opts = chatgpt_opts(chatgpt_route_status: fn [] -> {:error, :plan_usage_off} end)

      assert ModelListing.live_models(:openai_codex, opts) ==
               {:error, ChatGPT.failure_sentence(:plan_usage_off)}
    end

    test "the listing is a provider call on the openai_codex credential" do
      test_pid = self()
      handler_id = "chatgpt-listing-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:fermix, :provider, :call],
        fn _event, _measurements, metadata, _config ->
          if self() == test_pid, do: send(test_pid, {:call, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{"models" => [chatgpt_model("gpt-6-luna", "GPT-6 Luna", "list")]})
      end)

      assert {:ok, _models} = ModelListing.live_models(:openai_codex, chatgpt_opts())

      assert_receive {:call,
                      %{
                        provider: :openai_codex,
                        adapter: :model_listing,
                        status: :ok,
                        models_count: 1
                      }}
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
