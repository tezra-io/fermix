defmodule FermixCore.Auth.TokenManagerPluginRefreshTest do
  # async: false — sets the global [fermix_core :oauth] client config the
  # provider registry reads during plugin-oauth refresh.
  use ExUnit.Case, async: false

  alias FermixCore.Auth.TokenManager

  setup do
    previous = Application.get_env(:fermix_core, :oauth)

    Application.put_env(:fermix_core, :oauth, %{
      "google" => [client_type: "desktop_public_pkce", client_id: "g-id", client_secret: "g-sec"],
      "github" => [
        client_type: "desktop_public_pkce",
        client_id: "gh-id",
        client_secret: "gh-sec"
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

  defp write_auth_file(dir, profile, provider) do
    path = Path.join(dir, "fermix_auth.json")

    File.write!(
      path,
      Jason.encode!(%{
        "version" => 2,
        "providers" => %{
          profile => %{
            "auth_mode" => "oauth2",
            "provider" => provider,
            "granted_scopes" => ["a-scope"],
            "tokens" => %{"access_token" => "old_at", "refresh_token" => "old_rt"},
            "expires_at" =>
              DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()
          }
        }
      })
    )

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
end
