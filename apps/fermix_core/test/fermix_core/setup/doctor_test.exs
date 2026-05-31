defmodule FermixCore.Setup.DoctorTest do
  use ExUnit.Case, async: false

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

  defp put_web_search(config) do
    Application.put_env(:fermix_core, :tools, web_search: config)
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
end
