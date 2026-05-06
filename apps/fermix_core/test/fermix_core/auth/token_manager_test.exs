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

  def noop_plug(conn), do: Plug.Conn.send_resp(conn, 500, "test-noop")

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

  defp start_manager(opts) do
    name = :"tm_#{System.unique_integer([:positive])}"
    opts = Keyword.put(opts, :name, name)
    opts = Keyword.put_new(opts, :req_options, plug: &__MODULE__.noop_plug/1)
    start_supervised!({TokenManager, opts})
    name
  end

  defp future_iso8601(seconds) do
    DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.to_iso8601()
  end

  describe "init — loading tokens" do
    test "loads from fermix auth file (new openai_codex provider shape)" do
      dir = tmp_dir()

      fermix_path =
        write_auth_file(dir, "fermix_auth.json", %{
          "version" => 1,
          "providers" => %{
            "openai_codex" => %{
              "auth_mode" => "chatgpt",
              "tokens" => %{"access_token" => "AT", "refresh_token" => "RT"},
              "expires_at" => future_iso8601(3600)
            }
          }
        })

      name = start_manager(fermix_auth_path: fermix_path)
      assert {:ok, "AT"} = TokenManager.get_token(name)

      File.rm_rf!(dir)
    end

    test "does not load openai provider tokens as Codex credentials" do
      dir = tmp_dir()

      fermix_path =
        write_auth_file(dir, "fermix_auth.json", %{
          "version" => 1,
          "providers" => %{
            "openai" => %{
              "auth_mode" => "chatgpt",
              "tokens" => %{"access_token" => "legacy_nested", "refresh_token" => "rt"},
              "expires_at" => future_iso8601(3600)
            }
          }
        })

      name = start_manager(fermix_auth_path: fermix_path)
      assert {:error, :no_token} = TokenManager.get_token(name)

      File.rm_rf!(dir)
    end

    test "migrates flat M3-era shape (top-level tokens) to nested provider scope" do
      dir = tmp_dir()

      fermix_path =
        write_auth_file(dir, "fermix_auth.json", %{
          "auth_mode" => "chatgpt",
          "tokens" => %{"access_token" => "legacy_at", "refresh_token" => "legacy_rt"},
          "expires_at" => future_iso8601(3600)
        })

      name = start_manager(fermix_auth_path: fermix_path)
      assert {:ok, "legacy_at"} = TokenManager.get_token(name)

      File.rm_rf!(dir)
    end

    test "returns error when no auth file exists" do
      dir = tmp_dir()
      name = start_manager(fermix_auth_path: Path.join(dir, "missing.json"))
      assert {:error, :no_token} = TokenManager.get_token(name)
    end
  end

  describe "get_token/1" do
    test "returns cached token across calls" do
      dir = tmp_dir()

      fermix_path =
        write_auth_file(dir, "fermix_auth.json", %{
          "version" => 1,
          "providers" => %{
            "openai_codex" => %{
              "auth_mode" => "chatgpt",
              "tokens" => %{"access_token" => "cached", "refresh_token" => "rt"},
              "expires_at" => future_iso8601(3600)
            }
          }
        })

      name = start_manager(fermix_auth_path: fermix_path)
      assert {:ok, "cached"} = TokenManager.get_token(name)
      assert {:ok, "cached"} = TokenManager.get_token(name)

      File.rm_rf!(dir)
    end
  end

  describe "refresh/1" do
    test "returns no_refresh_token when state has none" do
      dir = tmp_dir()

      fermix_path =
        write_auth_file(dir, "fermix_auth.json", %{
          "version" => 1,
          "providers" => %{
            "openai_codex" => %{
              "auth_mode" => "chatgpt",
              "tokens" => %{"access_token" => "tok"},
              "expires_at" => future_iso8601(3600)
            }
          }
        })

      name = start_manager(fermix_auth_path: fermix_path)
      assert {:error, :no_refresh_token} = TokenManager.refresh(name)

      File.rm_rf!(dir)
    end

    test "refreshes and persists to Auth.Store" do
      dir = tmp_dir()

      fermix_path =
        write_auth_file(dir, "fermix_auth.json", %{
          "version" => 1,
          "providers" => %{
            "openai_codex" => %{
              "auth_mode" => "chatgpt",
              "tokens" => %{"access_token" => "old_at", "refresh_token" => "old_rt"},
              "expires_at" => future_iso8601(3600)
            }
          }
        })

      name =
        start_manager(
          fermix_auth_path: fermix_path,
          req_options: [plug: &__MODULE__.refresh_plug/1]
        )

      assert {:ok, "new_at"} = TokenManager.refresh(name)
      assert {:ok, raw} = File.read(fermix_path)
      data = Jason.decode!(raw)
      assert data["providers"]["openai_codex"]["tokens"]["access_token"] == "new_at"
      assert data["providers"]["openai_codex"]["tokens"]["refresh_token"] == "new_rt"

      File.rm_rf!(dir)
    end
  end

  describe "permanent refresh failures" do
    def permanent_401_plug(conn) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        401,
        Jason.encode!(%{
          "error" => %{
            "code" => "refresh_token_reused",
            "message" => "Already used"
          }
        })
      )
    end

    test "marks state invalidated and surfaces :auth_invalidated to callers" do
      dir = tmp_dir()

      fermix_path =
        write_auth_file(dir, "fermix_auth.json", %{
          "version" => 1,
          "providers" => %{
            "openai_codex" => %{
              "auth_mode" => "chatgpt",
              "tokens" => %{"access_token" => "AT", "refresh_token" => "RT"},
              "expires_at" => future_iso8601(3600)
            }
          }
        })

      name =
        start_manager(
          fermix_auth_path: fermix_path,
          req_options: [plug: &__MODULE__.permanent_401_plug/1]
        )

      assert {:ok, "AT"} = TokenManager.get_token(name)
      assert {:error, :auth_invalidated} = TokenManager.refresh(name)
      assert {:error, :auth_invalidated} = TokenManager.get_token(name)
      # subsequent refresh attempts short-circuit instead of re-hitting the network
      assert {:error, :auth_invalidated} = TokenManager.refresh(name)
    end
  end

  describe "scheduled refresh" do
    test "stays alive when scheduled refresh fires and fails" do
      dir = tmp_dir()

      fermix_path =
        write_auth_file(dir, "fermix_auth.json", %{
          "version" => 1,
          "providers" => %{
            "openai_codex" => %{
              "auth_mode" => "chatgpt",
              "tokens" => %{"access_token" => "soon", "refresh_token" => "rt"},
              "expires_at" => future_iso8601(2)
            }
          }
        })

      name = start_manager(fermix_auth_path: fermix_path)
      assert {:ok, "soon"} = TokenManager.get_token(name)
      Process.sleep(1_500)
      assert Process.whereis(name) |> Process.alive?()

      File.rm_rf!(dir)
    end
  end
end
