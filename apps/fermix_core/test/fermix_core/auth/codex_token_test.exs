defmodule FermixCore.Auth.CodexTokenTest do
  use ExUnit.Case, async: true

  alias FermixCore.Auth.CodexToken

  def refresh_plug(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    assert body =~ "refresh_token=old_rt"

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

  defp tmp_dir do
    Path.join(System.tmp_dir!(), "fermix_codex_token_#{System.unique_integer([:positive])}")
  end

  defp future_iso8601(seconds) do
    DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.to_iso8601()
  end

  defp write_auth_file(dir, entry) do
    File.mkdir_p!(dir)
    path = Path.join(dir, "auth.json")

    File.write!(
      path,
      Jason.encode!(%{
        "version" => 1,
        "providers" => %{
          "openai_codex" => entry
        }
      })
    )

    path
  end

  test "reads a usable token from the Fermix auth store" do
    dir = tmp_dir()
    on_exit(fn -> File.rm_rf!(dir) end)

    path =
      write_auth_file(dir, %{
        "auth_mode" => "chatgpt",
        "tokens" => %{"access_token" => "store_at", "refresh_token" => "rt"},
        "expires_at" => future_iso8601(3600)
      })

    assert {:ok, "store_at"} = CodexToken.get_token(fermix_auth_path: path)
  end

  test "refreshes and persists a token that is within the refresh window" do
    dir = tmp_dir()
    on_exit(fn -> File.rm_rf!(dir) end)

    path =
      write_auth_file(dir, %{
        "auth_mode" => "chatgpt",
        "tokens" => %{"access_token" => "old_at", "refresh_token" => "old_rt"},
        "expires_at" => future_iso8601(1)
      })

    assert {:ok, "new_at"} =
             CodexToken.get_token(
               fermix_auth_path: path,
               refresh_req_options: [plug: &__MODULE__.refresh_plug/1]
             )

    assert {:ok, raw} = File.read(path)
    data = Jason.decode!(raw)
    assert data["providers"]["openai_codex"]["tokens"]["access_token"] == "new_at"
    assert data["providers"]["openai_codex"]["tokens"]["refresh_token"] == "new_rt"
  end

  test "returns a visible error when an expired token has no refresh token" do
    dir = tmp_dir()
    on_exit(fn -> File.rm_rf!(dir) end)

    path =
      write_auth_file(dir, %{
        "auth_mode" => "chatgpt",
        "tokens" => %{"access_token" => "old_at", "refresh_token" => nil},
        "expires_at" => future_iso8601(-60)
      })

    assert {:error, :no_refresh_token} = CodexToken.get_token(fermix_auth_path: path)
  end

  test "returns a visible error when the auth store is missing" do
    dir = tmp_dir()
    on_exit(fn -> File.rm_rf!(dir) end)

    assert {:error, :no_auth_file} =
             CodexToken.get_token(fermix_auth_path: Path.join(dir, "missing-auth.json"))
  end
end
