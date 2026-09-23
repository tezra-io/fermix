defmodule FermixCore.Auth.TokenFileHandoffTest do
  @moduledoc """
  The write-through half of the token-file handoff (M8 §9.3): the per-profile
  `TokenManager` is the only writer of a plugin child's access-token
  projection, it rewrites the file on every accepted grant, and it deletes the
  file the moment the grant stops being servable.

  `async: false` — the plugin-oauth refresh path reads the global
  `[fermix_core :oauth]` client config, and one case reproduces the tree-less
  CLI world by unregistering the `TokenSupervisor` name.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [capture_log: 1, with_log: 1]

  alias FermixCore.Auth.Store
  alias FermixCore.Auth.TokenFile
  alias FermixCore.Auth.TokenManager
  alias FermixCore.Auth.TokenSupervisor
  alias FermixCore.Plugins.Dist.Store, as: DistStore
  alias FermixTestSupport.SafeRm

  setup do
    previous = Application.get_env(:fermix_core, :oauth)

    Application.put_env(:fermix_core, :oauth, %{
      "google" => [client_type: "desktop_public_pkce", client_id: "g-id", client_secret: "g-sec"],
      "x" => [client_type: "desktop_public_pkce", client_id: "x-id", client_secret: "stale-sec"],
      "tesla" => [
        client_type: "desktop_public_pkce",
        client_id: "t-id",
        client_secret: "t-sec",
        region: "eu"
      ]
    })

    dir = SafeRm.make_tmp_dir!("token-handoff")
    root = SafeRm.make_tmp_dir!("token-handoff-store")
    DistStore.ensure!(root)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:fermix_core, :oauth)
        value -> Application.put_env(:fermix_core, :oauth, value)
      end

      SafeRm.rm_rf!(dir)
      SafeRm.rm_rf!(root)
    end)

    %{dir: dir, root: root}
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

  def dead_grant_plug(conn), do: Plug.Conn.send_resp(conn, 400, ~s({"error":"invalid_grant"}))

  def refused_client_plug(conn) do
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

  defp start_manager(profile, auth_path, plug) do
    name = :"tm_handoff_#{System.unique_integer([:positive])}"

    start_supervised!(
      {TokenManager,
       [
         name: name,
         auth_profile: profile,
         fermix_auth_path: auth_path,
         req_options: if(plug, do: [plug: plug], else: [])
       ]}
    )

    name
  end

  defp read(path), do: path |> File.read!() |> Jason.decode!()

  describe "enable_token_file/2" do
    test "projects the current grant immediately", %{dir: dir, root: root} do
      auth = write_auth_file(dir, "tesla:primary", "tesla", %{"region" => "eu"})
      path = DistStore.token_file(root, "tesla:primary")
      name = start_manager("tesla:primary", auth, nil)

      assert :ok = TokenManager.enable_token_file(name, path)

      assert %{
               "access_token" => "old_at",
               "region" => "eu",
               "auth_profile" => "tesla:primary",
               "generation" => 1
             } = read(path)
    end

    test "a grant with no access token is refused rather than projected as empty", %{
      dir: dir,
      root: root
    } do
      auth = Path.join(dir, "absent_auth.json")
      path = DistStore.token_file(root, "tesla:primary")
      {name, _log} = with_log(fn -> start_manager("tesla:primary", auth, nil) end)

      assert {:error, :no_token} = TokenManager.enable_token_file(name, path)
      refute File.exists?(path)
    end

    test "a quarantined grant is refused and leaves no projection behind", %{
      dir: dir,
      root: root
    } do
      auth =
        write_auth_file(dir, "tesla:primary", "tesla", %{
          "status" => "wrong_region",
          "region" => "na",
          "region_actual" => "eu"
        })

      path = DistStore.token_file(root, "tesla:primary")
      name = start_manager("tesla:primary", auth, nil)

      assert {:error, :wrong_region} = TokenManager.enable_token_file(name, path)
      refute File.exists?(path)
    end
  end

  describe "write-through" do
    test "a refresh rewrites the projection and bumps the generation", %{dir: dir, root: root} do
      auth = write_auth_file(dir, "tesla:primary", "tesla", %{"region" => "eu"})
      path = DistStore.token_file(root, "tesla:primary")
      name = start_manager("tesla:primary", auth, &__MODULE__.refresh_plug/1)

      assert :ok = TokenManager.enable_token_file(name, path)
      assert read(path)["generation"] == 1

      assert {:ok, "new_at"} = TokenManager.refresh(name)

      projected = read(path)
      assert projected["access_token"] == "new_at"
      assert projected["generation"] == 2
      assert projected["region"] == "eu"
      # The refresh token stays inside the daemon: the child never gets one.
      refute Map.has_key?(projected, "refresh_token")
    end

    test "a reload after a fresh sign-in re-projects the new token", %{dir: dir, root: root} do
      auth = write_auth_file(dir, "google_calendar:primary", "google")
      path = DistStore.token_file(root, "google_calendar:primary")
      name = start_manager("google_calendar:primary", auth, nil)

      assert :ok = TokenManager.enable_token_file(name, path)

      {:ok, entry} = Store.read("google_calendar:primary", auth)

      :ok =
        Store.write(
          "google_calendar:primary",
          %{entry | tokens: %{access_token: "fresh_at", refresh_token: "fresh_rt"}},
          auth
        )

      assert {:ok, "fresh_at"} = TokenManager.reload(name)
      assert read(path)["access_token"] == "fresh_at"
    end
  end

  describe "deleting the projection" do
    test "disable_token_file/1 removes it and stops the write-through", %{dir: dir, root: root} do
      auth = write_auth_file(dir, "tesla:primary", "tesla", %{"region" => "eu"})
      path = DistStore.token_file(root, "tesla:primary")
      name = start_manager("tesla:primary", auth, &__MODULE__.refresh_plug/1)

      assert :ok = TokenManager.enable_token_file(name, path)
      assert File.exists?(path)

      assert :ok = TokenManager.disable_token_file(name)
      refute File.exists?(path)

      assert {:ok, "new_at"} = TokenManager.refresh(name)
      refute File.exists?(path)
    end

    test "forget/1 removes it", %{dir: dir, root: root} do
      auth = write_auth_file(dir, "tesla:primary", "tesla", %{"region" => "eu"})
      path = DistStore.token_file(root, "tesla:primary")
      name = start_manager("tesla:primary", auth, nil)

      assert :ok = TokenManager.enable_token_file(name, path)
      assert :ok = TokenManager.forget(name)
      refute File.exists?(path)
    end

    test "a refresh that ends in reauthorization_required removes it", %{dir: dir, root: root} do
      auth = write_auth_file(dir, "google_calendar:primary", "google")
      path = DistStore.token_file(root, "google_calendar:primary")
      name = start_manager("google_calendar:primary", auth, &__MODULE__.dead_grant_plug/1)

      assert :ok = TokenManager.enable_token_file(name, path)
      assert File.exists?(path)

      capture_log(fn ->
        assert {:error, :reauthorization_required} = TokenManager.refresh(name)
      end)

      refute File.exists?(path)
    end

    test "a refused sign-in client removes it", %{dir: dir, root: root} do
      auth = write_auth_file(dir, "x:primary", "x")
      path = DistStore.token_file(root, "x:primary")
      name = start_manager("x:primary", auth, &__MODULE__.refused_client_plug/1)

      assert :ok = TokenManager.enable_token_file(name, path)
      assert File.exists?(path)

      capture_log(fn ->
        assert {:error, {:oauth_client_rejected, _detail}} = TokenManager.refresh(name)
      end)

      refute File.exists?(path)
    end

    test "a reload that finds a wrong_region grant removes it", %{dir: dir, root: root} do
      auth = write_auth_file(dir, "tesla:primary", "tesla", %{"region" => "eu"})
      path = DistStore.token_file(root, "tesla:primary")
      name = start_manager("tesla:primary", auth, nil)

      assert :ok = TokenManager.enable_token_file(name, path)
      assert File.exists?(path)

      {:ok, entry} = Store.read("tesla:primary", auth)

      :ok =
        Store.write(
          "tesla:primary",
          entry |> Map.put(:status, "wrong_region") |> Map.put(:region_actual, "eu"),
          auth
        )

      assert {:ok, "old_at"} = TokenManager.reload(name)
      refute File.exists?(path)
    end
  end

  describe "the tree-less CLI world" do
    # `fermix plugins …`, `fermix doctor` and every other one-shot verb run with
    # no supervision tree, so no per-profile manager exists to keep a projection
    # fresh. Such a VM must refuse rather than write a token file it can never
    # rewrite — the daemon rewrites the file when it next reconciles its children.
    test "refuses to project a token with no daemon to keep it fresh", %{root: root} do
      path = DistStore.token_file(root, "tesla:primary")

      without_token_supervisor(fn ->
        assert {:error, :token_file_needs_daemon} =
                 TokenSupervisor.enable_token_file("tesla:primary", path)
      end)

      refute File.exists?(path)
      assert TokenFile.needs_daemon_sentence() =~ "daemon"
    end

    test "disabling a projection with no daemon is the state the caller asked for", %{
      root: root
    } do
      without_token_supervisor(fn ->
        assert :ok = TokenSupervisor.disable_token_file("tesla:primary")
      end)

      refute File.exists?(DistStore.token_file(root, "tesla:primary"))
    end
  end

  # Reproduces the tree-less world by unregistering the supervisor's name for
  # the length of one call. This module is `async: false` and ExUnit never runs
  # a synchronous module beside an asynchronous one, so nothing else can look
  # the name up meanwhile; `after` restores it on every path.
  defp without_token_supervisor(fun) do
    pid = Process.whereis(TokenSupervisor)
    assert is_pid(pid), "the token supervisor must be running for this case to mean anything"
    Process.unregister(TokenSupervisor)

    try do
      fun.()
    after
      Process.register(pid, TokenSupervisor)
    end
  end
end
