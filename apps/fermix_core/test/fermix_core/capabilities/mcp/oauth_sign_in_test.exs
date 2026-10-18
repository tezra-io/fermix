defmodule FermixCore.Capabilities.MCP.OAuthSignInTest do
  @moduledoc """
  The sign-in of an MCP server the owner added (M74 E5), end to end over real
  sockets: `auth.start mcp:<name>` against a loopback authorization server
  and the MCP server it protects (`LoopbackOAuth`), through discovery,
  registration, the browser (driven by the test), the exchange and the grant,
  to the server started by `MCP.Supervisor` with the grant's token; then the
  grant's life on the rail: refreshed before it expires and once on a `401`,
  expired when a refresh is refused, more scopes kept on `403
  insufficient_scope`, refused when the server names another issuer, and
  forgotten by `auth.logout` and by removing the server.

  The home, the secret store (the stub), the status table, the registries and
  the job registry are the case's own; the supervisor is a second
  `MCP.Supervisor` beside the application's, reached through `Restarter`.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.Auth.Store
  alias FermixCore.Capabilities.MCP.Config, as: McpConfig
  alias FermixCore.Capabilities.MCP.Naming
  alias FermixCore.Capabilities.MCP.OAuth.Grant
  alias FermixCore.Capabilities.MCP.OAuth.Registration
  alias FermixCore.Capabilities.MCP.Remote.Owner
  alias FermixCore.Capabilities.MCP.RuntimeStatus
  alias FermixCore.Capabilities.MCP.Secrets, as: McpSecrets
  alias FermixCore.Capabilities.MCP.Supervisor, as: McpSupervisor
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Management.Auth
  alias FermixCore.Management.Jobs
  alias FermixCore.Management.McpServers
  alias FermixCore.Management.Settings
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.RestartState
  alias FermixTestSupport.LoopbackOAuth
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.SecretWriterStub

  @bound_ms 30_000
  @server "linear"
  @source {:operator, @server}
  @tools ["mcp_linear_echo", "mcp_linear_admin"]

  defmodule Restarter do
    @moduledoc false

    alias FermixCore.Capabilities.MCP.Supervisor, as: McpSupervisor

    def supervisor, do: :mcp_oauth_sign_in_supervisor

    def opts do
      [
        mcp_registry: :mcp_oauth_sign_in_registry,
        capability_registry: :mcp_oauth_sign_in_capabilities,
        runtime_status: :mcp_oauth_sign_in_status
      ]
    end

    def reload, do: McpSupervisor.reload(supervisor(), opts())

    def restart_server(source_id, spec),
      do: McpSupervisor.restart_server(supervisor(), source_id, spec, opts())

    def stop_server(source_id), do: McpSupervisor.stop_server(supervisor(), source_id, opts())
    def subtree_alive?(source_id), do: McpSupervisor.subtree_alive?(supervisor(), source_id)
  end

  @supervisor Restarter.supervisor()
  @opts Restarter.opts()

  setup do
    home = System.get_env("FERMIX_HOME")

    core =
      Map.new(
        [:secret_writer, :profile, :mcp_servers],
        &{&1, Application.get_env(:fermix_core, &1)}
      )

    Application.put_env(:fermix_core, :secret_writer, SecretWriterStub)
    Application.delete_env(:fermix_core, :profile)
    SecretWriterStub.reset()

    tmp = SafeRm.make_tmp_dir!("mcp_oauth_sign_in_home")
    System.put_env("FERMIX_HOME", tmp)

    start_supervised!({RuntimeStatus, name: @opts[:runtime_status]})
    start_supervised!({CapabilityRegistry, name: @opts[:capability_registry]})
    tasks = :"mcp_oauth_sign_in_tasks_#{System.unique_integer([:positive])}"
    start_supervised!({Task.Supervisor, name: tasks})
    jobs = start_supervised!({Jobs, name: :mcp_oauth_sign_in_jobs, task_supervisor: tasks})

    on_exit(fn ->
      Enum.each(core, fn {key, value} -> restore(key, value) end)
      SecretWriterStub.reset()
      Enum.each(@tools, &Naming.unregister/1)
      restore_home(home)
      SafeRm.rm_rf!(tmp)
      :ok = RestartState.record_persisted_baseline()
    end)

    %{home: tmp, jobs: jobs}
  end

  describe "a sign-in" do
    test "discovers, registers, signs in with PKCE and the resource, stores the grant and starts the server once",
         ctx do
      as = LoopbackOAuth.start(%{challenge_scope: "mcp:read mcp:write"})
      configure!(ctx, as.url)
      assert await_status({:reauthorization_required, :sign_in_required})

      row = row!(ctx)
      assert row["status"] == "needs_sign_in"
      assert row["auth"]["state"] == "signed_out"
      assert {row["primary_action"], row["actions"]} == {"sign_in", ["sign_in", "disable"]}

      log =
        capture_log(fn ->
          assert {:ok, view} = Auth.start("mcp:#{@server}", auth_opts(ctx))
          assert %{"kind" => "auth", "status" => "running", "phase" => "awaiting_browser"} = view
          assert view["expires_in_ms"] == 300_000
          assert {:ok, _page} = LoopbackOAuth.browse(view["authorize_url"])

          assert {:ok, %{"status" => "completed", "result" => result}} =
                   eventually_terminal(ctx.jobs, view["job_id"])

          assert result == %{"account_label" => "127.0.0.1"}
          assert await_ready()
        end)

      state = LoopbackOAuth.state(as)
      assert state.registrations == 1
      assert [authorize] = state.authorize_requests
      assert authorize["client_id"] == "dcr-client-1"
      assert authorize["code_challenge_method"] == "S256"
      assert authorize["resource"] == as.url
      assert authorize["scope"] == "mcp:read mcp:write"
      assert authorize["redirect_uri"] =~ ~r{\Ahttp://127\.0\.0\.1:\d+/callback\z}

      assert [exchange] = state.token_requests
      assert exchange["grant_type"] == "authorization_code"
      assert exchange["resource"] == as.url
      assert is_binary(exchange["code_verifier"])

      # What the registration sent is Fermix's own metadata, `native` included,
      # naming the exact redirect the sign-in used, port and all.
      assert state.registered["dcr-client-1"] ==
               Registration.document()
               |> Map.delete("client_id")
               |> Map.put("redirect_uris", [authorize["redirect_uri"]])

      # The server was started once more, by the sign-in, with the token: the
      # start before it and the discovery's probe sent none.
      [access] = Map.keys(state.access)
      assert Enum.map(initializes(as), &bearer/1) == [nil, nil, access]

      row = row!(ctx)
      assert row["status"] == "connected"
      assert row["auth"] == auth_row("signed_in", "127.0.0.1", as.base)
      assert {row["primary_action"], row["actions"]} == {nil, ["sign_out", "check", "disable"]}

      # The token is in the auth store alone: not in config.toml, not logged.
      refute File.read!(Path.join(ctx.home, "config.toml")) =~ access
      assert File.read!(Path.join(ctx.home, "auth.json")) =~ access
      refute log =~ access
      refute log =~ "refresh-"
    end

    test "uses Fermix's Client ID Metadata Document where the server advertises it", ctx do
      as = LoopbackOAuth.start(%{cimd: true})
      configure!(ctx, as.url)
      assert :ok = sign_in!(ctx)

      state = LoopbackOAuth.state(as)
      assert state.registrations == 0

      assert [%{"client_id" => "https://fermix.ai/oauth/mcp-client.json"}] =
               state.authorize_requests

      assert [%{"client_id" => "https://fermix.ai/oauth/mcp-client.json"}] = state.token_requests
    end

    test "names the account from the ID token, else from userinfo, else by the issuer's host",
         ctx do
      claims = %{"preferred_username" => "owner", "email" => "owner@example.com"}
      as = LoopbackOAuth.start(%{id_token: unsigned_jwt(claims), userinfo: %{"name" => "Other"}})
      configure!(ctx, as.url)

      assert :ok = sign_in!(ctx)
      assert row!(ctx)["auth"]["account_label"] == "owner@example.com"

      LoopbackOAuth.configure(as, %{id_token: nil, userinfo: %{"preferred_username" => "owner"}})
      assert :ok = sign_in!(ctx)
      assert row!(ctx)["auth"]["account_label"] == "owner"

      LoopbackOAuth.configure(as, %{userinfo: nil})
      assert :ok = sign_in!(ctx)
      assert row!(ctx)["auth"]["account_label"] == "127.0.0.1"
    end

    # The double holds a registered client to the redirect URIs it registered,
    # matched exactly, as some authorization servers do.
    test "registers its exact redirect, and uses the client and its port again for the next sign-in to its issuer",
         ctx do
      as = LoopbackOAuth.start()
      configure!(ctx, as.url)
      assert :ok = sign_in!(ctx)
      assert :ok = sign_in!(ctx)

      state = LoopbackOAuth.state(as)
      assert state.registrations == 1
      assert [first, second] = state.authorize_requests
      assert {first["client_id"], second["client_id"]} == {"dcr-client-1", "dcr-client-1"}
      assert second["redirect_uri"] == first["redirect_uri"]
      assert state.registered["dcr-client-1"]["redirect_uris"] == [first["redirect_uri"]]
      assert {:ok, %{mcp: %{redirect_port: port}}} = Grant.read(@server)
      assert first["redirect_uri"] == "http://127.0.0.1:#{port}/callback"

      # Signed out, the client and its port stay for the next sign-in.
      assert {:ok, _restart} = Auth.logout("mcp:#{@server}", auth_opts(ctx))
      assert :ok = sign_in!(ctx)
      assert LoopbackOAuth.state(as).registrations == 1

      assert List.last(LoopbackOAuth.state(as).authorize_requests)["redirect_uri"] ==
               first["redirect_uri"]
    end

    test "registers again, for the port it binds, when the kept port is taken, and keeps that",
         ctx do
      as = LoopbackOAuth.start()
      configure!(ctx, as.url)
      assert :ok = sign_in!(ctx)
      {:ok, %{mcp: %{redirect_port: kept}}} = Grant.read(@server)

      {:ok, taken} =
        :gen_tcp.listen(kept, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

      try do
        assert :ok = sign_in!(ctx)
      after
        :gen_tcp.close(taken)
      end

      state = LoopbackOAuth.state(as)
      assert state.registrations == 2
      assert [_first, again] = state.authorize_requests
      assert again["client_id"] == "dcr-client-2"
      refute again["redirect_uri"] == "http://127.0.0.1:#{kept}/callback"
      assert state.registered["dcr-client-2"]["redirect_uris"] == [again["redirect_uri"]]

      assert {:ok, %{client_id: "dcr-client-2", mcp: %{redirect_port: port}}} =
               Grant.read(@server)

      assert again["redirect_uri"] == "http://127.0.0.1:#{port}/callback"
    end

    # A client ID with no stored secret is a pre-registered public client: its
    # server starts, and its sign-in authenticates with the id alone.
    test "uses a client ID with no stored secret as a public client", ctx do
      as = LoopbackOAuth.start(%{owner_clients: %{"public-client" => nil}})
      configure!(ctx, as.url, ~s(oauth_client_id = "public-client"))

      assert await_status({:reauthorization_required, :sign_in_required})
      refute row!(ctx)["status"] == "needs_secret"

      assert row!(ctx)["oauth_client"] == %{
               "client_id" => "public-client",
               "secret_present" => false
             }

      assert :ok = sign_in!(ctx)
      assert [exchange] = LoopbackOAuth.state(as).token_requests
      assert exchange["authenticated_as"] == {:form, "public-client", nil}
    end

    test "uses the owner's client ID first, with its secret as the metadata allows", ctx do
      as = LoopbackOAuth.start(%{cimd: true, owner_clients: %{"owner-client" => "owner-secret"}})
      configure!(ctx, as.url, ~s(oauth_client_id = "owner-client"))
      :ok = McpSecrets.put(@server, :client_secret, "owner-secret")
      assert :ok = sign_in!(ctx)

      state = LoopbackOAuth.state(as)
      assert state.registrations == 0
      assert [%{"client_id" => "owner-client"}] = state.authorize_requests
      assert [exchange] = state.token_requests
      assert exchange["authenticated_as"] == {:basic, "owner-client", "owner-secret"}
      refute Map.has_key?(exchange, "client_secret")
    end

    test "refuses an iss that is not the issuer, and a missing one only where it was promised",
         ctx do
      as = LoopbackOAuth.start(%{iss: :wrong})
      configure!(ctx, as.url)

      assert {:failed, "The sign-in reply came from another service, so Fermix did not use it."} =
               sign_in(ctx)

      assert LoopbackOAuth.state(as).token_requests == []

      LoopbackOAuth.configure(as, %{iss: :absent, iss_supported: true})

      assert {:failed,
              "The sign-in reply did not say which service sent it, so Fermix did not use it."} =
               sign_in(ctx)

      assert LoopbackOAuth.state(as).token_requests == []

      LoopbackOAuth.configure(as, %{iss: :absent, iss_supported: false})
      assert :ok = sign_in!(ctx)
    end

    test "is refused for a server that does not sign in by itself, with its reason", ctx do
      as = LoopbackOAuth.start()

      File.write!(Path.join(ctx.home, "config.toml"), """
      [mcp.servers.files]
      command = "/bin/sh"

      [mcp.servers.keyed]
      transport = "http"
      url = "#{as.url}"
      auth = "header"
      key_header = "Authorization"
      header_secrets = ["Authorization"]

      [mcp.servers.open]
      transport = "http"
      url = "#{as.url}"
      auth = "none"
      """)

      :ok = ConfigStore.apply_mcp_config()

      for {provider, sentence} <- [
            {"mcp:nothing", "There is no MCP server by that name."},
            {"mcp:files", "This server runs on this Mac and has no sign-in."},
            {"mcp:keyed", "This server signs in with a key, not a browser."},
            {"mcp:open", "This server is set to need no sign-in."}
          ] do
        assert {:error, {:invalid_params, "provider", ^sentence}} =
                 Auth.start(provider, auth_opts(ctx))
      end
    end
  end

  describe "the grant on the rail" do
    test "a token about to expire is refreshed before it is sent", ctx do
      as = LoopbackOAuth.start(%{token_ttl: 5})
      configure!(ctx, as.url)
      assert :ok = sign_in!(ctx)

      # The token the sign-in got was due at once, so the start refreshed it
      # before sending it.
      state = LoopbackOAuth.state(as)
      assert state.refreshes >= 1
      [%{"grant_type" => "authorization_code"} = exchange | refreshes] = state.token_requests

      assert Enum.all?(
               refreshes,
               &(&1["grant_type"] == "refresh_token" and &1["resource"] == as.url)
             )

      refute exchange["code"] == nil
      sent = initializes(as) |> List.last() |> bearer()
      assert Map.has_key?(state.access, sent)
      refute sent == "access-1"
    end

    test "a 401 is renewed once with a refresh, and the call sent again", ctx do
      as = LoopbackOAuth.start()
      configure!(ctx, as.url)
      assert :ok = sign_in!(ctx)

      :ok = LoopbackOAuth.revoke_access(as)
      assert {:ok, %{"content" => _content}} = Owner.call_tool(owner_pid(), "echo", %{}, 10_000)

      state = LoopbackOAuth.state(as)
      assert state.refreshes == 1
      assert {:ok, %{status: :ready}} = RuntimeStatus.fetch(@opts[:runtime_status], @source)
      assert row!(ctx)["auth"]["state"] == "signed_in"
    end

    test "a refused refresh leaves the grant expired and the server asking for a sign-in", ctx do
      as = LoopbackOAuth.start()
      configure!(ctx, as.url)
      assert :ok = sign_in!(ctx)

      LoopbackOAuth.configure(as, %{refuse_refresh: true})
      :ok = LoopbackOAuth.revoke_access(as)

      capture_log(fn ->
        assert {:error, {:reauthorization_required, :sign_in_required}} =
                 Owner.call_tool(owner_pid(), "echo", %{}, 10_000)

        assert await_status({:reauthorization_required, :sign_in_required})
      end)

      row = row!(ctx)
      assert row["status"] == "needs_sign_in"
      assert row["status_sentence"] == "Your sign-in has expired. Sign in again."
      assert row["auth"] == auth_row("expired", "127.0.0.1", as.base)
      assert {row["primary_action"], row["actions"]} == {"sign_in", ["sign_in", "disable"]}
      assert {:ok, %{status: "expired", tokens: %{access_token: nil}}} = Grant.read(@server)
    end

    test "keeps the scope a 403 insufficient_scope asks for, says so, and asks for it next time",
         ctx do
      as = LoopbackOAuth.start(%{challenge_scope: "mcp:read", required_scope: "mcp:admin"})
      configure!(ctx, as.url)
      assert :ok = sign_in!(ctx)

      assert {:error, {:insufficient_credential_scope, :scope}} =
               Owner.call_tool(owner_pid(), "admin", %{}, 10_000)

      row = row!(ctx)
      assert row["status"] == "connected"

      assert row["status_sentence"] ==
               "Connected. 2 tools. A tool asked for more access, so sign in again to allow it."

      assert {row["primary_action"], row["actions"]} ==
               {"sign_in", ["sign_in", "sign_out", "check", "disable"]}

      assert :ok = sign_in!(ctx)

      assert List.last(LoopbackOAuth.state(as).authorize_requests)["scope"] ==
               "mcp:read mcp:admin"

      assert {:ok, %{"content" => _content}} = Owner.call_tool(owner_pid(), "admin", %{}, 10_000)
      refute row!(ctx)["primary_action"]
    end

    test "is not sent again once the server names another issuer, and is deleted", ctx do
      as = LoopbackOAuth.start()
      configure!(ctx, as.url)
      assert :ok = sign_in!(ctx)

      other = LoopbackOAuth.start()
      LoopbackOAuth.configure(as, %{issuer: other.base})
      :ok = LoopbackOAuth.revoke_access(as)

      capture_log(fn ->
        assert {:error, {:reauthorization_required, :sign_in_required}} =
                 Owner.call_tool(owner_pid(), "echo", %{}, 10_000)

        assert await_status({:reauthorization_required, :sign_in_required})
      end)

      assert LoopbackOAuth.state(as).refreshes == 0
      assert LoopbackOAuth.state(other).token_requests == []
      assert {:ok, nil} = Grant.read(@server)

      row = row!(ctx)
      assert {row["status"], row["auth"]["state"]} == {"needs_sign_in", "signed_out"}
      assert row["status_sentence"] == "Sign in to finish connecting."
    end

    test "survives a restart of the server's subtree, and Auth.Store reads it back whole", ctx do
      as = LoopbackOAuth.start()
      configure!(ctx, as.url)
      assert :ok = sign_in!(ctx)
      {:ok, before} = Grant.read(@server)

      {:ok, server} = server_config()
      sent_before = length(initializes(as))
      {:ok, _pid} = Restarter.restart_server(@source, server)
      assert await_ready()

      assert [restarted] = Enum.drop(initializes(as), sent_before)
      assert bearer(restarted) == before.tokens.access_token

      assert {:ok, read_back} = Store.read("mcp:#{@server}")
      assert read_back.tokens == before.tokens
      assert read_back.client_id == "dcr-client-1"

      [authorize] = LoopbackOAuth.state(as).authorize_requests
      %URI{port: port} = URI.parse(authorize["redirect_uri"])

      assert read_back.mcp == %{
               issuer: as.base,
               resource: as.url,
               token_endpoint: as.base <> "/token",
               client_kind: "registered",
               token_auth: "none",
               client_secret: nil,
               redirect_port: port,
               scopes: ["mcp:read"],
               wanted_scopes: [],
               account_label: "127.0.0.1"
             }
    end

    test "is forgotten by auth.logout, which starts the server again without it", ctx do
      as = LoopbackOAuth.start(%{cimd: true})
      configure!(ctx, as.url)
      assert :ok = sign_in!(ctx)

      # The daemon's own restart state, to which a sign-out adds nothing.
      assert Auth.logout("mcp:#{@server}", auth_opts(ctx)) ==
               {:ok, %{"restart" => Settings.restart()}}

      assert {:ok, nil} = Grant.read(@server)
      assert await_status({:reauthorization_required, :sign_in_required})
      assert row!(ctx)["auth"]["state"] == "signed_out"
      refute List.keyfind(List.last(LoopbackOAuth.mcp_requests(as)).headers, "authorization", 0)
    end

    test "is deleted with its server", ctx do
      as = LoopbackOAuth.start()
      configure!(ctx, as.url)
      assert :ok = sign_in!(ctx)
      assert {:ok, %{}} = Grant.read(@server)

      assert {:ok, %{"removed" => true}} = McpServers.remove(@server, mcp_opts(ctx))
      assert {:ok, nil} = Grant.read(@server)
    end

    test "is not needed by a public server, which connects with no sign-in", ctx do
      as = LoopbackOAuth.start(%{protected: false})
      configure!(ctx, as.url)
      assert await_ready()

      for request <- LoopbackOAuth.mcp_requests(as) do
        refute List.keyfind(request.headers, "authorization", 0)
      end

      row = row!(ctx)
      assert {row["status"], row["auth"]["state"]} == {"connected", "not_needed"}
      assert row["actions"] == ["check", "disable"]
      assert LoopbackOAuth.state(as).authorize_requests == []
    end
  end

  # --- helpers ----------------------------------------------------------------

  defp configure!(ctx, url, extra \\ "") do
    File.write!(Path.join(ctx.home, "config.toml"), """
    [mcp.servers.#{@server}]
    transport = "http"
    url = "#{url}"
    #{extra}
    """)

    :ok = ConfigStore.apply_mcp_config()
    :ok = RestartState.record_persisted_baseline()
    start_supervised!({McpSupervisor, [name: @supervisor, servers: []] ++ @opts})
    {:ok, _summary} = Restarter.reload()
  end

  defp unsigned_jwt(claims) do
    [%{"alg" => "none"}, claims]
    |> Enum.map(&Base.url_encode64(JSON.encode!(&1), padding: false))
    |> Enum.join(".")
    |> Kernel.<>(".")
  end

  defp auth_opts(ctx), do: [jobs: [server: ctx.jobs], mcp_supervisor: Restarter]

  defp mcp_opts(_ctx), do: [mcp_supervisor: Restarter, runtime_status: @opts[:runtime_status]]

  defp row!(ctx) do
    {:ok, %{"server" => row}} = McpServers.get(@server, mcp_opts(ctx))
    row
  end

  defp auth_row(state, label, issuer) do
    %{
      "mode" => "auto",
      "state" => state,
      "key_header" => nil,
      "account_label" => label,
      "issuer" => issuer
    }
  end

  # One whole sign-in: the job, the browser, and the server ready after it.
  defp sign_in!(ctx) do
    case sign_in(ctx) do
      :ok -> if await_ready(), do: :ok, else: RuntimeStatus.fetch(@opts[:runtime_status], @source)
      other -> other
    end
  end

  defp sign_in(ctx) do
    {:ok, view} = Auth.start("mcp:#{@server}", auth_opts(ctx))
    {:ok, _page} = LoopbackOAuth.browse(view["authorize_url"])

    case eventually_terminal(ctx.jobs, view["job_id"]) do
      {:ok, %{"status" => "completed"}} ->
        :ok

      {:ok, %{"status" => "failed", "failure" => %{"sentence" => sentence}}} ->
        {:failed, sentence}
    end
  end

  # Every `initialize` the MCP endpoint was sent, the discovery's probe among them.
  defp initializes(as) do
    Enum.filter(LoopbackOAuth.mcp_requests(as), fn request ->
      request.method == "POST" and JSON.decode!(request.body)["method"] == "initialize"
    end)
  end

  defp bearer(request) do
    case List.keyfind(request.headers, "authorization", 0) do
      {"authorization", "Bearer " <> token} -> token
      nil -> nil
    end
  end

  defp server_config do
    case Enum.find(McpConfig.configured(), &(&1.name == @server)) do
      nil -> :error
      server -> {:ok, server}
    end
  end

  defp owner_pid do
    {:ok, owner, _generation} = RuntimeStatus.owner(@opts[:runtime_status], @source)
    owner
  end

  defp await_ready do
    eventually(fn ->
      match?(
        {:ok, %{status: :ready, discovery: %{tool_count: 2}}},
        RuntimeStatus.fetch(@opts[:runtime_status], @source)
      )
    end)
  end

  defp await_status({status, detail}) do
    eventually(fn ->
      match?(
        {:ok, %{status: ^status, detail: ^detail}},
        RuntimeStatus.fetch(@opts[:runtime_status], @source)
      )
    end)
  end

  defp eventually_terminal(jobs, job_id) do
    eventually(fn ->
      match?(
        {:ok, %{"status" => status}} when status != "running",
        Jobs.get(job_id, server: jobs)
      )
    end)

    Jobs.get(job_id, server: jobs)
  end

  defp eventually(fun) do
    deadline = System.monotonic_time(:millisecond) + @bound_ms
    poll(fun, deadline)
  end

  defp poll(fun, deadline) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> Process.sleep(20) && poll(fun, deadline)
    end
  end

  defp restore_home(nil), do: System.delete_env("FERMIX_HOME")
  defp restore_home(home), do: System.put_env("FERMIX_HOME", home)

  defp restore(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore(key, value), do: Application.put_env(:fermix_core, key, value)
end
