defmodule FermixCore.Auth.TokenManagerTest do
  use ExUnit.Case, async: true

  alias FermixCore.Auth.Store
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

    test "reuses a recently refreshed short-lived token" do
      dir = tmp_dir()
      test_pid = self()

      fermix_path =
        write_auth_file(dir, "fermix_auth.json", %{
          "version" => 1,
          "providers" => %{
            "openai_codex" => %{
              "auth_mode" => "chatgpt",
              "tokens" => %{"access_token" => "old_at", "refresh_token" => "old_rt"},
              "expires_at" => future_iso8601(1)
            }
          }
        })

      refresh_plug = fn conn ->
        send(test_pid, :refresh_called)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "access_token" => "new_at",
            "refresh_token" => "new_rt",
            "expires_in" => 60
          })
        )
      end

      name = start_manager(fermix_auth_path: fermix_path, req_options: [plug: refresh_plug])
      assert {:ok, "new_at"} = TokenManager.get_token(name)
      assert_receive :refresh_called
      assert {:ok, "new_at"} = TokenManager.get_token(name)
      refute_receive :refresh_called, 100

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

  describe "lazy refresh" do
    test "does not refresh after startup without a get_token or explicit refresh call" do
      dir = tmp_dir()
      test_pid = self()

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

      refresh_plug = fn conn ->
        send(test_pid, :refresh_called)
        __MODULE__.refresh_plug(conn)
      end

      _name = start_manager(fermix_auth_path: fermix_path, req_options: [plug: refresh_plug])
      refute_receive :refresh_called, 1_500

      FermixTestSupport.SafeRm.rm_rf!(dir)
    end

    test "stays alive when lazy refresh fails during get_token" do
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

  describe "proactive refresh" do
    test "refreshes in the background before expiry without an explicit token request" do
      dir = tmp_dir()

      path =
        write_auth_file(dir, "auth.json", %{
          "version" => 1,
          "providers" => %{
            "openai_codex" => %{
              "auth_mode" => "chatgpt",
              "tokens" => %{"access_token" => "old_at", "refresh_token" => "old_rt"},
              "expires_at" => future_iso8601(5)
            }
          }
        })

      # ~500ms of headroom before the margin — the one-shot timer fires well
      # before the 5s expiry, and nothing calls get_token (so this is purely the
      # proactive path, not a lazy on-use refresh).
      start_manager(
        fermix_auth_path: path,
        req_options: [plug: &__MODULE__.refresh_plug/1],
        proactive_refresh_margin_ms: 4_500
      )

      assert eventually(fn ->
               match?(
                 {:ok, %{tokens: %{access_token: "new_at"}}},
                 Store.read(:openai_codex, path)
               )
             end)

      FermixTestSupport.SafeRm.rm_rf!(dir)
    end

    test "refresh uses the latest refresh token from the store, not a stale in-memory copy" do
      dir = tmp_dir()

      path =
        write_auth_file(dir, "auth.json", %{
          "version" => 1,
          "providers" => %{
            "openai_codex" => %{
              "auth_mode" => "chatgpt",
              "tokens" => %{"access_token" => "at", "refresh_token" => "rt_A"},
              "expires_at" => future_iso8601(3600)
            }
          }
        })

      test_pid = self()

      capture_plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:refresh_body, body})

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

      name = start_manager(fermix_auth_path: path, req_options: [plug: capture_plug])

      # A doctor/CLI probe rotates the refresh token in the store out-of-band.
      write_auth_file(dir, "auth.json", %{
        "version" => 1,
        "providers" => %{
          "openai_codex" => %{
            "auth_mode" => "chatgpt",
            "tokens" => %{"access_token" => "at", "refresh_token" => "rt_B"},
            "expires_at" => future_iso8601(3600)
          }
        }
      })

      assert {:ok, _} = TokenManager.refresh(name)
      assert_receive {:refresh_body, body}
      assert body =~ "rt_B", "refresh must use the latest stored token"
      refute body =~ "rt_A", "refresh must not reuse the stale in-memory token"

      FermixTestSupport.SafeRm.rm_rf!(dir)
    end
  end

  defp eventually(fun, deadline_ms \\ 2_000) do
    poll(fun, System.monotonic_time(:millisecond) + deadline_ms)
  end

  defp poll(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(20)
        poll(fun, deadline)
    end
  end
end
