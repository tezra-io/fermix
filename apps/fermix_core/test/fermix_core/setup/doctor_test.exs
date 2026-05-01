defmodule FermixCore.Setup.DoctorTest do
  use ExUnit.Case, async: false

  alias FermixCore.Setup.Doctor

  setup do
    original_providers = Application.get_env(:fermix_core, :providers, [])
    original_agent = Application.get_env(:fermix_core, :agent, [])

    on_exit(fn ->
      Application.put_env(:fermix_core, :providers, original_providers)
      Application.put_env(:fermix_core, :agent, original_agent)
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

    test "uses TokenManager bearer when auth_mode is :oauth" do
      put_provider(:openai, auth_mode: :oauth, default_model: "gpt-5.5")
      {:ok, server} = GenServer.start_link(__MODULE__.TokenStub, "oauth-bearer-xyz")

      plug = fn conn ->
        assert ["Bearer oauth-bearer-xyz"] = Plug.Conn.get_req_header(conn, "authorization")
        Plug.Conn.send_resp(conn, 200, "{}")
      end

      assert {:ok, %{provider: :openai, model: "gpt-5.5"}} =
               Doctor.probe_provider(:openai,
                 req_options: [plug: plug],
                 token_server: server
               )

      GenServer.stop(server)
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
    test "uses bearer token from injected token_server" do
      put_provider(:openai_codex, default_model: "gpt-5.5")
      {:ok, server} = GenServer.start_link(__MODULE__.TokenStub, "oauth-bearer-xyz")

      plug = fn conn ->
        assert ["Bearer oauth-bearer-xyz"] = Plug.Conn.get_req_header(conn, "authorization")
        assert ["responses=experimental"] = Plug.Conn.get_req_header(conn, "openai-beta")
        assert ["pi"] = Plug.Conn.get_req_header(conn, "originator")
        Plug.Conn.send_resp(conn, 200, "{}")
      end

      assert {:ok, %{provider: :openai_codex, model: "gpt-5.5"}} =
               Doctor.probe_provider(:openai_codex,
                 req_options: [plug: plug],
                 token_server: server
               )

      GenServer.stop(server)
    end

    test "returns misconfigured when token_server has no token" do
      put_provider(:openai_codex, default_model: "gpt-5.5")
      {:ok, server} = GenServer.start_link(__MODULE__.TokenStub, :no_token)

      assert {:error, {:misconfigured, message}} =
               Doctor.probe_provider(:openai_codex, token_server: server)

      assert message =~ "Codex token"
      GenServer.stop(server)
    end

    test "returns auth_scope_mismatch on 401 with codex-specific hint" do
      put_provider(:openai_codex, default_model: "gpt-5.5")
      {:ok, server} = GenServer.start_link(__MODULE__.TokenStub, "oauth-stale")

      plug = fn conn -> Plug.Conn.send_resp(conn, 401, "unauthorized") end

      assert {:error, {:auth_scope_mismatch, surface, hint}} =
               Doctor.probe_provider(:openai_codex,
                 req_options: [plug: plug],
                 token_server: server
               )

      assert surface =~ "Codex"
      assert hint =~ "fermix setup --import-codex"
      GenServer.stop(server)
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

  describe "network errors" do
    test "returns network error tuple on transport failure" do
      put_provider(:openai, api_key: "sk-test")

      adapter = fn req ->
        {req, %Req.TransportError{reason: :econnrefused}}
      end

      assert {:error, {:network, %Req.TransportError{reason: :econnrefused}}} =
               Doctor.probe_provider(:openai, req_options: [adapter: adapter])
    end
  end

  defmodule TokenStub do
    use GenServer

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:get_token, _from, "oauth-bearer-xyz" = state),
      do: {:reply, {:ok, state}, state}

    def handle_call(:get_token, _from, "oauth-stale" = state),
      do: {:reply, {:ok, state}, state}

    def handle_call(:get_token, _from, :no_token = state),
      do: {:reply, {:error, :no_token}, state}
  end
end
