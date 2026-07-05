defmodule FermixCore.Setup.DoctorTest do
  use ExUnit.Case, async: false

  alias FermixCore.Auth.Store
  alias FermixCore.Auth.TokenManager
  alias FermixCore.Setup.Doctor

  defmodule HealthyChannel do
    def health_check(opts) do
      send(Keyword.fetch!(opts, :test_pid), {:channel_health_checked, :healthy})
      {:ok, %{detail: "healthy channel ok", latency_ms: 3}}
    end
  end

  defmodule DisabledChannel do
    def health_check(opts) do
      send(Keyword.fetch!(opts, :test_pid), {:channel_health_checked, :disabled})
      {:ok, %{detail: "disabled channel ok", latency_ms: 3}}
    end
  end

  setup do
    original_providers = Application.get_env(:fermix_core, :providers, [])
    original_agent = Application.get_env(:fermix_core, :agent, [])
    original_compaction = Application.get_env(:fermix_core, :compaction, [])
    original_tools = Application.get_env(:fermix_core, :tools, [])
    original_registry = Application.get_env(:fermix_channels, :channel_registry)

    original_channels =
      for channel <- [:telegram, :whatsapp, :discord, :slack, :signal], into: %{} do
        {channel, Application.get_env(:fermix_channels, channel, [])}
      end

    on_exit(fn ->
      Application.put_env(:fermix_core, :providers, original_providers)
      Application.put_env(:fermix_core, :agent, original_agent)
      Application.put_env(:fermix_core, :compaction, original_compaction)
      Application.put_env(:fermix_core, :tools, original_tools)
      restore_env(:fermix_channels, :channel_registry, original_registry)
      Application.delete_env(:fermix_channels, :healthy_channel)
      Application.delete_env(:fermix_channels, :disabled_channel)

      Enum.each(original_channels, fn {channel, config} ->
        Application.put_env(:fermix_channels, channel, config)
      end)
    end)

    :ok
  end

  defp put_provider(provider, config) do
    Application.put_env(
      :fermix_core,
      :providers,
      [{provider, config}] ++ Application.get_env(:fermix_core, :providers, [])
    )
  end

  defp set_active(provider) do
    Application.put_env(:fermix_core, :agent, name: "fermix", provider: provider)
  end

  defp tmp_dir do
    Path.join(System.tmp_dir!(), "fermix_doctor_#{System.unique_integer([:positive])}")
  end

  defp future_iso8601(seconds) do
    DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.to_iso8601()
  end

  defp write_codex_auth(dir, access_token, refresh_token \\ "refresh-token") do
    File.mkdir_p!(dir)
    path = Path.join(dir, "auth.json")

    File.write!(
      path,
      Jason.encode!(%{
        "version" => 1,
        "providers" => %{
          "openai_codex" => %{
            "auth_mode" => "chatgpt",
            "tokens" => %{
              "access_token" => access_token,
              "refresh_token" => refresh_token
            },
            "expires_at" => future_iso8601(3600)
          }
        }
      })
    )

    path
  end

  describe "computer_use_permissions/0" do
    setup do
      original = Application.get_env(:fermix_core, :computer_use, [])
      on_exit(fn -> Application.put_env(:fermix_core, :computer_use, original) end)
      :ok
    end

    test "reports :disabled without spawning the sidecar when the feature is off" do
      # Establish the precondition rather than trusting global env (hermetic rule):
      # disabled short-circuits before installed?/probe, so this is deterministic.
      Application.put_env(:fermix_core, :computer_use, enabled: false)
      assert {:ok, %{state: :disabled}} = Doctor.computer_use_permissions()
    end
  end

  describe "active_provider/0" do
    test "defaults to :openai when agent.provider is unset" do
      Application.delete_env(:fermix_core, :agent)
      assert Doctor.active_provider() == :openai
    end

    test "returns the configured provider" do
      set_active(:openai_codex)
      assert Doctor.active_provider() == :openai_codex
    end

    test "raises ArgumentError on garbage atom (e.g. user typo)" do
      Application.put_env(:fermix_core, :agent, name: "fermix", provider: :openia)

      assert_raise ArgumentError, ~r/unknown provider :openia/, fn ->
        Doctor.active_provider()
      end
    end
  end

  describe "probe_provider/2 — unknown provider" do
    test "raises ArgumentError" do
      assert_raise ArgumentError, ~r/unknown provider :gemini/, fn ->
        Doctor.probe_provider(:gemini)
      end
    end
  end

  describe "probe_provider/2 — :openai" do
    test "returns ok with model and latency on 200" do
      put_provider(:openai, api_key: "sk-test", default_model: "gpt-5.5")

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body =~ "gpt-5.5"
        assert ["Bearer sk-test"] = Plug.Conn.get_req_header(conn, "authorization")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"ok": true}))
      end

      assert {:ok, %{provider: :openai, model: "gpt-5.5", latency_ms: ms}} =
               Doctor.probe_provider(:openai, req_options: [plug: plug])

      assert is_integer(ms) and ms >= 0
    end

    test "returns auth_scope_mismatch on 401" do
      put_provider(:openai, api_key: "sk-bad")

      plug = fn conn ->
        Plug.Conn.send_resp(conn, 401, ~s({"error":{"message":"unauthorized"}}))
      end

      assert {:error, {:auth_scope_mismatch, surface, hint}} =
               Doctor.probe_provider(:openai, req_options: [plug: plug])

      assert surface =~ "api.openai.com"
      assert hint =~ "api.responses.write"
    end

    test "returns auth_scope_mismatch on 403" do
      put_provider(:openai, api_key: "sk-test")

      plug = fn conn -> Plug.Conn.send_resp(conn, 403, "{}") end

      assert {:error, {:auth_scope_mismatch, _surface, _hint}} =
               Doctor.probe_provider(:openai, req_options: [plug: plug])
    end

    test "returns server_error on 5xx" do
      put_provider(:openai, api_key: "sk-test")

      plug = fn conn -> Plug.Conn.send_resp(conn, 500, ~s({"error":"boom"})) end

      assert {:error, {:server_error, 500, _body}} =
               Doctor.probe_provider(:openai, req_options: [plug: plug])
    end

    test "returns server_error on 4xx (non-401/403)" do
      put_provider(:openai, api_key: "sk-test")

      plug = fn conn -> Plug.Conn.send_resp(conn, 429, ~s({"error":"rate limit"})) end

      assert {:error, {:server_error, 429, _body}} =
               Doctor.probe_provider(:openai, req_options: [plug: plug])
    end

    test "returns misconfigured when api_key is missing" do
      Application.put_env(:fermix_core, :providers, openai: [])

      assert {:error, {:misconfigured, message}} = Doctor.probe_provider(:openai)
      assert message =~ "openai"
      assert message =~ "api_key"
    end

    test "returns misconfigured when api_key is empty string" do
      put_provider(:openai, api_key: "")

      assert {:error, {:misconfigured, _}} = Doctor.probe_provider(:openai)
    end

    test "does not use OAuth for the regular OpenAI provider" do
      put_provider(:openai, auth_mode: :oauth, default_model: "gpt-5.5")

      assert {:error, {:misconfigured, message}} = Doctor.probe_provider(:openai)
      assert message =~ "openai"
      assert message =~ "api_key"
    end

    test "uses ModelCatalog default when default_model is unset" do
      put_provider(:openai, api_key: "sk-test")
      seen_model = :counters.new(1, [])

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        if body =~ "gpt-5.5", do: :counters.add(seen_model, 1, 1)
        Plug.Conn.send_resp(conn, 200, "{}")
      end

      assert {:ok, %{model: "gpt-5.5"}} =
               Doctor.probe_provider(:openai, req_options: [plug: plug])

      assert :counters.get(seen_model, 1) == 1
    end
  end

  describe "probe_provider/2 — :anthropic" do
    test "sends x-api-key header and anthropic-version" do
      put_provider(:anthropic, api_key: "sk-ant-test", default_model: "claude-sonnet-4-6")

      plug = fn conn ->
        assert ["sk-ant-test"] = Plug.Conn.get_req_header(conn, "x-api-key")
        assert ["2023-06-01"] = Plug.Conn.get_req_header(conn, "anthropic-version")
        Plug.Conn.send_resp(conn, 200, ~s({"id":"x"}))
      end

      assert {:ok, %{provider: :anthropic, model: "claude-sonnet-4-6"}} =
               Doctor.probe_provider(:anthropic, req_options: [plug: plug])
    end

    test "returns auth_scope_mismatch on 401 with anthropic-specific hint" do
      put_provider(:anthropic, api_key: "sk-ant-bad")

      plug = fn conn -> Plug.Conn.send_resp(conn, 401, "{}") end

      assert {:error, {:auth_scope_mismatch, surface, hint}} =
               Doctor.probe_provider(:anthropic, req_options: [plug: plug])

      assert surface =~ "anthropic"
      assert hint =~ "Anthropic"
    end

    test "returns misconfigured when api_key missing" do
      Application.put_env(:fermix_core, :providers, anthropic: [])

      assert {:error, {:misconfigured, message}} = Doctor.probe_provider(:anthropic)
      assert message =~ "anthropic"
    end

    test "oauth mode probes with bearer auth and Claude Code identity headers" do
      put_provider(:anthropic, auth_mode: "oauth", default_model: "claude-sonnet-4-6")

      plug = fn conn ->
        assert ["Bearer sub-tok"] = Plug.Conn.get_req_header(conn, "authorization")
        assert [] = Plug.Conn.get_req_header(conn, "x-api-key")
        assert [beta] = Plug.Conn.get_req_header(conn, "anthropic-beta")
        assert beta =~ "oauth-2025-04-20"
        Plug.Conn.send_resp(conn, 200, ~s({"id":"x"}))
      end

      assert {:ok, %{provider: :anthropic, model: "claude-sonnet-4-6"}} =
               Doctor.probe_provider(:anthropic,
                 access_token: "sub-tok",
                 req_options: [plug: plug]
               )
    end

    test "oauth mode reads the bearer from the auth store when no token is supplied" do
      dir = tmp_dir()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)
      auth_path = Path.join(dir, "auth.json")

      :ok =
        Store.write(
          "anthropic_oauth",
          %{
            auth_mode: "setup_token",
            provider: "anthropic",
            tokens: %{access_token: "stored-sub-tok", refresh_token: nil},
            expires_at: nil,
            last_refresh: nil
          },
          auth_path
        )

      put_provider(:anthropic, auth_mode: "oauth")

      plug = fn conn ->
        assert ["Bearer stored-sub-tok"] = Plug.Conn.get_req_header(conn, "authorization")
        Plug.Conn.send_resp(conn, 200, ~s({"id":"x"}))
      end

      assert {:ok, %{provider: :anthropic}} =
               Doctor.probe_provider(:anthropic,
                 fermix_auth_path: auth_path,
                 req_options: [plug: plug]
               )
    end

    test "oauth mode without stored credentials is misconfigured" do
      dir = tmp_dir()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)
      put_provider(:anthropic, auth_mode: "oauth")

      assert {:error, {:misconfigured, message}} =
               Doctor.probe_provider(:anthropic,
                 fermix_auth_path: Path.join(dir, "missing.json")
               )

      assert message =~ "anthropic"
    end
  end

  describe "probe_provider/2 — :xai" do
    test "sends bearer auth to the responses endpoint" do
      put_provider(:xai, api_key: "xai-key", default_model: "grok-4.3")

      plug = fn conn ->
        assert ["Bearer xai-key"] = Plug.Conn.get_req_header(conn, "authorization")
        Plug.Conn.send_resp(conn, 200, ~s({"id":"x"}))
      end

      assert {:ok, %{provider: :xai, model: "grok-4.3"}} =
               Doctor.probe_provider(:xai, req_options: [plug: plug])
    end

    test "probes a configured root base_url at the /responses endpoint (matches the adapter)" do
      put_provider(:xai, api_key: "xai-key", base_url: "https://xai-proxy.example/v1")

      plug = fn conn ->
        # The runtime adapter treats base_url as a root and appends
        # /responses; the probe must hit the same URL, not the root.
        assert conn.host == "xai-proxy.example"
        assert conn.request_path == "/v1/responses"
        Plug.Conn.send_resp(conn, 200, ~s({"id":"x"}))
      end

      assert {:ok, %{provider: :xai}} =
               Doctor.probe_provider(:xai, req_options: [plug: plug])
    end

    test "returns auth_scope_mismatch on 401 with an xai-specific hint" do
      put_provider(:xai, api_key: "xai-bad")

      plug = fn conn -> Plug.Conn.send_resp(conn, 401, "{}") end

      assert {:error, {:auth_scope_mismatch, surface, hint}} =
               Doctor.probe_provider(:xai, req_options: [plug: plug])

      assert surface =~ "api.x.ai"
      assert hint =~ "xAI"
    end

    test "returns misconfigured when api_key missing" do
      Application.put_env(:fermix_core, :providers, xai: [])

      assert {:error, {:misconfigured, message}} = Doctor.probe_provider(:xai)
      assert message =~ "xai"
    end

    test "oauth mode probes with the stored subscription bearer" do
      put_provider(:xai, auth_mode: "oauth", default_model: "grok-4.3")

      plug = fn conn ->
        assert ["Bearer sub-tok"] = Plug.Conn.get_req_header(conn, "authorization")
        Plug.Conn.send_resp(conn, 200, ~s({"id":"x"}))
      end

      assert {:ok, %{provider: :xai, model: "grok-4.3"}} =
               Doctor.probe_provider(:xai, access_token: "sub-tok", req_options: [plug: plug])
    end

    test "oauth 401 maps to the subscription reconnect hint" do
      put_provider(:xai, auth_mode: "oauth")

      plug = fn conn -> Plug.Conn.send_resp(conn, 401, "{}") end

      assert {:error, {:auth_scope_mismatch, surface, hint}} =
               Doctor.probe_provider(:xai, access_token: "sub-tok", req_options: [plug: plug])

      assert surface =~ "Grok subscription"
      assert hint =~ "fermix auth login --provider xai"
    end

    test "oauth mode without stored credentials is misconfigured" do
      dir = tmp_dir()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)
      put_provider(:xai, auth_mode: "oauth")

      assert {:error, {:misconfigured, message}} =
               Doctor.probe_provider(:xai, fermix_auth_path: Path.join(dir, "missing.json"))

      assert message =~ "xai"
    end
  end

  describe "probe_provider/2 — :openrouter" do
    test "sends a 1-token chat completion with attribution headers (mirrors the adapter)" do
      put_provider(:openrouter, api_key: "sk-or-key", default_model: "z-ai/glm-5.1")

      plug = fn conn ->
        assert ["Bearer sk-or-key"] = Plug.Conn.get_req_header(conn, "authorization")
        assert ["https://fermix.sh"] = Plug.Conn.get_req_header(conn, "http-referer")
        assert ["Fermix"] = Plug.Conn.get_req_header(conn, "x-title")
        assert conn.request_path == "/api/v1/chat/completions"
        Plug.Conn.send_resp(conn, 200, ~s({"id":"or-1"}))
      end

      assert {:ok, %{provider: :openrouter, model: "z-ai/glm-5.1"}} =
               Doctor.probe_provider(:openrouter, req_options: [plug: plug])
    end

    test "classifies a 401 as auth_scope_mismatch with an OpenRouter hint" do
      put_provider(:openrouter, api_key: "sk-or-bad")

      plug = fn conn -> Plug.Conn.send_resp(conn, 401, ~s({"error":"bad key"})) end

      assert {:error, {:auth_scope_mismatch, "openrouter.ai API key", hint}} =
               Doctor.probe_provider(:openrouter, req_options: [plug: plug])

      assert hint =~ "OpenRouter API key rejected"
    end

    test "reports missing api_key as misconfigured" do
      put_provider(:openrouter, [])

      assert {:error, {:misconfigured, message}} = Doctor.probe_provider(:openrouter)
      assert message =~ "openrouter provider has no api_key"
    end
  end

  describe "probe_provider/2 — :ollama" do
    test "probes /v1 keyless and accepts when /api/show reports a healthy num_ctx" do
      put_provider(:ollama, base_url: "http://localhost:11434/v1", default_model: "qwen3:32b")

      plug = fn conn ->
        case conn.request_path do
          "/v1/chat/completions" ->
            assert [] = Plug.Conn.get_req_header(conn, "authorization")
            Plug.Conn.send_resp(conn, 200, ~s({"id":"local"}))

          "/api/show" ->
            body =
              Jason.encode!(%{
                "parameters" => "num_ctx 131072",
                "model_info" => %{"qwen3.context_length" => 131_072}
              })

            conn
            |> Plug.Conn.put_resp_header("content-type", "application/json")
            |> Plug.Conn.send_resp(200, body)
        end
      end

      assert {:ok, %{provider: :ollama, model: "qwen3:32b"}} =
               Doctor.probe_provider(:ollama, req_options: [plug: plug])
    end

    test "fails loud when the served num_ctx undercuts the catalog window" do
      put_provider(:ollama, base_url: "http://localhost:11434/v1", default_model: "qwen3:32b")

      plug = fn conn ->
        case conn.request_path do
          "/v1/chat/completions" ->
            Plug.Conn.send_resp(conn, 200, ~s({"id":"local"}))

          "/api/show" ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "application/json")
            |> Plug.Conn.send_resp(200, Jason.encode!(%{"parameters" => "num_ctx 4096"}))
        end
      end

      assert {:error, {:misconfigured, message}} =
               Doctor.probe_provider(:ollama, req_options: [plug: plug])

      assert message =~ "num_ctx=4096"
      assert message =~ "OLLAMA_CONTEXT_LENGTH"
    end

    test "an unreachable /api/show is inconclusive — the chat probe decides" do
      put_provider(:ollama, base_url: "http://localhost:11434/v1", default_model: "qwen3:32b")

      plug = fn conn ->
        case conn.request_path do
          "/v1/chat/completions" -> Plug.Conn.send_resp(conn, 200, ~s({"id":"local"}))
          "/api/show" -> Plug.Conn.send_resp(conn, 404, "no native api")
        end
      end

      assert {:ok, %{provider: :ollama}} =
               Doctor.probe_provider(:ollama, req_options: [plug: plug])
    end

    test "maps a 404 model error to an `ollama pull` hint" do
      put_provider(:ollama, base_url: "http://localhost:11434/v1", default_model: "missing:7b")

      plug = fn conn -> Plug.Conn.send_resp(conn, 404, ~s({"error":"model not found"})) end

      assert {:error, {:misconfigured, message}} =
               Doctor.probe_provider(:ollama, req_options: [plug: plug])

      assert message =~ "ollama pull missing:7b"
    end

    test "reports a missing base_url as misconfigured (explicit opt-in)" do
      put_provider(:ollama, [])

      assert {:error, {:misconfigured, message}} = Doctor.probe_provider(:ollama)
      assert message =~ "no base_url configured"
    end
  end

  describe "probe_provider/2 — :openai_codex" do
    test "uses bearer token from Auth.Store without a running TokenManager" do
      dir = tmp_dir()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)

      auth_path = write_codex_auth(dir, "store-bearer-xyz")
      put_provider(:openai_codex, default_model: "gpt-5.5")

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["stream"] == true
        assert decoded["store"] == false
        refute Map.has_key?(decoded, "max_output_tokens")
        assert ["Bearer store-bearer-xyz"] = Plug.Conn.get_req_header(conn, "authorization")
        Plug.Conn.send_resp(conn, 200, "{}")
      end

      assert {:ok, %{provider: :openai_codex, model: "gpt-5.5"}} =
               Doctor.probe_provider(:openai_codex,
                 fermix_auth_path: auth_path,
                 req_options: [plug: plug]
               )
    end

    test "uses a running TokenManager instead of refreshing directly from disk" do
      dir = tmp_dir()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)

      auth_path = write_codex_auth(dir, "manager-bearer-xyz")
      put_provider(:openai_codex, default_model: "gpt-5.5")
      manager = :"doctor_token_manager_#{System.unique_integer([:positive])}"

      start_supervised!({TokenManager, [name: manager, fermix_auth_path: auth_path]}, id: manager)
      FermixTestSupport.SafeRm.rm!(auth_path)

      plug = fn conn ->
        assert ["Bearer manager-bearer-xyz"] = Plug.Conn.get_req_header(conn, "authorization")
        Plug.Conn.send_resp(conn, 200, "{}")
      end

      assert {:ok, %{provider: :openai_codex, model: "gpt-5.5"}} =
               Doctor.probe_provider(:openai_codex,
                 token_manager: manager,
                 req_options: [plug: plug]
               )
    end

    test "returns misconfigured when Auth.Store has no token" do
      dir = tmp_dir()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)

      put_provider(:openai_codex, default_model: "gpt-5.5")

      assert {:error, {:misconfigured, message}} =
               Doctor.probe_provider(:openai_codex,
                 fermix_auth_path: Path.join(dir, "missing-auth.json")
               )

      assert message =~ "Codex token"
    end

    test "returns auth_scope_mismatch on 401 with codex-specific hint" do
      dir = tmp_dir()
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)

      auth_path = write_codex_auth(dir, "oauth-stale")
      put_provider(:openai_codex, default_model: "gpt-5.5")

      plug = fn conn -> Plug.Conn.send_resp(conn, 401, "unauthorized") end

      assert {:error, {:auth_scope_mismatch, surface, hint}} =
               Doctor.probe_provider(:openai_codex,
                 fermix_auth_path: auth_path,
                 req_options: [plug: plug]
               )

      assert surface =~ "Codex"
      assert hint =~ "fermix setup --import-codex"
    end
  end

  describe "probe_active/1" do
    test "dispatches to the active provider" do
      put_provider(:anthropic, api_key: "sk-ant-test")
      set_active(:anthropic)

      plug = fn conn -> Plug.Conn.send_resp(conn, 200, "{}") end

      assert {:ok, %{provider: :anthropic}} =
               Doctor.probe_active(req_options: [plug: plug])
    end
  end

  describe "compaction_report/0" do
    test "reports threshold, active route context window, and trigger token count" do
      Application.put_env(:fermix_core, :compaction, enabled: true, threshold: 0.8)
      put_provider(:anthropic, default_model: "claude-haiku-4-5")
      set_active(:anthropic)

      report = Doctor.compaction_report()

      assert report.enabled == true
      assert report.threshold == 0.8
      assert report.provider == :anthropic
      assert report.model == "claude-haiku-4-5"
      assert report.context_window == 200_000
      assert report.compact_at_tokens == 160_000

      assert %{provider: :openai, model: "gpt-5.5", context_window: 1_050_000} in report.catalog
    end
  end

  describe "command_owner_report/0" do
    test "reports per-channel owner and allowlist configuration" do
      Application.put_env(:fermix_channels, :telegram,
        enabled: true,
        owner_user_id: "111",
        command_allowlist: ["222", "333"]
      )

      Application.put_env(:fermix_channels, :signal, enabled: true)

      report = Doctor.command_owner_report()

      assert %{
               channel: :telegram,
               enabled: true,
               owner_user_id: "111",
               command_allowlist: ["222", "333"]
             } in report

      assert %{channel: :signal, enabled: true, owner_user_id: nil, command_allowlist: []} in report
    end
  end

  describe "probe_channels/1" do
    test "probes enabled registry channels and skips disabled channels" do
      Application.put_env(:fermix_channels, :channel_registry, [
        %{
          name: "healthy",
          config_key: :healthy_channel,
          adapter: HealthyChannel,
          remote?: true,
          transport: :webhook,
          child: nil
        },
        %{
          name: "disabled",
          config_key: :disabled_channel,
          adapter: DisabledChannel,
          remote?: true,
          transport: :webhook,
          child: nil
        }
      ])

      Application.put_env(:fermix_channels, :healthy_channel, enabled: true)
      Application.put_env(:fermix_channels, :disabled_channel, enabled: false)

      assert [
               %{
                 channel: :healthy_channel,
                 name: "healthy",
                 status: :ok,
                 detail: "healthy channel ok"
               }
             ] = Doctor.probe_channels(test_pid: self())

      assert_received {:channel_health_checked, :healthy}
      refute_received {:channel_health_checked, :disabled}
    end
  end

  defmodule DraftCapableAdapter do
    def stream_capability, do: :draft_edit
  end

  defmodule NoStreamAdapter do
  end

  describe "streaming_config_report/0" do
    test "pairs each configured channel's streaming opt-in with its capability" do
      Application.put_env(:fermix_channels, :channel_registry, [
        %{
          name: "drafty",
          config_key: :drafty_channel,
          adapter: DraftCapableAdapter,
          remote?: true,
          transport: :webhook,
          child: nil
        },
        %{
          name: "plain",
          config_key: :plain_channel,
          adapter: NoStreamAdapter,
          remote?: true,
          transport: :webhook,
          child: nil
        },
        %{
          name: "unconfigured",
          config_key: :unconfigured_channel,
          adapter: NoStreamAdapter,
          remote?: true,
          transport: :webhook,
          child: nil
        }
      ])

      Application.put_env(:fermix_channels, :drafty_channel, streaming: "draft")
      Application.put_env(:fermix_channels, :plain_channel, streaming: "draft")

      on_exit(fn ->
        Application.delete_env(:fermix_channels, :channel_registry)
        Application.delete_env(:fermix_channels, :drafty_channel)
        Application.delete_env(:fermix_channels, :plain_channel)
      end)

      report = Doctor.streaming_config_report()

      assert %{
               channel: :drafty_channel,
               name: "drafty",
               streaming: "draft",
               capability: :draft_edit
             } in report

      assert %{
               channel: :plain_channel,
               name: "plain",
               streaming: "draft",
               capability: :none
             } in report

      refute Enum.any?(report, &(&1.channel == :unconfigured_channel))
    end
  end

  describe "network errors" do
    test "returns network error tuple on transport failure" do
      put_provider(:openai, api_key: "sk-test")

      adapter = fn req ->
        {req, %Req.TransportError{reason: :econnrefused}}
      end

      assert {:error, {:network, %Req.TransportError{reason: :econnrefused}}} =
               Doctor.probe_provider(:openai, req_options: [adapter: adapter])
    end

    test "provider probes cap inherited request timeouts" do
      put_provider(:openai, api_key: "sk-test")
      test_pid = self()

      adapter = fn req ->
        send(test_pid, {:probe_timeout, req.options[:receive_timeout]})
        {req, %Req.Response{status: 200, body: %{}}}
      end

      assert {:ok, %{provider: :openai}} =
               Doctor.probe_provider(:openai,
                 req_options: [adapter: adapter, receive_timeout: 60_000]
               )

      assert_received {:probe_timeout, 5_000}
    end
  end

  describe "web_search_report/1" do
    test "offline reports the duckduckgo default with no credential required" do
      put_web_search([])

      report = Doctor.web_search_report()

      assert report.backend == :duckduckgo
      assert report.credential_present? == true
      refute Map.has_key?(report, :probe_result)
    end

    test "offline reports a keyed backend credential as present when set" do
      put_web_search(backend: :tavily, tavily_api_key: "tvly-secret")

      assert %{backend: :tavily, credential_present?: true} = Doctor.web_search_report()
    end

    test "offline reports a keyed backend credential as missing without a key" do
      put_web_search(backend: :tavily)

      assert %{backend: :tavily, credential_present?: false} = Doctor.web_search_report()
    end

    test "offline never reaches the network" do
      id = unique_plug(self())
      put_web_search(backend: :tavily, tavily_api_key: "tvly-secret")

      Doctor.web_search_report(
        req_options: [plug: {Req.Test, id}],
        net_resolver: public_resolver()
      )

      refute_received :web_search_probe_request
    end

    test "--full runs a live probe for the keyless backend" do
      id = stub_duckduckgo()
      put_web_search([])

      report =
        Doctor.web_search_report(
          full: true,
          req_options: [plug: {Req.Test, id}],
          net_resolver: public_resolver()
        )

      assert report.backend == :duckduckgo
      assert report.credential_present? == true
      assert report.probe_result == :ok
      assert report.result_count == 1
    end

    test "--full maps a keyed backend auth failure to :auth_failed" do
      id = stub_status(401)
      put_web_search(backend: :tavily, tavily_api_key: "tvly-secret")

      report =
        Doctor.web_search_report(
          full: true,
          req_options: [plug: {Req.Test, id}],
          net_resolver: public_resolver()
        )

      assert report.probe_result == :auth_failed
      assert report.result_count == 0
    end

    test "--full skips the probe when the credential is missing" do
      id = unique_plug(self())
      put_web_search(backend: :tavily)

      report =
        Doctor.web_search_report(
          full: true,
          req_options: [plug: {Req.Test, id}],
          net_resolver: public_resolver()
        )

      assert report.credential_present? == false
      refute Map.has_key?(report, :probe_result)
      refute_received :web_search_probe_request
    end

    test "--full maps a probe network failure to :network without crashing" do
      id = stub_status(200)
      put_web_search(backend: :tavily, tavily_api_key: "tvly-secret")

      report =
        Doctor.web_search_report(
          full: true,
          req_options: [plug: {Req.Test, id}],
          net_resolver: private_resolver()
        )

      assert report.probe_result == :network
      assert report.result_count == 0
    end
  end

  describe "image_report/1 (M15)" do
    test "reports :unconfigured when no generate_image block is set" do
      Application.put_env(:fermix_core, :tools, [])

      assert %{status: :unconfigured} = Doctor.image_report()
    end

    test "reports the configured backend with a present credential (google)" do
      put_generate_image(backend: "google", google_api_key: "gm-secret")

      assert %{status: :configured, backend: :google_image, credential_present?: true} =
               Doctor.image_report()
    end

    test "reports a missing credential without crashing (google)" do
      put_generate_image(backend: "google")

      assert %{status: :configured, backend: :google_image, credential_present?: false} =
               Doctor.image_report()
    end

    test "reuses the openai provider key through the api_key seam (openai)" do
      put_generate_image(backend: "openai", api_key: "sk-image")

      assert %{status: :configured, backend: :openai_image, credential_present?: true} =
               Doctor.image_report()
    end

    test "reports an unknown backend as a config error" do
      put_generate_image(backend: "midjourney")

      assert %{status: :error, error: error} = Doctor.image_report()
      assert error =~ "Unknown"
    end

    test "reports a missing backend selection as a config error" do
      put_generate_image(model: "gpt-image-2")

      assert %{status: :error, error: error} = Doctor.image_report()
      assert error =~ "no configured backend"
    end

    test "never reaches the network (offline credential check only)" do
      put_generate_image(backend: "openai", api_key: "sk-image")

      Doctor.image_report()

      refute_received :web_search_probe_request
    end
  end

  defp put_web_search(config) do
    Application.put_env(:fermix_core, :tools, web_search: config)
  end

  defp put_generate_image(config) do
    Application.put_env(:fermix_core, :tools, generate_image: config)
  end

  defp private_resolver do
    fn "api.tavily.com" -> {:ok, [{10, 0, 0, 1}]} end
  end

  defp unique_plug(test_pid) do
    id = :"web_search_probe_#{System.unique_integer([:positive])}"

    Req.Test.stub(id, fn conn ->
      send(test_pid, :web_search_probe_request)
      Plug.Conn.send_resp(conn, 200, "{}")
    end)

    id
  end

  defp stub_status(status) do
    id = :"web_search_status_#{System.unique_integer([:positive])}"

    Req.Test.stub(id, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, "{}")
    end)

    id
  end

  defp stub_duckduckgo do
    id = :"web_search_ddg_#{System.unique_integer([:positive])}"

    Req.Test.stub(id, fn conn ->
      Plug.Conn.send_resp(conn, 200, ddg_fixture())
    end)

    id
  end

  defp ddg_fixture do
    """
    <html><body>
      <div class="result">
        <h2 class="result__title">
          <a class="result__a" href="https://example.com/fermix">Fermix</a>
        </h2>
        <a class="result__snippet">Elixir agent platform.</a>
      </div>
    </body></html>
    """
  end

  defp public_resolver do
    fn
      "api.tavily.com" -> {:ok, [{93, 184, 216, 34}]}
      "html.duckduckgo.com" -> {:ok, [{52, 149, 246, 39}]}
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  describe "stale_token_profiles/0" do
    setup do
      previous_home = System.get_env("FERMIX_HOME")
      home = FermixTestSupport.SafeRm.make_tmp_dir!("doctor-stale-tokens")
      System.put_env("FERMIX_HOME", home)

      on_exit(fn ->
        case previous_home do
          nil -> System.delete_env("FERMIX_HOME")
          value -> System.put_env("FERMIX_HOME", value)
        end

        FermixTestSupport.SafeRm.rm_rf!(home)
      end)

      %{home: home}
    end

    test "returns only the stale profile names, sorted" do
      :ok = Store.write("xai_oauth", token_entry(-7200))
      :ok = Store.write(:openai_codex, token_entry(-7200))
      :ok = Store.write("gmail:primary", token_entry(3600))

      assert {:ok, ["openai_codex", "xai_oauth"]} = Doctor.stale_token_profiles()
    end

    test "propagates a read error instead of swallowing it", %{home: home} do
      File.write!(Path.join(home, "auth.json"), "{ not json")

      assert {:error, {:invalid_json, _}} = Doctor.stale_token_profiles()
    end
  end

  defp token_entry(expires_in_seconds) do
    %{
      auth_mode: "oauth2",
      provider: "google",
      tokens: %{access_token: "at", refresh_token: "rt"},
      expires_at: DateTime.add(DateTime.utc_now(), expires_in_seconds, :second),
      last_refresh: nil,
      status: "ready"
    }
  end
end
