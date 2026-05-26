defmodule FermixCore.Auth.StoreV2Test do
  use ExUnit.Case, async: true

  alias FermixCore.Auth.Store

  defp tmp_path do
    path =
      Path.join(
        System.tmp_dir!(),
        "fermix_store_v2_#{System.system_time(:nanosecond)}_" <>
          "#{System.unique_integer([:positive, :monotonic])}.json"
      )

    on_exit(fn -> FermixTestSupport.SafeRm.rm(path) end)
    path
  end

  test "reads v2 plugin auth metadata" do
    path = tmp_path()

    File.write!(
      path,
      Jason.encode!(%{
        "version" => 2,
        "providers" => %{
          "google_calendar:primary" => %{
            "auth_mode" => "oauth2",
            "provider" => "google",
            "account" => %{"email" => "suj@example.com", "subject" => "sub-1"},
            "scope_profile" => "readonly",
            "granted_scopes" => ["openid", "email"],
            "tokens" => %{"access_token" => "AT", "refresh_token" => "RT"},
            "expires_at" => DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601(),
            "status" => "ready"
          }
        }
      })
    )

    assert {:ok, entry} = Store.read("google_calendar:primary", path)
    assert entry.provider == "google"
    assert entry.account.email == "suj@example.com"
    assert entry.scope_profile == "readonly"
    assert entry.granted_scopes == ["openid", "email"]
    assert entry.status == "ready"
  end

  test "refresh writes preserve v2 plugin metadata" do
    path = tmp_path()

    entry = %{
      auth_mode: "oauth2",
      provider: "google",
      account: %{email: "suj@example.com", subject: "sub-1"},
      scope_profile: "readonly",
      granted_scopes: ["openid", "email"],
      tokens: %{access_token: "old_at", refresh_token: "old_rt"},
      expires_at: DateTime.utc_now() |> DateTime.add(3600),
      last_refresh: nil,
      status: "ready"
    }

    assert :ok = Store.write("google_calendar:primary", entry, path)

    refreshed = %{
      entry
      | tokens: %{access_token: "new_at", refresh_token: "new_rt"},
        expires_at: DateTime.utc_now() |> DateTime.add(7200)
    }

    assert :ok = Store.write("google_calendar:primary", refreshed, path)

    data = path |> File.read!() |> Jason.decode!()
    profile = data["providers"]["google_calendar:primary"]

    assert data["version"] == 2
    assert profile["provider"] == "google"
    assert profile["account"]["email"] == "suj@example.com"
    assert profile["scope_profile"] == "readonly"
    assert profile["granted_scopes"] == ["openid", "email"]
    assert profile["status"] == "ready"
    assert profile["tokens"]["access_token"] == "new_at"
    assert profile["tokens"]["refresh_token"] == "new_rt"
  end
end
