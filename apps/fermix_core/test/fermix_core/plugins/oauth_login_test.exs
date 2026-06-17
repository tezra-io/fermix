defmodule FermixCore.Plugins.OAuthLoginTest do
  use ExUnit.Case, async: false

  alias FermixCore.Auth.OAuthFlow
  alias FermixCore.Auth.OAuthProviders
  alias FermixCore.Auth.Store
  alias FermixCore.Auth.TokenSupervisor
  alias FermixCore.Plugins.Auth
  alias FermixCore.Plugins.Dist.Store, as: DistStore

  setup do
    home = FermixTestSupport.SafeRm.make_tmp_dir!("plugin-oauth")
    old_home = System.get_env("FERMIX_HOME")
    plugins = Application.get_env(:fermix_core, :plugins, [])
    oauth = Application.get_env(:fermix_core, :oauth, %{})

    System.put_env("FERMIX_HOME", home)

    Application.put_env(:fermix_core, :oauth, %{
      "google" => [
        client_type: "desktop_public_pkce",
        client_id: "123.apps.googleusercontent.com",
        client_secret: "desktop-secret",
        redirect_host: "127.0.0.1"
      ]
    })

    Application.put_env(:fermix_core, :plugins, [])
    TokenSupervisor.stop_profile("google_calendar:primary")

    on_exit(fn ->
      TokenSupervisor.stop_profile("google_calendar:primary")

      case old_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      Application.put_env(:fermix_core, :plugins, plugins)
      Application.put_env(:fermix_core, :oauth, oauth)
      FermixTestSupport.SafeRm.rm_rf!(home)
    end)

    :ok
  end

  test "runs Google loopback OAuth, persists v2 metadata, and enables the plugin" do
    port = pick_free_port()
    parent = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(body)
      send(parent, {:token_request, params})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "access_token" => "google_at",
          "refresh_token" => "google_rt",
          "expires_in" => 3600,
          "scope" => "openid email profile https://www.googleapis.com/auth/calendar.readonly"
        })
      )
    end

    userinfo_plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{"sub" => "google-sub", "email" => "suj@example.com", "name" => "Suj"})
      )
    end

    opener = fn url ->
      send(parent, {:opened, url})

      Task.start(fn ->
        state =
          url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")

        deliver_callback(port, "/auth/callback?code=AUTHCODE&state=#{state}")
      end)

      :ok
    end

    assert {:ok, entry} =
             Auth.login("google_calendar",
               port: port,
               opener: opener,
               timeout_ms: 5_000,
               req_options: [plug: plug],
               userinfo_req_options: [plug: userinfo_plug],
               puts: fn _ -> :ok end
             )

    assert entry.provider == "google"
    assert entry.account.email == "suj@example.com"

    assert {:ok, stored} = Store.read("google_calendar:primary")
    assert stored.tokens.access_token == "google_at"
    assert stored.tokens.refresh_token == "google_rt"

    assert stored.granted_scopes == [
             "openid",
             "email",
             "profile",
             "https://www.googleapis.com/auth/calendar.readonly"
           ]

    assert stored.status == "ready"

    plugins = Application.get_env(:fermix_core, :plugins)
    assert Keyword.get(plugins, :enabled) == ["google_calendar"]

    assert_received {:opened, url}
    assert URI.decode_query(URI.parse(url).query)["client_id"] == "123.apps.googleusercontent.com"
    assert_received {:token_request, params}
    assert params["client_secret"] == "desktop-secret"
    assert params["redirect_uri"] == "http://127.0.0.1:#{port}/auth/callback"
  end

  test "missing Google client config returns needs_client_config" do
    Application.put_env(:fermix_core, :oauth, %{})

    assert {:error, :needs_client_config} =
             Auth.login("google_calendar")
  end

  test "Google OAuth login requires the desktop secret" do
    Application.put_env(:fermix_core, :oauth, %{
      "google" => [client_id: "123.apps.googleusercontent.com"]
    })

    assert {:error, :needs_client_config} =
             Auth.login("google_calendar")
  end

  test "userinfo failure does not discard minted OAuth tokens" do
    port = pick_free_port()
    parent = self()

    token_plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "access_token" => "google_at",
          "refresh_token" => "google_rt",
          "expires_in" => 3600,
          "scope" => "openid email profile https://www.googleapis.com/auth/calendar.readonly"
        })
      )
    end

    userinfo_plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(500, Jason.encode!(%{"error" => "temporary"}))
    end

    opener = fn url ->
      Task.start(fn ->
        state =
          url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")

        deliver_callback(port, "/auth/callback?code=AUTHCODE&state=#{state}")
      end)

      send(parent, :opened)
      :ok
    end

    assert {:ok, entry} =
             Auth.login("google_calendar",
               port: port,
               opener: opener,
               timeout_ms: 5_000,
               req_options: [plug: token_plug],
               userinfo_req_options: [plug: userinfo_plug],
               puts: fn _ -> :ok end
             )

    assert entry.account == nil
    assert {:ok, stored} = Store.read("google_calendar:primary")
    assert stored.tokens.access_token == "google_at"
    assert_received :opened
  end

  test "Google OAuth prints the URL and still waits when browser launch fails" do
    port = pick_free_port()
    parent = self()

    {:ok, provider} =
      OAuthProviders.definition("google",
        client_id: "123.apps.googleusercontent.com",
        client_secret: "desktop-secret",
        redirect_port: port,
        scopes: ["openid", "email", "profile"]
      )

    token_plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "access_token" => "fallback_at",
          "refresh_token" => "fallback_rt",
          "expires_in" => 3600,
          "scope" => "openid email profile"
        })
      )
    end

    userinfo_plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"sub" => "google-sub"}))
    end

    opener = fn url ->
      send(parent, {:opened, url})

      Task.start(fn ->
        state =
          url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")

        deliver_callback(port, "/auth/callback?code=AUTHCODE&state=#{state}")
      end)

      {:error, :browser_missing}
    end

    assert {:ok, tokens} =
             OAuthFlow.start_loopback(provider,
               opener: opener,
               timeout_ms: 5_000,
               req_options: [plug: token_plug],
               userinfo_req_options: [plug: userinfo_plug],
               puts: fn message -> send(parent, {:printed, message}) end
             )

    assert tokens.access_token == "fallback_at"
    assert_received {:opened, _url}
    assert_received {:printed, "Open this URL" <> _}
  end

  test "Google OAuth falls back when the preferred loopback port is taken" do
    preferred_port = pick_free_port()
    {:ok, blocker} = :gen_tcp.listen(preferred_port, [:binary, ip: {127, 0, 0, 1}])

    parent = self()

    {:ok, provider} =
      OAuthProviders.definition("google",
        client_id: "123.apps.googleusercontent.com",
        client_secret: "desktop-secret",
        redirect_port: preferred_port,
        scopes: ["openid", "email", "profile"]
      )

    token_plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "access_token" => "fallback_port_at",
          "expires_in" => 3600,
          "scope" => "openid email profile"
        })
      )
    end

    userinfo_plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"sub" => "google-sub"}))
    end

    opener = fn url ->
      query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      state = Map.fetch!(query, "state")
      actual_port = query["redirect_uri"] |> URI.parse() |> Map.fetch!(:port)

      send(parent, {:actual_port, actual_port})

      Task.start(fn ->
        deliver_callback(actual_port, "/auth/callback?code=AUTHCODE&state=#{state}")
      end)

      :ok
    end

    assert {:ok, tokens} =
             OAuthFlow.start_loopback(provider,
               opener: opener,
               timeout_ms: 5_000,
               req_options: [plug: token_plug],
               userinfo_req_options: [plug: userinfo_plug],
               puts: fn _ -> :ok end
             )

    assert tokens.access_token == "fallback_port_at"
    assert_received {:actual_port, actual_port}
    assert actual_port != preferred_port

    :gen_tcp.close(blocker)
  end

  test "GitHub login splits the comma-separated granted scopes" do
    install_github_fixture()
    TokenSupervisor.stop_profile("github:primary")
    on_exit(fn -> TokenSupervisor.stop_profile("github:primary") end)

    Application.put_env(:fermix_core, :oauth, %{
      "github" => [
        client_type: "desktop_public_pkce",
        client_id: "gh-client-id",
        client_secret: "gh-client-secret"
      ]
    })

    port = pick_free_port()
    parent = self()

    token_plug = fn conn ->
      send(parent, {:accept_header, Plug.Conn.get_req_header(conn, "accept")})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{"access_token" => "gh_at", "scope" => "repo,read:user"})
      )
    end

    userinfo_plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"name" => "Suj"}))
    end

    opener = fn url ->
      Task.start(fn ->
        state =
          url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")

        deliver_callback(port, "/auth/callback?code=AUTHCODE&state=#{state}")
      end)

      :ok
    end

    assert {:ok, entry} =
             Auth.login("github",
               port: port,
               opener: opener,
               timeout_ms: 5_000,
               req_options: [plug: token_plug],
               userinfo_req_options: [plug: userinfo_plug],
               puts: fn _ -> :ok end
             )

    assert entry.provider == "github"
    assert entry.granted_scopes == ["repo", "read:user"]

    assert {:ok, stored} = Store.read("github:primary")
    assert stored.tokens.access_token == "gh_at"
    assert stored.granted_scopes == ["repo", "read:user"]

    assert_received {:accept_header, ["application/json"]}
  end

  test "Notion's fixed redirect port fails loud when the port is taken" do
    port = pick_free_port()
    {:ok, blocker} = :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}])

    {:ok, provider} =
      OAuthProviders.definition("notion",
        client_id: "n-id",
        client_secret: "n-sec",
        redirect_port: port,
        scopes: []
      )

    assert {:error, {:port_in_use, ^port}} =
             OAuthFlow.start_loopback(provider,
               opener: fn _url -> :ok end,
               timeout_ms: 1_000,
               puts: fn _ -> :ok end
             )

    :gen_tcp.close(blocker)
  end

  # A ready installed plugin under FERMIX_HOME/plugins — the exact tree
  # Installer.run_install/2 leaves behind (registry_union_test pattern).
  defp install_github_fixture do
    root = Path.join(System.fetch_env!("FERMIX_HOME"), "plugins")
    DistStore.ensure!(root)
    dir = DistStore.version_dir(root, "github", "1.0.0")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "plugin.json"), Jason.encode!(github_manifest()))
    :ok = DistStore.activate(root, "github", "1.0.0")

    :ok =
      DistStore.record(root, "github", %{
        "version" => "1.0.0",
        "sha256" => String.duplicate("0", 64),
        "h1" => String.duplicate("0", 64),
        "plugin_api" => 2,
        "min_core_version" => "0.1.0"
      })
  end

  defp github_manifest do
    %{
      "schema_version" => 2,
      "name" => "github",
      "display_name" => "GitHub",
      "description" => "GitHub issues and pull requests",
      "category" => "developer",
      "version" => "1.0.0",
      "min_core_version" => "0.1.0",
      "plugin_api" => 2,
      "auth" => %{
        "type" => "oauth2",
        "provider" => "github",
        "profile_key" => "github",
        "account_mode" => "single",
        "scopes" => ["read:user", "repo"]
      },
      "health_check" => %{"kind" => "local_readiness", "requires_auth" => true},
      "tools" => [],
      "skills" => []
    }
  end

  defp pick_free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp deliver_callback(port, path) do
    {:ok, conn} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    request = "GET #{path} HTTP/1.1\r\nHost: localhost:#{port}\r\nConnection: close\r\n\r\n"
    :ok = :gen_tcp.send(conn, request)
    {:ok, _resp} = :gen_tcp.recv(conn, 0, 5_000)
    :gen_tcp.close(conn)
  end
end
