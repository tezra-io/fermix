defmodule FermixCore.Auth.TokenSupervisorTest do
  # async: false — mutates FERMIX_HOME so Store's default path is hermetic.
  use ExUnit.Case, async: false

  alias FermixCore.Auth.Store
  alias FermixCore.Auth.TokenSupervisor

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
