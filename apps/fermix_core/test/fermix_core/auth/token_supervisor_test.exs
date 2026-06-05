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
