defmodule FermixCore.Auth.TokenManagerPluginRefreshTest do
  # async: false — sets the global [fermix_core :oauth] client config the
  # provider registry reads during plugin-oauth refresh.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.Auth.ClientRejection
  alias FermixCore.Auth.Store
  alias FermixCore.Auth.TokenManager

  setup do
    previous = Application.get_env(:fermix_core, :oauth)

    Application.put_env(:fermix_core, :oauth, %{
      "google" => [client_type: "desktop_public_pkce", client_id: "g-id", client_secret: "g-sec"],
      "github" => [
        client_type: "desktop_public_pkce",
        client_id: "gh-id",
        client_secret: "gh-sec"
      ],
      "x" => [client_type: "desktop_public_pkce", client_id: "x-id", client_secret: "stale-sec"],
      "tesla" => [
        client_type: "desktop_public_pkce",
        client_id: "t-id",
        client_secret: "t-sec",
        region: "eu"
      ]
    })

    dir = FermixTestSupport.SafeRm.make_tmp_dir!("tm-plugin-refresh")

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:fermix_core, :oauth)
        value -> Application.put_env(:fermix_core, :oauth, value)
      end

      FermixTestSupport.SafeRm.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  def refresh_plug(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(
      200,
      Jason.encode!(%{
        "access_token" => "new_at",
        "refresh_token" => "new_rt",
        "expires_in" => 3600
      })
    )
  end

  defp write_auth_file(dir, profile, provider, extra \\ %{}) do
    path = Path.join(dir, "fermix_auth.json")

    entry =
      Map.merge(
        %{
          "auth_mode" => "oauth2",
          "provider" => provider,
          "granted_scopes" => ["a-scope"],
          "tokens" => %{"access_token" => "old_at", "refresh_token" => "old_rt"},
          "expires_at" =>
            DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()
        },
        extra
      )

    File.write!(path, Jason.encode!(%{"version" => 2, "providers" => %{profile => entry}}))

    path
  end

  defp start_manager(opts) do
    name = :"tm_plugin_#{System.unique_integer([:positive])}"
    start_supervised!({TokenManager, Keyword.put(opts, :name, name)})
    name
  end

  test "refreshes a github profile through the provider registry", %{dir: dir} do
    fermix_path = write_auth_file(dir, "github:primary", "github")

    name =
      start_manager(
        auth_profile: "github:primary",
        fermix_auth_path: fermix_path,
        req_options: [plug: &__MODULE__.refresh_plug/1]
      )

    assert {:ok, "new_at"} = TokenManager.refresh(name)

    data = fermix_path |> File.read!() |> Jason.decode!()
    entry = data["providers"]["github:primary"]
    assert entry["tokens"]["access_token"] == "new_at"
    assert entry["tokens"]["refresh_token"] == "new_rt"
    assert entry["provider"] == "github"
    assert entry["status"] == "ready"
  end

  test "google profiles still refresh through the registry (regression)", %{dir: dir} do
    fermix_path = write_auth_file(dir, "google_calendar:primary", "google")

    name =
      start_manager(
        auth_profile: "google_calendar:primary",
        fermix_auth_path: fermix_path,
        req_options: [plug: &__MODULE__.refresh_plug/1]
      )

    assert {:ok, "new_at"} = TokenManager.refresh(name)

    data = fermix_path |> File.read!() |> Jason.decode!()
    entry = data["providers"]["google_calendar:primary"]
    assert entry["tokens"]["access_token"] == "new_at"
    assert entry["provider"] == "google"
  end

  # The region is recorded once, at sign-in, and nothing on the refresh path can
  # re-derive it — so a refresh that rebuilt the entry instead of updating it
  # would silently strand the plugin without a Fleet API host.
  test "a tesla refresh keeps the recorded region and sends no exchange audience", %{dir: dir} do
    fermix_path = write_auth_file(dir, "tesla:primary", "tesla", %{"region" => "eu"})
    parent = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:refresh_form, URI.decode_query(body)})
      __MODULE__.refresh_plug(conn)
    end

    name =
      start_manager(
        auth_profile: "tesla:primary",
        fermix_auth_path: fermix_path,
        req_options: [plug: plug]
      )

    assert {:ok, "new_at"} = TokenManager.refresh(name)

    entry =
      fermix_path |> File.read!() |> Jason.decode!() |> get_in(["providers", "tesla:primary"])

    assert entry["region"] == "eu"
    assert entry["tokens"]["access_token"] == "new_at"
    assert entry["tokens"]["refresh_token"] == "new_rt"
    assert entry["status"] == "ready"

    assert_received {:refresh_form, form}
    refute Map.has_key?(form, "audience")
    assert form["grant_type"] == "refresh_token"
    assert form["client_id"] == "t-id"
  end

  test "unknown providers stay unsupported", %{dir: dir} do
    fermix_path = write_auth_file(dir, "linear:primary", "linear")

    name =
      start_manager(
        auth_profile: "linear:primary",
        fermix_auth_path: fermix_path,
        req_options: []
      )

    assert {:error, :unsupported_provider} = TokenManager.refresh(name)
  end

  describe "a refused client" do
    defp refusing_plug(parent) do
      fn conn ->
        send(parent, :token_request)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          401,
          Jason.encode!(%{
            "error" => "unauthorized_client",
            "error_description" => "Missing valid authorization header"
          })
        )
      end
    end

    defp stored(path, profile) do
      path |> File.read!() |> Jason.decode!() |> get_in(["providers", profile])
    end

    test "quarantines the grant under its true cause and says how to fix it", %{dir: dir} do
      fermix_path = write_auth_file(dir, "x:primary", "x")

      name =
        start_manager(
          auth_profile: "x:primary",
          fermix_auth_path: fermix_path,
          req_options: [plug: refusing_plug(self())]
        )

      {result, log} = with_log(fn -> TokenManager.refresh(name) end)

      assert {:error, {:oauth_client_rejected, detail}} = result
      assert stored(fermix_path, "x:primary")["status"] == "client_rejected"

      # One line with the profile, the provider, the vendor's own words and the
      # fix. A refused client is not a dead grant: signing in with the same
      # secret or restarting the daemon cannot help, so neither is advised.
      assert [line] = log |> String.split("\n") |> Enum.filter(&(&1 =~ "x:primary"))
      assert line =~ ClientRejection.vendor_words(detail)
      assert line =~ ClientRejection.sentence(detail)
      refute log =~ "fermix auth login"
      refute log =~ "restart"
    end

    test "answers the typed refusal until a fresh sign-in is reloaded", %{dir: dir} do
      fermix_path = write_auth_file(dir, "x:primary", "x")

      name =
        start_manager(
          auth_profile: "x:primary",
          fermix_auth_path: fermix_path,
          req_options: [plug: refusing_plug(self())]
        )

      capture_log(fn ->
        assert {:error, {:oauth_client_rejected, _detail}} = TokenManager.refresh(name)
      end)

      assert_received :token_request

      # Quarantined: the same diagnosis, and no request the client would refuse.
      assert {:error, {:oauth_client_rejected, detail}} = TokenManager.get_token(name)
      assert {:error, {:oauth_client_rejected, ^detail}} = TokenManager.refresh(name)
      assert {:ok, %{invalidated?: true}} = TokenManager.status(name)
      refute_received :token_request

      # A fresh sign-in rewrites the entry as ready; the reload brings it in.
      {:ok, entry} = Store.read("x:primary", fermix_path)

      :ok =
        Store.write(
          "x:primary",
          %{
            entry
            | tokens: %{access_token: "fresh_at", refresh_token: "fresh_rt"},
              status: "ready"
          },
          fermix_path
        )

      assert {:ok, "fresh_at"} = TokenManager.reload(name)
      assert {:ok, "fresh_at"} = TokenManager.get_token(name)
      assert {:ok, %{invalidated?: false}} = TokenManager.status(name)
    end

    test "forget replaces the typed refusal with the generic one", %{dir: dir} do
      fermix_path = write_auth_file(dir, "x:primary", "x")

      name =
        start_manager(
          auth_profile: "x:primary",
          fermix_auth_path: fermix_path,
          req_options: [plug: refusing_plug(self())]
        )

      capture_log(fn ->
        assert {:error, {:oauth_client_rejected, _detail}} = TokenManager.refresh(name)
      end)

      assert :ok = TokenManager.forget(name)
      assert {:error, :reauthorization_required} = TokenManager.get_token(name)
    end
  end

  test "a dead plugin grant still quarantines as reauthorization_required", %{dir: dir} do
    fermix_path = write_auth_file(dir, "github:primary", "github")

    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(400, Jason.encode!(%{"error" => "invalid_grant"}))
    end

    name =
      start_manager(
        auth_profile: "github:primary",
        fermix_auth_path: fermix_path,
        req_options: [plug: plug]
      )

    log =
      capture_log(fn ->
        assert {:error, :reauthorization_required} = TokenManager.refresh(name)
      end)

    data = fermix_path |> File.read!() |> Jason.decode!()
    assert data["providers"]["github:primary"]["status"] == "reauthorization_required"
    assert log =~ "fermix auth login"
    assert {:error, :reauthorization_required} = TokenManager.get_token(name)
  end

  # AGENTS.md rule 7: the quarantine status write after a dead grant can fail
  # (a malformed auth.json, a busy store lock). The failure is logged and
  # answered rather than dropped, and the manager refuses the dead grant all the
  # same.
  test "a failed reauthorization_required write is logged and answered", %{dir: dir} do
    fermix_path = write_auth_file(dir, "github:primary", "github")

    plug = fn conn ->
      File.write!(fermix_path, "{ not json ")

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(400, Jason.encode!(%{"error" => "invalid_grant"}))
    end

    name =
      start_manager(
        auth_profile: "github:primary",
        fermix_auth_path: fermix_path,
        req_options: [plug: plug]
      )

    {result, log} = with_log(fn -> TokenManager.refresh(name) end)

    assert {:error, {:malformed_auth_file, ^fermix_path, _backup, {:invalid_json, _err}}} = result
    assert log =~ "could not record reauthorization_required for github:primary"
    assert {:error, :reauthorization_required} = TokenManager.get_token(name)
  end

  # TOKEN-5 (tla/specs/token_refresh, check 14): `fermix plugins auth logout`
  # deletes the entry in a tree-less VM and never reaches the daemon's manager.
  # That manager's next refresh must not send the grant or write it back, and
  # its plugin child must lose the projected token.
  test "a refresh after a CLI logout refuses, sends nothing and writes nothing", %{dir: dir} do
    fermix_path = write_auth_file(dir, "github:primary", "github")
    token_file = Path.join(dir, "github-primary.token.json")
    parent = self()

    plug = fn conn ->
      send(parent, :refresh_sent)
      __MODULE__.refresh_plug(conn)
    end

    name =
      start_manager(
        auth_profile: "github:primary",
        fermix_auth_path: fermix_path,
        req_options: [plug: plug]
      )

    assert :ok = TokenManager.enable_token_file(name, token_file)
    assert File.exists?(token_file)

    :ok = Store.delete_provider("github:primary", fermix_path)

    {result, log} = with_log(fn -> TokenManager.refresh(name) end)

    assert {:error, :reauthorization_required} = result
    assert log =~ "github:primary"
    refute_received :refresh_sent

    assert {:error, {:provider_missing, "github:primary"}} =
             Store.read("github:primary", fermix_path)

    assert {:error, :reauthorization_required} = TokenManager.get_token(name)
    refute File.exists?(token_file)
  end

  # TOKEN-4 (check 12): a plugin logout whose delete landed inside the
  # profile's own refresh was undone when that refresh renamed its rotation.
  # The delete takes the profile lock, so it waits and deletes after it.
  test "a logout's delete waits for the profile's refresh in flight", %{dir: dir} do
    fermix_path = write_auth_file(dir, "github:primary", "github")
    parent = self()

    plug = fn conn ->
      send(parent, {:in_flight, self()})

      receive do
        :release -> :ok
      end

      __MODULE__.refresh_plug(conn)
    end

    name =
      start_manager(
        auth_profile: "github:primary",
        fermix_auth_path: fermix_path,
        req_options: [plug: plug]
      )

    refresh = Task.async(fn -> TokenManager.refresh(name) end)
    assert_receive {:in_flight, plug_pid}

    delete = Task.async(fn -> Store.delete_provider("github:primary", fermix_path) end)
    assert Task.yield(delete, 300) == nil

    send(plug_pid, :release)
    assert {:ok, "new_at"} = Task.await(refresh)
    assert :ok = Task.await(delete)

    assert {:error, {:provider_missing, "github:primary"}} =
             Store.read("github:primary", fermix_path)
  end

  # A grant minted for the wrong region is real and unexpired, so nothing stops
  # it being handed out on its own: every call it authorises is refused by the
  # provider from the wrong host. The manager reads the quarantine off the stored
  # grant, which is where the sign-in recorded it, and refuses instead.
  describe "a grant the sign-in recorded as wrong_region" do
    test "is refused rather than served", %{dir: dir} do
      fermix_path =
        write_auth_file(dir, "tesla:primary", "tesla", %{
          "status" => "wrong_region",
          "region" => "na",
          "region_actual" => "eu"
        })

      name =
        start_manager(
          auth_profile: "tesla:primary",
          fermix_auth_path: fermix_path,
          req_options: [plug: &__MODULE__.refresh_plug/1]
        )

      assert {:error, :wrong_region} = TokenManager.get_token(name)
      assert {:error, :wrong_region} = TokenManager.refresh(name)
      assert {:ok, %{invalidated?: true}} = TokenManager.status(name)
    end

    # A fresh sign-in rewrites the status, and a reload is what a sign-in runs.
    test "is served again once a sign-in clears the marker", %{dir: dir} do
      fermix_path =
        write_auth_file(dir, "tesla:primary", "tesla", %{
          "status" => "wrong_region",
          "region" => "na",
          "region_actual" => "eu"
        })

      name =
        start_manager(
          auth_profile: "tesla:primary",
          fermix_auth_path: fermix_path,
          req_options: [plug: &__MODULE__.refresh_plug/1]
        )

      assert {:error, :wrong_region} = TokenManager.get_token(name)

      :ok =
        Store.write(
          "tesla:primary",
          %{
            auth_mode: "oauth2",
            provider: "tesla",
            granted_scopes: ["a-scope"],
            tokens: %{access_token: "eu_at", refresh_token: "eu_rt"},
            expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
            last_refresh: nil,
            status: "ready",
            region: "eu"
          },
          fermix_path
        )

      assert {:ok, "eu_at"} = TokenManager.reload(name)
      assert {:ok, "eu_at"} = TokenManager.get_token(name)
    end

    test "a grant with a region and no mismatch is served normally", %{dir: dir} do
      fermix_path =
        write_auth_file(dir, "tesla:primary", "tesla", %{
          "status" => "ready",
          "region" => "eu"
        })

      name =
        start_manager(
          auth_profile: "tesla:primary",
          fermix_auth_path: fermix_path,
          req_options: [plug: &__MODULE__.refresh_plug/1]
        )

      assert {:ok, "old_at"} = TokenManager.get_token(name)
    end
  end
end
