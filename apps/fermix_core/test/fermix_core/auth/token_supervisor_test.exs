defmodule FermixCore.Auth.TokenSupervisorTest do
  # async: false — mutates FERMIX_HOME so Store's default path is hermetic.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias FermixCore.Auth.Store
  alias FermixCore.Auth.TokenManager
  alias FermixCore.Auth.TokenSupervisor
  alias FermixCore.Plugins.Dist.Store, as: DistStore
  alias FermixTestSupport.SafeRm

  setup do
    dir = Path.join(System.tmp_dir!(), "fermix_ts_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    prior = System.get_env("FERMIX_HOME")
    System.put_env("FERMIX_HOME", dir)

    on_exit(fn ->
      case prior do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      FermixTestSupport.SafeRm.rm_rf!(dir)
    end)

    :ok
  end

  defp anthropic_entry do
    %{
      auth_mode: "claude_code_import",
      provider: "anthropic",
      tokens: %{access_token: "old_at", refresh_token: "old_rt"},
      expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      last_refresh: nil
    }
  end

  defp short_lived_entry do
    %{
      anthropic_entry()
      | provider: "custom",
        expires_at: DateTime.add(DateTime.utc_now(), 60, :second),
        last_refresh: DateTime.utc_now()
    }
  end

  defp refresh_plug(conn) do
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

  defp permanent_400_plug(conn) do
    Plug.Conn.send_resp(conn, 400, ~s({"error":"invalid_grant"}))
  end

  describe "refresh_entry/3 — anthropic (the direct, process-less refresh path)" do
    test "refreshes via the Anthropic token endpoint and persists the entry" do
      :ok = Store.write("anthropic_oauth", anthropic_entry())
      # The production path always refreshes a Store-normalized entry.
      {:ok, entry} = Store.read("anthropic_oauth")

      assert {:ok, refreshed} =
               TokenSupervisor.refresh_entry("anthropic_oauth", entry, plug: &refresh_plug/1)

      assert refreshed.tokens.access_token == "new_at"
      assert refreshed.status == "ready"

      assert {:ok, stored} = Store.read("anthropic_oauth")
      assert stored.tokens.access_token == "new_at"
      assert stored.tokens.refresh_token == "new_rt"
      assert stored.provider == "anthropic"
    end

    test "permanent refresh failure quarantines the profile" do
      :ok = Store.write("anthropic_oauth", anthropic_entry())
      {:ok, entry} = Store.read("anthropic_oauth")

      assert {:error, :reauthorization_required} =
               TokenSupervisor.refresh_entry("anthropic_oauth", entry,
                 plug: &permanent_400_plug/1
               )

      assert {:ok, stored} = Store.read("anthropic_oauth")
      assert stored.status == "reauthorization_required"
    end

    test "entries without a refresh token are unsupported (setup tokens never refresh)" do
      entry = %{anthropic_entry() | tokens: %{access_token: "at", refresh_token: nil}}

      assert {:error, :unsupported_provider} =
               TokenSupervisor.refresh_entry("anthropic_oauth", entry, [])
    end
  end

  describe "get_token/1 — direct fallback" do
    test "reuses a recently refreshed short-lived token" do
      :ok = Store.write("custom_oauth", short_lived_entry())

      assert {:ok, "old_at"} = TokenSupervisor.get_token("custom_oauth")
    end

    # A grant a sign-in quarantined is unexpired and otherwise servable, so the
    # refusal has to come off the stored entry. `Store.quarantine_reason/1` is
    # the one reader, so this answer is the same in the tree-less world where
    # `direct_read` resolves the token with no manager at all.
    test "refuses a grant the sign-in recorded as wrong_region" do
      profile = fresh_profile()

      :ok =
        Store.write(
          profile,
          %{short_lived_entry() | provider: "tesla"}
          |> Map.put(:status, "wrong_region")
          |> Map.put(:region, "na")
          |> Map.put(:region_actual, "eu")
        )

      assert {:error, :wrong_region} = TokenSupervisor.get_token(profile)
    end

    test "serves a grant whose region matches" do
      profile = fresh_profile()

      :ok =
        Store.write(
          profile,
          %{short_lived_entry() | provider: "tesla"}
          |> Map.put(:status, "ready")
          |> Map.put(:region, "eu")
        )

      assert {:ok, "old_at"} = TokenSupervisor.get_token(profile)
    end
  end

  # A manager caches the entry it read at init, so a case that reuses a profile
  # name another case already started reads that case's grant instead of its own.
  defp fresh_profile do
    profile = "tesla_#{System.unique_integer([:positive])}:primary"
    on_exit(fn -> TokenSupervisor.stop_profile(profile) end)
    profile
  end

  # TOKEN-6: a CLI logout deleted the entry in its own VM; the daemon's
  # `auth_forget` then lets go of what this VM still holds for the profile.
  describe "forget_signed_out/1" do
    test "drops a child's tokens and token file, stops it, and serves a later sign-in" do
      profile = "google_calendar:signout-#{System.unique_integer([:positive])}"
      on_exit(fn -> TokenSupervisor.stop_profile(profile) end)
      root = SafeRm.make_tmp_dir!("ts-signout-store")
      on_exit(fn -> SafeRm.rm_rf!(root) end)
      DistStore.ensure!(root)
      token_file = DistStore.token_file(root, profile)

      :ok = Store.write(profile, google_entry("old_at"))
      assert :ok = TokenSupervisor.enable_token_file(profile, token_file)
      assert %{"access_token" => "old_at"} = token_file |> File.read!() |> Jason.decode!()
      [{manager, _value}] = Registry.lookup(FermixCore.Auth.TokenRegistry, profile)
      down = Process.monitor(manager)

      # The CLI VM's logout.
      :ok = Store.delete_provider(profile)
      assert :ok = TokenSupervisor.forget_signed_out(profile)

      refute File.exists?(token_file)
      assert_receive {:DOWN, ^down, :process, ^manager, _reason}

      # The next use starts a fresh manager from auth.json, so a sign-in made
      # after the logout is served rather than refused.
      :ok = Store.write(profile, google_entry("fresh_at"))
      assert {:ok, "fresh_at"} = TokenSupervisor.get_token(profile)
    end

    test "tells the top-level Codex manager to forget, and leaves it running" do
      assert Process.whereis(TokenManager) == nil
      :ok = Store.write("openai_codex", %{anthropic_entry() | provider: "openai"})

      manager =
        start_supervised!({TokenManager, name: TokenManager, fermix_auth_path: Store.path()})

      assert {:ok, "old_at"} = TokenManager.get_token(TokenManager)

      :ok = Store.delete_provider("openai_codex")
      assert :ok = TokenSupervisor.forget_signed_out("openai_codex")

      assert {:error, :auth_invalidated} = TokenManager.get_token(TokenManager)
      assert Process.alive?(manager)
    end

    test "starts no manager for a profile nothing holds" do
      profile = "github:signout-#{System.unique_integer([:positive])}"

      assert :ok = TokenSupervisor.forget_signed_out(profile)
      assert Registry.lookup(FermixCore.Auth.TokenRegistry, profile) == []
    end

    # A manager can stop between the lookup and the call (a plugin reload, a
    # concurrent stop). The call then exits `:noproc`, the shape a stand-in
    # that exits with that reason on the call reproduces: nothing is held, so
    # the daemon must not report a failed forget.
    test "a child that is gone by the time it is called held nothing" do
      profile = "github:signout-gone-#{System.unique_integer([:positive])}"

      gone_on_call(fn ->
        {:ok, _owner} = Registry.register(FermixCore.Auth.TokenRegistry, profile, nil)
      end)

      assert :ok = TokenSupervisor.forget_signed_out(profile)
    end

    test "a Codex manager that is gone by the time it is called held nothing" do
      assert Process.whereis(TokenManager) == nil
      gone_on_call(fn -> Process.register(self(), TokenManager) end)

      assert :ok = TokenSupervisor.forget_signed_out("openai_codex")
    end
  end

  # A stand-in manager, registered by `register`, that exits `:noproc` on the
  # first call it receives: to its caller, a manager that died just before it.
  defp gone_on_call(register) do
    parent = self()

    stand_in =
      spawn(fn ->
        register.()
        send(parent, {:stand_in_registered, self()})

        receive do
          {:"$gen_call", _from, :forget} -> exit(:noproc)
        end
      end)

    on_exit(fn -> Process.exit(stand_in, :kill) end)
    assert_receive {:stand_in_registered, ^stand_in}
    stand_in
  end

  defp google_entry(access_token) do
    %{
      auth_mode: "oauth2",
      provider: "google",
      granted_scopes: [],
      tokens: %{access_token: access_token, refresh_token: "rt"},
      expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      last_refresh: nil,
      status: "ready"
    }
  end

  describe "refresh_entry/3 — plugin oauth providers (registry path)" do
    setup do
      previous = Application.get_env(:fermix_core, :oauth)

      Application.put_env(:fermix_core, :oauth, %{
        "google" => [
          client_type: "desktop_public_pkce",
          client_id: "g-id",
          client_secret: "g-sec"
        ],
        "github" => [
          client_type: "desktop_public_pkce",
          client_id: "gh-id",
          client_secret: "gh-sec"
        ],
        "notion" => [
          client_type: "desktop_public_pkce",
          client_id: "n-id",
          client_secret: "n-sec"
        ],
        "x" => [
          client_type: "desktop_public_pkce",
          client_id: "x-id",
          client_secret: "x-sec"
        ],
        "tesla" => [
          client_type: "desktop_public_pkce",
          client_id: "t-id",
          client_secret: "t-sec",
          region: "eu"
        ]
      })

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:fermix_core, :oauth)
          value -> Application.put_env(:fermix_core, :oauth, value)
        end
      end)

      :ok
    end

    defp plugin_oauth_entry(provider) do
      %{
        auth_mode: "oauth2",
        provider: provider,
        granted_scopes: ["a-scope"],
        tokens: %{access_token: "old_at", refresh_token: "old_rt"},
        expires_at: DateTime.add(DateTime.utc_now(), 60, :second),
        last_refresh: nil,
        status: "ready"
      }
    end

    test "refreshes a github entry through the provider registry" do
      :ok = Store.write("github:primary", plugin_oauth_entry("github"))
      {:ok, entry} = Store.read("github:primary")

      parent = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:refresh_request, URI.decode_query(body), conn.req_headers})
        refresh_plug(conn)
      end

      assert {:ok, refreshed} = TokenSupervisor.refresh_entry("github:primary", entry, plug: plug)
      assert refreshed.tokens.access_token == "new_at"

      assert {:ok, stored} = Store.read("github:primary")
      assert stored.tokens.access_token == "new_at"
      assert stored.provider == "github"

      assert_received {:refresh_request, params, headers}
      assert params["client_id"] == "gh-id"
      assert params["client_secret"] == "gh-sec"
      assert {"accept", "application/json"} in headers
    end

    test "refreshes a notion entry with HTTP Basic auth and rotates the pair" do
      :ok = Store.write("notion:primary", plugin_oauth_entry("notion"))
      {:ok, entry} = Store.read("notion:primary")

      parent = self()
      expected = "Basic " <> Base.encode64("n-id:n-sec")

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:refresh_request, URI.decode_query(body), conn.req_headers})
        refresh_plug(conn)
      end

      assert {:ok, refreshed} = TokenSupervisor.refresh_entry("notion:primary", entry, plug: plug)
      assert refreshed.tokens.access_token == "new_at"
      assert refreshed.tokens.refresh_token == "new_rt"

      assert_received {:refresh_request, params, headers}
      refute Map.has_key?(params, "client_secret")
      refute Map.has_key?(params, "client_id")
      assert {"authorization", expected} in headers
    end

    # The direct (process-less) dispatch is its own refresh owner with its own
    # entry update, so the region has to survive here as well as through
    # TokenManager — a rebuild rather than an update would strand the plugin
    # without a Fleet API region, which nothing downstream can re-derive.
    test "refreshes a tesla entry, keeps its region, and sends no exchange audience" do
      entry_with_region = Map.put(plugin_oauth_entry("tesla"), :region, "eu")
      :ok = Store.write("tesla:primary", entry_with_region)
      {:ok, entry} = Store.read("tesla:primary")
      assert entry.region == "eu"

      parent = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:refresh_request, URI.decode_query(body), conn.req_headers})
        refresh_plug(conn)
      end

      assert {:ok, refreshed} = TokenSupervisor.refresh_entry("tesla:primary", entry, plug: plug)
      assert refreshed.region == "eu"
      assert refreshed.tokens.access_token == "new_at"

      assert {:ok, stored} = Store.read("tesla:primary")
      assert stored.region == "eu"
      assert stored.tokens.refresh_token == "new_rt"

      assert_received {:refresh_request, params, _headers}
      assert params["grant_type"] == "refresh_token"
      assert params["client_id"] == "t-id"
      refute Map.has_key?(params, "audience")
    end

    test "refreshes an x entry with HTTP Basic auth and persists the rotated pair" do
      # X rotates refresh tokens on every refresh — the old one is invalidated,
      # so the new refresh_token from the response MUST land in the store or the
      # next refresh fails. X is the first provider whose tokens die without it.
      :ok = Store.write("x:primary", plugin_oauth_entry("x"))
      {:ok, entry} = Store.read("x:primary")

      parent = self()
      expected = "Basic " <> Base.encode64("x-id:x-sec")

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:refresh_request, URI.decode_query(body), conn.req_headers})
        refresh_plug(conn)
      end

      assert {:ok, refreshed} = TokenSupervisor.refresh_entry("x:primary", entry, plug: plug)
      assert refreshed.tokens.access_token == "new_at"
      assert refreshed.tokens.refresh_token == "new_rt"

      assert {:ok, stored} = Store.read("x:primary")
      assert stored.tokens.access_token == "new_at"
      assert stored.tokens.refresh_token == "new_rt"
      assert stored.provider == "x"

      assert_received {:refresh_request, params, headers}
      assert params["grant_type"] == "refresh_token"
      refute Map.has_key?(params, "client_secret")
      refute Map.has_key?(params, "client_id")
      assert {"authorization", expected} in headers
    end

    test "google still refreshes through the registry (regression)" do
      :ok = Store.write("google_calendar:primary", plugin_oauth_entry("google"))
      {:ok, entry} = Store.read("google_calendar:primary")

      assert {:ok, refreshed} =
               TokenSupervisor.refresh_entry("google_calendar:primary", entry,
                 plug: &refresh_plug/1
               )

      assert refreshed.tokens.access_token == "new_at"

      assert {:ok, stored} = Store.read("google_calendar:primary")
      assert stored.tokens.access_token == "new_at"
      assert stored.tokens.refresh_token == "new_rt"
    end

    test "unknown providers stay unsupported" do
      entry = plugin_oauth_entry("linear")

      assert {:error, :unsupported_provider} =
               TokenSupervisor.refresh_entry("linear:primary", entry, [])
    end

    test "a known provider without saved client config fails with needs_client_config" do
      Application.put_env(:fermix_core, :oauth, %{})
      entry = plugin_oauth_entry("github")

      assert {:error, :needs_client_config} =
               TokenSupervisor.refresh_entry("github:primary", entry, [])
    end

    # The tree-less direct path quarantines exactly as the supervised manager
    # does: the grant cannot renew under this client, so it is stored under its
    # true cause and the caller is handed the typed refusal to word.
    test "a refused client is stored as client_rejected and answered typed" do
      :ok = Store.write("x:primary", plugin_oauth_entry("x"))
      {:ok, entry} = Store.read("x:primary")

      refusing = fn conn ->
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

      assert {:error, {:oauth_client_rejected, detail}} =
               TokenSupervisor.refresh_entry("x:primary", entry, plug: refusing)

      assert detail.provider == "x"
      assert detail.error == "unauthorized_client"

      assert {:ok, stored} = Store.read("x:primary")
      assert stored.status == "client_rejected"
      assert stored.tokens.refresh_token == "old_rt"
    end

    test "a dead plugin grant is still quarantined as reauthorization_required" do
      :ok = Store.write("github:primary", plugin_oauth_entry("github"))
      {:ok, entry} = Store.read("github:primary")

      assert {:error, :reauthorization_required} =
               TokenSupervisor.refresh_entry("github:primary", entry, plug: &permanent_400_plug/1)

      assert {:ok, stored} = Store.read("github:primary")
      assert stored.status == "reauthorization_required"
    end

    # AGENTS.md rule 7: the quarantine status write can fail. Its error is
    # logged and answered rather than dropped.
    test "a failed reauthorization_required write is logged and answered" do
      :ok = Store.write("github:primary", plugin_oauth_entry("github"))
      {:ok, entry} = Store.read("github:primary")
      File.write!(Store.path(), "{ not json ")

      {result, log} =
        with_log(fn ->
          TokenSupervisor.refresh_entry("github:primary", entry, plug: &permanent_400_plug/1)
        end)

      assert {:error, {:malformed_auth_file, _path, _backup, {:invalid_json, _err}}} = result
      assert log =~ "could not record reauthorization_required for github:primary"
    end

    # TOKEN-2 (tla/specs/token_refresh, check 15): `fermix plugins auth
    # refresh` in a tree-less VM refreshes directly. While the daemon's manager
    # holds the profile lock mid-refresh, the direct refresh waits, then reads
    # the manager's rotation instead of presenting the token it consumed, and
    # its status write can no longer put that consumed token back.
    test "a direct refresh waits for the profile lock, then refreshes the newest token" do
      :ok = Store.write("github:primary", plugin_oauth_entry("github"))
      parent = self()

      holder =
        Task.async(fn ->
          Store.with_profile_lock("github:primary", Store.path(), fn ->
            send(parent, :held)

            receive do
              :go -> :ok
            end

            {:ok, entry} = Store.read("github:primary")
            rotated = %{access_token: "mgr_at", refresh_token: "mgr_rt"}
            Store.write("github:primary", %{entry | tokens: rotated})
          end)
        end)

      assert_receive :held

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:direct_sent, URI.decode_query(body)})
        refresh_plug(conn)
      end

      direct = Task.async(fn -> TokenSupervisor.direct_refresh("github:primary", plug: plug) end)
      refute_receive {:direct_sent, _form}, 300

      send(holder.pid, :go)
      assert :ok = Task.await(holder)
      assert {:ok, "new_at"} = Task.await(direct)
      assert_received {:direct_sent, %{"refresh_token" => "mgr_rt"}}

      assert {:ok, %{status: "ready", tokens: %{refresh_token: "new_rt"}}} =
               Store.read("github:primary")
    end

    # Config.auth_profile is operator-settable, so a profile name is untrusted
    # input to the lockfile name: it stays beside auth.json in FERMIX_HOME.
    test "a profile name with path separators keeps its lockfile in FERMIX_HOME" do
      home = Path.dirname(Store.path())
      profile = "../../outside/github:primary"

      lock_dir =
        Store.with_profile_lock(profile, Store.path(), fn ->
          home |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".lock"))
        end)

      assert lock_dir == [Path.basename(Store.profile_lock_path(profile, Store.path()))]
      assert Path.dirname(Store.profile_lock_path(profile, Store.path())) == home
      refute File.exists?(Path.join(home |> Path.dirname() |> Path.dirname(), "outside"))
    end
  end

  describe "refresh_entry/3 — xai" do
    defp xai_entry do
      %{anthropic_entry() | auth_mode: "oauth_pkce", provider: "xai"}
    end

    test "refreshes and persists; 403 is tier denial without quarantine" do
      :ok = Store.write("xai_oauth", xai_entry())
      {:ok, entry} = Store.read("xai_oauth")

      assert {:ok, refreshed} =
               TokenSupervisor.refresh_entry("xai_oauth", entry, plug: &refresh_plug/1)

      assert refreshed.tokens.access_token == "new_at"

      tier_denied = fn conn ->
        Plug.Conn.send_resp(conn, 403, ~s({"error":"no api access"}))
      end

      assert {:error, :xai_oauth_tier_denied} =
               TokenSupervisor.refresh_entry("xai_oauth", entry, plug: tier_denied)

      {:ok, stored} = Store.read("xai_oauth")
      refute stored.status == "reauthorization_required"
    end

    test "non-403 permanent failure quarantines the profile" do
      :ok = Store.write("xai_oauth", xai_entry())
      {:ok, entry} = Store.read("xai_oauth")

      assert {:error, :reauthorization_required} =
               TokenSupervisor.refresh_entry("xai_oauth", entry, plug: &permanent_400_plug/1)

      {:ok, stored} = Store.read("xai_oauth")
      assert stored.status == "reauthorization_required"
    end
  end
end
