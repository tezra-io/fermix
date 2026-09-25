defmodule FermixCore.Plugins.OAuthLoginTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

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

    # Two separate callbacks, restoration registered FIRST so it runs LAST:
    # ExUnit wraps each registered on_exit on its own, so a `stop_profile` that
    # exits can no longer strand this module's tmp FERMIX_HOME and app env on
    # every later module in the VM.
    on_exit(fn ->
      case old_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      Application.put_env(:fermix_core, :plugins, plugins)
      Application.put_env(:fermix_core, :oauth, oauth)
      FermixTestSupport.SafeRm.rm_rf!(home)
    end)

    on_exit(fn -> TokenSupervisor.stop_profile("google_calendar:primary") end)

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

  # `fermix plugins auth login` runs without the supervision tree, so the save
  # that enables the plugin after the grant must keychain the sign-in client's
  # secret inline. The caller says so; the daemon's sign-ins say nothing.
  test "a tree-less sign-in enables the plugin with its keychain calls inline" do
    previous_writer = Application.get_env(:fermix_core, :secret_writer)
    Application.put_env(:fermix_core, :secret_writer, FermixTestSupport.TreeLessSecretWriter)
    :ok = FermixTestSupport.TreeLessSecretWriter.watch()

    on_exit(fn ->
      case previous_writer do
        nil -> Application.delete_env(:fermix_core, :secret_writer)
        writer -> Application.put_env(:fermix_core, :secret_writer, writer)
      end

      FermixTestSupport.SecretWriterStub.reset()
    end)

    port = pick_free_port()

    token_plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{"access_token" => "google_at", "refresh_token" => "google_rt"})
      )
    end

    opener = fn url ->
      Task.start(fn ->
        state =
          url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")

        deliver_callback(port, "/auth/callback?code=AUTHCODE&state=#{state}")
      end)

      :ok
    end

    assert {:ok, _entry} =
             Auth.login("google_calendar",
               supervised: false,
               port: port,
               opener: opener,
               timeout_ms: 5_000,
               req_options: [plug: token_plug],
               userinfo_req_options: [plug: fn conn -> Plug.Conn.send_resp(conn, 500, "") end],
               puts: fn _ -> :ok end
             )

    assert_received {:tree_less_keychain, :put, :google_oauth_client_secret}

    plugins = Application.get_env(:fermix_core, :plugins)
    assert Keyword.get(plugins, :enabled) == ["google_calendar"]
  end

  test "missing Google client config returns needs_client_config" do
    Application.put_env(:fermix_core, :oauth, %{})

    assert {:error, :needs_client_config} =
             Auth.login("google_calendar")
  end

  # A failed sign-in used to leave no trace: the event carried a bare `:error`
  # and nothing handled it. Every op now emits through one emitter, and the log
  # names the failure once. The fidelity half proves the diagnosis arrives; the
  # non-leak half proves the authorize url, the code, the tokens and the client
  # secret never do.
  describe "what a sign-in leaves behind" do
    # `Auth.login/2` runs in the test process, and so does the handler it
    # triggers: filtering on that pid keeps any other emitter out of the mailbox.
    setup do
      parent = self()
      handler = "oauth-login-test-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler,
          [:fermix, :plugin, :auth],
          fn _event, measurements, metadata, _config ->
            if self() == parent, do: send(parent, {:plugin_auth, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)
      :ok
    end

    defp login_through(token_plug) do
      port = pick_free_port()
      parent = self()

      opener = fn url ->
        send(parent, {:authorize_url, url})

        Task.start(fn ->
          state =
            url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")

          deliver_callback(port, "/auth/callback?code=AUTHCODE&state=#{state}")
        end)

        :ok
      end

      with_log(fn ->
        Auth.login("google_calendar",
          port: port,
          opener: opener,
          timeout_ms: 5_000,
          req_options: [plug: token_plug],
          userinfo_req_options: [plug: fn conn -> Plug.Conn.send_resp(conn, 500, "") end],
          puts: fn _ -> :ok end
        )
      end)
    end

    defp leaked(text, url) do
      Enum.filter([url, "AUTHCODE", "desktop-secret", "google_at", "google_rt"], &(text =~ &1))
    end

    test "a refused sign-in client is traced with its class and the vendor's words" do
      refusing = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          401,
          Jason.encode!(%{"error" => "invalid_client", "error_description" => "Unauthorized"})
        )
      end

      {result, log} = login_through(refusing)

      assert {:error, {:oauth_client_rejected, %{error: "invalid_client"}}} = result
      assert_received {:authorize_url, url}
      assert_received {:plugin_auth, %{duration_ms: _}, metadata}

      assert metadata == %{
               op: :login,
               plugin: "google_calendar",
               result: :error,
               error_class: :oauth_client_rejected,
               vendor_error: "invalid_client",
               vendor_description: "Unauthorized"
             }

      assert log =~ "login google_calendar"
      assert log =~ "oauth_client_rejected"
      assert log =~ "Google answered HTTP 401 invalid_client: Unauthorized"
      assert leaked(inspect(metadata), url) == []
      assert leaked(log, url) == []
    end

    test "a completed sign-in is traced with its tag and nothing it holds" do
      minting = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "access_token" => "google_at",
            "refresh_token" => "google_rt",
            "expires_in" => 3600
          })
        )
      end

      {result, _log} = login_through(minting)

      assert {:ok, %{status: "ready"}} = result
      assert_received {:authorize_url, url}
      assert_received {:plugin_auth, _measurements, metadata}
      assert metadata == %{op: :login, plugin: "google_calendar", result: :ready}
      assert leaked(inspect(metadata), url) == []
    end

    test "a sign-in refused before any browser still names its class" do
      Application.put_env(:fermix_core, :oauth, %{})

      {result, log} = with_log(fn -> Auth.login("google_calendar") end)

      assert {:error, :needs_client_config} = result
      assert_received {:plugin_auth, _measurements, metadata}
      assert metadata.error_class == :needs_client_config
      refute Map.has_key?(metadata, :vendor_error)
      assert log =~ "needs_client_config"
    end

    # A name no plugin answers to is a typed failure reported once, the same as
    # sign-in's, not a WithClauseError or a bare :error that skips the report.
    test "a sign-out or refresh of an unknown plugin is one reported, typed failure" do
      {results, log} =
        with_log(fn -> {Auth.logout("no-such-plugin"), Auth.refresh("no-such-plugin")} end)

      assert {{:error, {:unknown_plugin, "no-such-plugin"}},
              {:error, {:unknown_plugin, "no-such-plugin"}}} = results

      assert_received {:plugin_auth, _measurements, logout}

      assert logout == %{
               op: :logout,
               plugin: "no-such-plugin",
               result: :error,
               error_class: :unknown_plugin
             }

      assert_received {:plugin_auth, _measurements, refresh}

      assert refresh == %{
               op: :refresh,
               plugin: "no-such-plugin",
               result: :error,
               error_class: :unknown_plugin
             }

      assert log =~ "logout no-such-plugin failed (unknown_plugin)"
      assert log =~ "refresh no-such-plugin failed (unknown_plugin)"
    end
  end

  test "Google OAuth login requires the desktop secret" do
    Application.put_env(:fermix_core, :oauth, %{
      "google" => [client_id: "123.apps.googleusercontent.com"]
    })

    assert {:error, :needs_client_config} =
             Auth.login("google_calendar")
  end

  # The account lookup runs while the sign-in holds the profile lock, so it is
  # one bounded attempt: a transient failure is not retried (Req would retry a
  # GET three more times, and honour a Retry-After of any length).
  test "userinfo failure does not discard minted OAuth tokens, and is asked once" do
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
      send(parent, :userinfo_asked)

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
    assert_received :userinfo_asked
    refute_received :userinfo_asked
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
    install_oauth_plugin_fixture("github", "github", ["read:user", "repo"])
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
    # Only a regional provider records one; GitHub has no region to record.
    assert stored.region == nil

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

  # Tesla's Fleet API is regional, and the region is knowable only at sign-in:
  # it is the region whose base URL the code exchange named as `audience`. It is
  # recorded on the auth entry because the refresh path and the plugin's HTTP
  # host both read it back and neither can re-derive it from the tokens.
  #
  # The region is chosen as part of the sign-in client, so a sign-in then
  # confirms it against the account's own region before the grant is stored:
  # otherwise the first tool call is the first anyone hears of a mismatch, and
  # what they hear is Tesla's 421.
  describe "a Tesla sign-in and the region it confirms" do
    setup do
      install_oauth_plugin_fixture("tesla", "tesla", [
        "openid",
        "offline_access",
        "vehicle_device_data"
      ])

      TokenSupervisor.stop_profile("tesla:primary")
      on_exit(fn -> TokenSupervisor.stop_profile("tesla:primary") end)

      put_tesla_client("na")
      :ok
    end

    test "records the chosen region on the entry when the account agrees" do
      parent = self()

      assert {:ok, entry} = tesla_login(region_plug(200, %{"response" => %{"region" => "na"}}))

      assert entry.provider == "tesla"
      assert entry.region == "na"
      assert entry.status == "ready"
      assert entry.region_actual == nil

      assert {:ok, stored} = Store.read("tesla:primary")
      assert stored.region == "na"
      assert stored.status == "ready"
      assert stored.region_actual == nil
      assert stored.tokens.access_token == "tesla_at"
      assert stored.tokens.refresh_token == "tesla_rt"
      assert stored.granted_scopes == ["openid", "offline_access", "vehicle_device_data"]

      assert_received {:authorize_url, url}
      query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      assert query["redirect_uri"] == "https://fermix.ai/api/integrations/tesla/callback"

      assert_received {:token_form, form}
      assert form["audience"] == "https://fleet-api.prd.na.vn.cloud.tesla.com"
      assert form["redirect_uri"] == "https://fermix.ai/api/integrations/tesla/callback"
      assert form["client_secret"] == "tesla-client-secret"

      # The probe asks the chosen region's own Fleet API host, with the grant it
      # just minted.
      assert_received {:region_probe, probe_url, authorization}
      assert probe_url == "/api/1/users/region"
      assert authorization == "Bearer tesla_at"
      send(parent, :ok)
    end

    # The grant is real, so the sign-in succeeds; what it is not is usable, and
    # the entry says so rather than leaving the first tool call to find out.
    test "marks a grant whose account is in another region" do
      assert {:ok, entry} = tesla_login(region_plug(200, %{"response" => %{"region" => "eu"}}))

      assert entry.status == "wrong_region"
      assert entry.region == "na"
      assert entry.region_actual == "eu"

      assert {:ok, stored} = Store.read("tesla:primary")
      assert stored.status == "wrong_region"
      assert stored.region == "na"
      assert stored.region_actual == "eu"
      assert stored.tokens.access_token == "tesla_at"
    end

    # Tesla's own refusal: 421 with the right base URL in its error text. The
    # region is read back out of that text rather than guessed.
    test "marks a grant the provider refuses with 421, naming the region it named" do
      body = %{
        "error" => "user out of region, use base URL: https://fleet-api.prd.eu.vn.cloud.tesla.com"
      }

      assert {:ok, entry} = tesla_login(region_plug(421, body))

      assert entry.status == "wrong_region"
      assert entry.region_actual == "eu"

      assert {:ok, stored} = Store.read("tesla:primary")
      assert stored.status == "wrong_region"
      assert stored.region_actual == "eu"
    end

    test "marks the mismatch with no region when the refusal names none it knows" do
      body = %{"error" => "user out of region"}

      assert {:ok, entry} = tesla_login(region_plug(421, body))

      assert entry.status == "wrong_region"
      assert entry.region_actual == nil

      assert {:ok, stored} = Store.read("tesla:primary")
      assert stored.status == "wrong_region"
      assert stored.region_actual == nil
    end

    # Best-effort, exactly like the userinfo fetch: a probe that cannot answer
    # must not fail a sign-in that succeeded, and it must say so once in the log.
    test "leaves a real grant alone when the probe cannot answer" do
      unreadable = fn conn -> Plug.Conn.send_resp(conn, 200, "not json") end
      broken = fn conn -> Plug.Conn.send_resp(conn, 500, "") end

      for plug <- [unreadable, broken] do
        Store.delete_provider("tesla:primary")

        {result, log} = with_log(fn -> tesla_login(plug) end)

        assert {:ok, entry} = result
        assert entry.status == "ready"
        assert entry.region == "na"
        assert entry.region_actual == nil

        assert {:ok, stored} = Store.read("tesla:primary")
        assert stored.status == "ready"
        assert stored.tokens.access_token == "tesla_at"

        assert log =~ "region"
        refute log =~ "tesla_at"
      end
    end

    # The probe runs while the sign-in holds the profile lock, so it is one
    # bounded attempt: a transient failure is not retried.
    test "asks the region once when the probe fails" do
      assert {:ok, entry} = tesla_login(region_plug(503, %{"error" => "unavailable"}))

      assert entry.status == "ready"
      assert_received {:region_probe, "/api/1/users/region", _authorization}
      refute_received {:region_probe, _path, _authorization}
    end

    # A sign-in under the region the account is actually in clears the marker a
    # previous one left, because the status is rewritten on every write.
    test "a sign-in in the right region clears an earlier mismatch" do
      assert {:ok, _mismatched} =
               tesla_login(region_plug(200, %{"response" => %{"region" => "eu"}}))

      assert {:ok, stored} = Store.read("tesla:primary")
      assert stored.status == "wrong_region"

      put_tesla_client("eu")

      assert {:ok, entry} = tesla_login(region_plug(200, %{"response" => %{"region" => "eu"}}))

      assert entry.status == "ready"
      assert entry.region == "eu"

      assert {:ok, reread} = Store.read("tesla:primary")
      assert reread.status == "ready"
      assert reread.region == "eu"
    end
  end

  # The trace has to carry the mismatch, or the one surface that could explain a
  # sign-in nobody can use says it went fine.
  test "a sign-in in the wrong region is traced as such, and carries nothing it holds" do
    install_oauth_plugin_fixture("tesla", "tesla", ["openid"])
    TokenSupervisor.stop_profile("tesla:primary")
    on_exit(fn -> TokenSupervisor.stop_profile("tesla:primary") end)
    put_tesla_client("na")

    parent = self()
    handler = "oauth-login-region-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:fermix, :plugin, :auth],
        fn _event, _measurements, metadata, _config ->
          if self() == parent, do: send(parent, {:plugin_auth, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, _entry} = tesla_login(region_plug(200, %{"response" => %{"region" => "eu"}}))

    assert_received {:plugin_auth, metadata}
    assert metadata.op == :login
    assert metadata.plugin == "tesla"
    assert metadata.result == :wrong_region
    refute Map.has_key?(metadata, :error_class)
  end

  defp put_tesla_client(region) do
    Application.put_env(:fermix_core, :oauth, %{
      "tesla" => [
        client_type: "desktop_public_pkce",
        client_id: "tesla-client-id",
        client_secret: "tesla-client-secret",
        region: region
      ]
    })
  end

  # The probe's own answer, and the proof it was made with the fresh grant
  # against the chosen region's host.
  defp region_plug(status, body) do
    parent = self()

    fn conn ->
      authorization = conn |> Plug.Conn.get_req_header("authorization") |> List.first()
      send(parent, {:region_probe, conn.request_path, authorization})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end
  end

  defp tesla_login(region_plug) do
    port = pick_free_port()
    parent = self()

    token_plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:token_form, URI.decode_query(body)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "access_token" => "tesla_at",
          "refresh_token" => "tesla_rt",
          "expires_in" => 28_800,
          "scope" => "openid offline_access vehicle_device_data"
        })
      )
    end

    opener = fn url ->
      send(parent, {:authorize_url, url})

      Task.start(fn ->
        state =
          url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")

        deliver_callback(port, "/auth/callback?code=AUTHCODE&state=#{state}")
      end)

      :ok
    end

    Auth.login("tesla",
      port: port,
      opener: opener,
      timeout_ms: 5_000,
      req_options: [plug: token_plug],
      region_req_options: [plug: region_plug],
      puts: fn _ -> :ok end
    )
  end

  # A ready installed plugin under FERMIX_HOME/plugins — the exact tree
  # Installer.run_install/2 leaves behind (registry_union_test pattern).
  defp install_oauth_plugin_fixture(name, provider, scopes) do
    root = Path.join(System.fetch_env!("FERMIX_HOME"), "plugins")
    DistStore.ensure!(root)
    dir = DistStore.version_dir(root, name, "1.0.0")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "plugin.json"), Jason.encode!(manifest(name, provider, scopes)))
    :ok = DistStore.activate(root, name, "1.0.0")

    :ok =
      DistStore.record(root, name, %{
        "version" => "1.0.0",
        "sha256" => String.duplicate("0", 64),
        "h1" => String.duplicate("0", 64),
        "plugin_api" => 2,
        "min_core_version" => "0.1.0"
      })
  end

  defp manifest(name, provider, scopes) do
    %{
      "schema_version" => 2,
      "name" => name,
      "display_name" => name,
      "description" => "An OAuth plugin fixture",
      "category" => "developer",
      "version" => "1.0.0",
      "min_core_version" => "0.1.0",
      "plugin_api" => 2,
      "auth" => %{
        "type" => "oauth2",
        "provider" => provider,
        "profile_key" => name,
        "account_mode" => "single",
        "scopes" => scopes
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
