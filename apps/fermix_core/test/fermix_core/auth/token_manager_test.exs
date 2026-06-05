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

      FermixTestSupport.SafeRm.rm_rf!(dir)
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

      FermixTestSupport.SafeRm.rm_rf!(dir)
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

      FermixTestSupport.SafeRm.rm_rf!(dir)
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

      FermixTestSupport.SafeRm.rm_rf!(dir)
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

      FermixTestSupport.SafeRm.rm_rf!(dir)
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

      FermixTestSupport.SafeRm.rm_rf!(dir)
    end
  end

  describe "anthropic_oauth refresh" do
    defp write_anthropic_auth(dir) do
      write_auth_file(dir, "fermix_auth.json", %{
        "version" => 2,
        "providers" => %{
          "anthropic_oauth" => %{
            "auth_mode" => "claude_code_import",
            "provider" => "anthropic",
            "tokens" => %{"access_token" => "old_at", "refresh_token" => "old_rt"},
            "expires_at" => future_iso8601(3600)
          }
        }
      })
    end

    test "refreshes via the Anthropic token endpoint and persists the entry" do
      dir = tmp_dir()
      fermix_path = write_anthropic_auth(dir)

      name =
        start_manager(
          auth_profile: "anthropic_oauth",
          fermix_auth_path: fermix_path,
          req_options: [plug: &__MODULE__.refresh_plug/1]
        )

      assert {:ok, "new_at"} = TokenManager.refresh(name)

      assert {:ok, raw} = File.read(fermix_path)
      data = Jason.decode!(raw)
      entry = data["providers"]["anthropic_oauth"]
      assert entry["tokens"]["access_token"] == "new_at"
      assert entry["tokens"]["refresh_token"] == "new_rt"
      assert entry["provider"] == "anthropic"
      assert entry["status"] == "ready"

      FermixTestSupport.SafeRm.rm_rf!(dir)
    end

    test "permanent refresh failure marks the profile reauthorization_required" do
      dir = tmp_dir()
      fermix_path = write_anthropic_auth(dir)

      name =
        start_manager(
          auth_profile: "anthropic_oauth",
          fermix_auth_path: fermix_path,
          req_options: [plug: &__MODULE__.permanent_400_plug/1]
        )

      assert {:error, :reauthorization_required} = TokenManager.refresh(name)

      assert {:ok, raw} = File.read(fermix_path)
      data = Jason.decode!(raw)
      assert data["providers"]["anthropic_oauth"]["status"] == "reauthorization_required"

      FermixTestSupport.SafeRm.rm_rf!(dir)
    end

    def permanent_400_plug(conn) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        400,
        Jason.encode!(%{"error" => "invalid_grant"})
      )
    end
  end

  describe "xai_oauth refresh" do
    defp write_xai_auth(dir) do
      write_auth_file(dir, "fermix_auth.json", %{
        "version" => 2,
        "providers" => %{
          "xai_oauth" => %{
            "auth_mode" => "oauth_pkce",
            "provider" => "xai",
            "tokens" => %{"access_token" => "old_at", "refresh_token" => "old_rt"},
            "expires_at" => future_iso8601(3600)
          }
        }
      })
    end

    test "refreshes via the xAI token endpoint and persists the entry" do
      dir = tmp_dir()
      fermix_path = write_xai_auth(dir)

      name =
        start_manager(
          auth_profile: "xai_oauth",
          fermix_auth_path: fermix_path,
          req_options: [plug: &__MODULE__.refresh_plug/1]
        )

      assert {:ok, "new_at"} = TokenManager.refresh(name)

      assert {:ok, raw} = File.read(fermix_path)
      entry = Jason.decode!(raw)["providers"]["xai_oauth"]
      assert entry["tokens"]["access_token"] == "new_at"
      assert entry["provider"] == "xai"
      assert entry["status"] == "ready"

      FermixTestSupport.SafeRm.rm_rf!(dir)
    end

    test "403 surfaces tier denial without quarantining the profile" do
      dir = tmp_dir()
      fermix_path = write_xai_auth(dir)

      name =
        start_manager(
          auth_profile: "xai_oauth",
          fermix_auth_path: fermix_path,
          req_options: [plug: &__MODULE__.tier_denied_403_plug/1]
        )

      assert {:error, :xai_oauth_tier_denied} = TokenManager.refresh(name)

      # Tokens kept, no reauthorization_required status (design doc §6.5).
      assert {:ok, raw} = File.read(fermix_path)
      entry = Jason.decode!(raw)["providers"]["xai_oauth"]
      assert entry["tokens"]["refresh_token"] == "old_rt"
      refute entry["status"] == "reauthorization_required"

      FermixTestSupport.SafeRm.rm_rf!(dir)
    end

    test "400 invalid_grant quarantines the profile" do
      dir = tmp_dir()
      fermix_path = write_xai_auth(dir)

      name =
        start_manager(
          auth_profile: "xai_oauth",
          fermix_auth_path: fermix_path,
          req_options: [plug: &__MODULE__.permanent_400_plug/1]
        )

      assert {:error, :reauthorization_required} = TokenManager.refresh(name)

      assert {:ok, raw} = File.read(fermix_path)
      assert Jason.decode!(raw)["providers"]["xai_oauth"]["status"] == "reauthorization_required"

      FermixTestSupport.SafeRm.rm_rf!(dir)
    end

    def tier_denied_403_plug(conn) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(403, Jason.encode!(%{"error" => "plan does not include API access"}))
    end

    def jwt_refresh_plug(conn) do
      header = Base.url_encode64(~s({"alg":"none"}), padding: false)

      payload =
        %{"exp" => System.os_time(:second) + 3600}
        |> Jason.encode!()
        |> Base.url_encode64(padding: false)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "access_token" => "#{header}.#{payload}.sig",
          "refresh_token" => "new_rt"
        })
      )
    end

    test "a refresh response without expires_in derives expiry from the JWT exp claim" do
      dir = tmp_dir()
      fermix_path = write_xai_auth(dir)

      name =
        start_manager(
          auth_profile: "xai_oauth",
          fermix_auth_path: fermix_path,
          req_options: [plug: &__MODULE__.jwt_refresh_plug/1]
        )

      assert {:ok, _token} = TokenManager.refresh(name)

      assert {:ok, raw} = File.read(fermix_path)
      entry = Jason.decode!(raw)["providers"]["xai_oauth"]
      # Without the JWT fallback this would be nil and scheduled refresh
      # would silently stop (design doc §6.4).
      assert is_binary(entry["expires_at"])

      FermixTestSupport.SafeRm.rm_rf!(dir)
    end

    test "a scheduled refresh hitting tier denial stops the timer instead of looping" do
      dir = tmp_dir()
      fermix_path = write_xai_auth(dir)

      name =
        start_manager(
          auth_profile: "xai_oauth",
          fermix_auth_path: fermix_path,
          req_options: [plug: &__MODULE__.tier_denied_403_plug/1]
        )

      pid = Process.whereis(name)
      send(pid, :refresh)

      # The manager must survive and must NOT re-arm the retry timer —
      # a 403 entitlement denial can never be fixed by retrying (§6.5).
      :ok = wait_until(fn -> :sys.get_state(pid).refresh_timer == nil end)
      assert Process.alive?(pid)

      FermixTestSupport.SafeRm.rm_rf!(dir)
    end

    test "a scheduled refresh hitting a permanent failure stops instead of looping" do
      dir = tmp_dir()
      fermix_path = write_xai_auth(dir)

      name =
        start_manager(
          auth_profile: "xai_oauth",
          fermix_auth_path: fermix_path,
          req_options: [plug: &__MODULE__.permanent_400_plug/1]
        )

      pid = Process.whereis(name)
      send(pid, :refresh)

      :ok = wait_until(fn -> :sys.get_state(pid).invalidated end)
      assert :sys.get_state(pid).refresh_timer == nil
      assert Process.alive?(pid)

      FermixTestSupport.SafeRm.rm_rf!(dir)
    end

    defp wait_until(fun, attempts \\ 50)
    defp wait_until(_fun, 0), do: {:error, :timeout}

    defp wait_until(fun, attempts) do
      if fun.() do
        :ok
      else
        Process.sleep(10)
        wait_until(fun, attempts - 1)
      end
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
      assert {:error, "Refresh failed (500): \"test-noop\""} = TokenManager.get_token(name)
      Process.sleep(1_500)
      assert Process.whereis(name) |> Process.alive?()

      FermixTestSupport.SafeRm.rm_rf!(dir)
    end
  end

  describe "reload/1" do
    test "re-reads tokens from disk and replaces the in-memory access token" do
      dir = tmp_dir()

      fermix_path =
        write_auth_file(dir, "fermix_auth.json", %{
          "version" => 1,
          "providers" => %{
            "openai_codex" => %{
              "auth_mode" => "chatgpt",
              "tokens" => %{"access_token" => "stale_at", "refresh_token" => "stale_rt"},
              "expires_at" => future_iso8601(3600)
            }
          }
        })

      name = start_manager(fermix_auth_path: fermix_path)
      assert {:ok, "stale_at"} = TokenManager.get_token(name)

      File.write!(
        fermix_path,
        Jason.encode!(%{
          "version" => 1,
          "providers" => %{
            "openai_codex" => %{
              "auth_mode" => "chatgpt",
              "tokens" => %{"access_token" => "fresh_at", "refresh_token" => "fresh_rt"},
              "expires_at" => future_iso8601(3600)
            }
          }
        })
      )

      assert {:ok, "fresh_at"} = TokenManager.reload(name)
      assert {:ok, "fresh_at"} = TokenManager.get_token(name)

      FermixTestSupport.SafeRm.rm_rf!(dir)
    end

    test "clears invalidated state so subsequent get_token calls succeed" do
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

      assert {:error, :auth_invalidated} = TokenManager.refresh(name)
      assert {:error, :auth_invalidated} = TokenManager.get_token(name)

      File.write!(
        fermix_path,
        Jason.encode!(%{
          "version" => 1,
          "providers" => %{
            "openai_codex" => %{
              "auth_mode" => "chatgpt",
              "tokens" => %{"access_token" => "recovered_at", "refresh_token" => "recovered_rt"},
              "expires_at" => future_iso8601(3600)
            }
          }
        })
      )

      assert {:ok, "recovered_at"} = TokenManager.reload(name)
      assert {:ok, "recovered_at"} = TokenManager.get_token(name)

      FermixTestSupport.SafeRm.rm_rf!(dir)
    end

    test "returns error and preserves cached state when disk read fails" do
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

      FermixTestSupport.SafeRm.rm!(fermix_path)
      assert {:error, :no_auth_file} = TokenManager.reload(name)
      assert {:ok, "AT"} = TokenManager.get_token(name)

      FermixTestSupport.SafeRm.rm_rf!(dir)
    end
  end
end
