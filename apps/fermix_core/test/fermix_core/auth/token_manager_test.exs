defmodule FermixCore.Auth.TokenManagerTest do
  use ExUnit.Case, async: true

  alias FermixCore.Auth.TokenManager

  @moduletag :token_manager

  defp tmp_dir do
    Path.join(System.tmp_dir!(), "fermix_tm_#{System.unique_integer([:positive])}")
  end

  defp write_auth_file(dir, filename, data) do
    File.mkdir_p!(dir)
    path = Path.join(dir, filename)
    File.write!(path, Jason.encode!(data))
    path
  end

  defp make_jwt_with_exp(exp_unix) do
    header = Base.url_encode64("{}", padding: false)
    payload = Base.url_encode64(Jason.encode!(%{"exp" => exp_unix}), padding: false)
    "#{header}.#{payload}.fake_signature"
  end

  defp start_manager(opts) do
    name = :"tm_#{System.unique_integer([:positive])}"
    opts = Keyword.put(opts, :name, name)
    start_supervised!({TokenManager, opts})
    name
  end

  describe "init — loading tokens" do
    test "loads from fermix auth file when available" do
      dir = tmp_dir()

      fermix_path =
        write_auth_file(dir, "fermix_auth.json", %{
          "tokens" => %{
            "access_token" => "fermix_token",
            "refresh_token" => "fermix_refresh"
          },
          "expires_at" => DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()
        })

      codex_path = Path.join(dir, "codex_auth.json")

      name = start_manager(fermix_auth_path: fermix_path, codex_auth_path: codex_path)
      assert {:ok, "fermix_token"} = TokenManager.get_token(name)

      File.rm_rf!(dir)
    end

    test "falls back to codex auth file when fermix file missing" do
      dir = tmp_dir()
      exp = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_unix()
      jwt = make_jwt_with_exp(exp)

      codex_path =
        write_auth_file(dir, "codex_auth.json", %{
          "auth_mode" => "chatgpt",
          "tokens" => %{
            "access_token" => jwt,
            "refresh_token" => "codex_refresh"
          }
        })

      fermix_path = Path.join(dir, "fermix_auth.json")

      name = start_manager(fermix_auth_path: fermix_path, codex_auth_path: codex_path)
      assert {:ok, ^jwt} = TokenManager.get_token(name)

      File.rm_rf!(dir)
    end

    test "returns error when no auth files exist" do
      dir = tmp_dir()

      name =
        start_manager(
          fermix_auth_path: Path.join(dir, "nope1.json"),
          codex_auth_path: Path.join(dir, "nope2.json")
        )

      assert {:error, :no_token} = TokenManager.get_token(name)
    end

    test "prefers fermix file over codex file" do
      dir = tmp_dir()

      fermix_path =
        write_auth_file(dir, "fermix_auth.json", %{
          "tokens" => %{
            "access_token" => "fermix_wins",
            "refresh_token" => "r"
          },
          "expires_at" => DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()
        })

      codex_path =
        write_auth_file(dir, "codex_auth.json", %{
          "auth_mode" => "chatgpt",
          "tokens" => %{
            "access_token" => "codex_loses",
            "refresh_token" => "r"
          }
        })

      name = start_manager(fermix_auth_path: fermix_path, codex_auth_path: codex_path)
      assert {:ok, "fermix_wins"} = TokenManager.get_token(name)

      File.rm_rf!(dir)
    end
  end

  describe "get_token/1" do
    test "returns cached token" do
      dir = tmp_dir()

      fermix_path =
        write_auth_file(dir, "auth.json", %{
          "tokens" => %{"access_token" => "cached", "refresh_token" => "r"},
          "expires_at" => DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()
        })

      name = start_manager(fermix_auth_path: fermix_path, codex_auth_path: Path.join(dir, "x"))
      assert {:ok, "cached"} = TokenManager.get_token(name)
      assert {:ok, "cached"} = TokenManager.get_token(name)

      File.rm_rf!(dir)
    end
  end

  describe "refresh/1" do
    test "returns error when no refresh token" do
      dir = tmp_dir()

      fermix_path =
        write_auth_file(dir, "auth.json", %{
          "tokens" => %{"access_token" => "tok"},
          "expires_at" => DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()
        })

      name = start_manager(fermix_auth_path: fermix_path, codex_auth_path: Path.join(dir, "x"))
      assert {:error, :no_refresh_token} = TokenManager.refresh(name)

      File.rm_rf!(dir)
    end
  end

  describe "JWT exp decoding" do
    test "reads codex token with valid JWT exp" do
      dir = tmp_dir()
      future_exp = DateTime.utc_now() |> DateTime.add(7200) |> DateTime.to_unix()
      jwt = make_jwt_with_exp(future_exp)

      codex_path =
        write_auth_file(dir, "codex.json", %{
          "auth_mode" => "chatgpt",
          "tokens" => %{"access_token" => jwt, "refresh_token" => "r"}
        })

      name =
        start_manager(
          fermix_auth_path: Path.join(dir, "nope.json"),
          codex_auth_path: codex_path
        )

      assert {:ok, ^jwt} = TokenManager.get_token(name)

      File.rm_rf!(dir)
    end

    test "handles non-JWT codex token gracefully" do
      dir = tmp_dir()

      codex_path =
        write_auth_file(dir, "codex.json", %{
          "auth_mode" => "chatgpt",
          "tokens" => %{"access_token" => "not-a-jwt", "refresh_token" => "r"}
        })

      name =
        start_manager(
          fermix_auth_path: Path.join(dir, "nope.json"),
          codex_auth_path: codex_path
        )

      # Still loads the token, just without expiry scheduling
      assert {:ok, "not-a-jwt"} = TokenManager.get_token(name)

      File.rm_rf!(dir)
    end
  end

  describe "scheduled refresh" do
    test "sends :refresh message when token is near expiry" do
      dir = tmp_dir()

      # Token expires in 2 seconds — refresh_skew is 90s, so min delay kicks in (1s)
      fermix_path =
        write_auth_file(dir, "auth.json", %{
          "tokens" => %{"access_token" => "soon_expired", "refresh_token" => "r"},
          "expires_at" => DateTime.utc_now() |> DateTime.add(2) |> DateTime.to_iso8601()
        })

      name = start_manager(fermix_auth_path: fermix_path, codex_auth_path: Path.join(dir, "x"))

      # The refresh will fire but fail (no real endpoint) — that's expected.
      # We just verify the token was loaded and the GenServer stays alive.
      assert {:ok, "soon_expired"} = TokenManager.get_token(name)
      Process.sleep(1_500)
      assert Process.whereis(name) |> Process.alive?()

      File.rm_rf!(dir)
    end
  end
end
