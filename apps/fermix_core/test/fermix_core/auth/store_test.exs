defmodule FermixCore.Auth.StoreTest do
  use ExUnit.Case, async: true

  alias FermixCore.Auth.Store

  # `unique_integer` resets per BEAM run, so leftover files from prior test
  # runs would otherwise satisfy `read/2` and break the "missing file" tests.
  # Time-based suffix + on_exit cleanup keeps each path globally unique and
  # ensures the file does not survive to the next run.
  defp tmp_path do
    path =
      Path.join(
        System.tmp_dir!(),
        "fermix_store_#{System.system_time(:nanosecond)}_" <>
          "#{System.unique_integer([:positive, :monotonic])}.json"
      )

    ExUnit.Callbacks.on_exit(fn -> FermixTestSupport.SafeRm.rm(path) end)
    path
  end

  defp future_iso8601(seconds) do
    DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.to_iso8601()
  end

  describe "read/2" do
    test "returns no_auth_file when file is missing" do
      assert {:error, :no_auth_file} = Store.read(:openai, tmp_path())
    end

    test "reads new nested provider shape" do
      path = tmp_path()

      data = %{
        "version" => 1,
        "providers" => %{
          "openai" => %{
            "auth_mode" => "chatgpt",
            "tokens" => %{"access_token" => "AT", "refresh_token" => "RT"},
            "expires_at" => future_iso8601(3600)
          }
        }
      }

      File.write!(path, Jason.encode!(data))
      assert {:ok, entry} = Store.read(:openai, path)
      assert entry.tokens.access_token == "AT"
      assert entry.tokens.refresh_token == "RT"
      assert entry.auth_mode == "chatgpt"
      assert %DateTime{} = entry.expires_at
    end

    test "migrates flat M3-era shape into openai_codex provider" do
      path = tmp_path()

      flat = %{
        "auth_mode" => "chatgpt",
        "tokens" => %{"access_token" => "AT", "refresh_token" => "RT"},
        "expires_at" => future_iso8601(3600)
      }

      File.write!(path, Jason.encode!(flat))
      assert {:ok, entry} = Store.read(:openai_codex, path)
      assert entry.tokens.access_token == "AT"
      assert {:error, {:provider_missing, :openai}} = Store.read(:openai, path)
    end

    test "returns provider_missing when provider not present" do
      path = tmp_path()
      File.write!(path, Jason.encode!(%{"version" => 1, "providers" => %{}}))
      assert {:error, {:provider_missing, :openai}} = Store.read(:openai, path)
    end

    test "returns invalid_json when file is malformed" do
      path = tmp_path()
      File.write!(path, "not json")
      assert {:error, {:invalid_json, _}} = Store.read(:openai, path)
    end

    test "returns invalid_auth_entry when the entry has no access_token" do
      path = tmp_path()

      data = %{
        "version" => 2,
        "providers" => %{
          "openai_codex" => %{"auth_mode" => "chatgpt", "tokens" => %{"access_token" => ""}},
          "anthropic" => %{"auth_mode" => "oauth"}
        }
      }

      File.write!(path, Jason.encode!(data))

      assert {:error, {:invalid_auth_entry, :openai_codex, :missing_access_token}} =
               Store.read(:openai_codex, path)

      assert {:error, {:invalid_auth_entry, :anthropic, :missing_access_token}} =
               Store.read(:anthropic, path)
    end
  end

  describe "write/3" do
    test "writes nested provider shape and round-trips through read" do
      path = tmp_path()

      entry = %{
        auth_mode: "chatgpt",
        tokens: %{access_token: "new_at", refresh_token: "new_rt"},
        expires_at: DateTime.utc_now() |> DateTime.add(3600),
        last_refresh: nil
      }

      assert :ok = Store.write(:openai, entry, path)
      assert {:ok, %{tokens: %{access_token: "new_at"}}} = Store.read(:openai, path)
    end

    test "sets 0600 permissions on written file" do
      path = tmp_path()

      entry = %{
        auth_mode: "chatgpt",
        tokens: %{access_token: "at", refresh_token: nil},
        expires_at: nil,
        last_refresh: nil
      }

      assert :ok = Store.write(:openai, entry, path)
      assert {:ok, %{mode: mode}} = File.stat(path)
      # mode includes file-type bits; mask them off and check the user-rw-only pattern
      assert Bitwise.band(mode, 0o777) == 0o600
    end

    test "preserves other providers when writing one" do
      path = tmp_path()

      original = %{
        "version" => 1,
        "providers" => %{
          "openai" => %{
            "auth_mode" => "chatgpt",
            "tokens" => %{"access_token" => "openai_at", "refresh_token" => "openai_rt"}
          },
          "anthropic" => %{
            "auth_mode" => "api_key",
            "tokens" => %{"access_token" => "anthropic_at"}
          }
        }
      }

      File.write!(path, Jason.encode!(original))

      new_entry = %{
        auth_mode: "chatgpt",
        tokens: %{access_token: "openai_new", refresh_token: "openai_rt"},
        expires_at: nil,
        last_refresh: nil
      }

      assert :ok = Store.write(:openai, new_entry, path)

      {:ok, raw} = File.read(path)
      data = Jason.decode!(raw)

      assert data["providers"]["openai"]["tokens"]["access_token"] == "openai_new"
      assert data["providers"]["anthropic"]["tokens"]["access_token"] == "anthropic_at"
    end

    test "writes through atomic tmp+rename (no partial file remains)" do
      path = tmp_path()

      entry = %{
        auth_mode: "chatgpt",
        tokens: %{access_token: "at", refresh_token: nil},
        expires_at: nil,
        last_refresh: nil
      }

      assert :ok = Store.write(:openai, entry, path)

      tmp_pattern = Path.dirname(path) |> Path.join("#{Path.basename(path)}.tmp.*")
      assert Path.wildcard(tmp_pattern) == []
    end

    test "refuses to overwrite malformed auth.json; preserves the original at a backup path" do
      path = tmp_path()
      File.write!(path, "{ not json ")

      entry = %{
        auth_mode: "chatgpt",
        tokens: %{access_token: "at", refresh_token: nil},
        expires_at: nil,
        last_refresh: nil
      }

      assert {:error, {:malformed_auth_file, ^path, backup, {:invalid_json, _err}}} =
               Store.write(:openai, entry, path)

      assert is_binary(backup)
      assert File.exists?(backup)
      assert File.read!(backup) == "{ not json "
      assert File.read!(path) == "{ not json "
      ExUnit.Callbacks.on_exit(fn -> FermixTestSupport.SafeRm.rm(backup) end)
    end

    test "refuses to overwrite an auth.json with an unknown shape" do
      path = tmp_path()
      File.write!(path, Jason.encode!(%{"unknown" => "shape"}))

      entry = %{
        auth_mode: "chatgpt",
        tokens: %{access_token: "at", refresh_token: nil},
        expires_at: nil,
        last_refresh: nil
      }

      assert {:error, {:malformed_auth_file, ^path, backup, :unknown_shape}} =
               Store.write(:openai, entry, path)

      assert is_binary(backup)
      assert File.exists?(backup)
      ExUnit.Callbacks.on_exit(fn -> FermixTestSupport.SafeRm.rm(backup) end)
    end
  end

  describe "validate_permissions/1" do
    test "passes when auth file is missing" do
      assert :ok = Store.validate_permissions(tmp_path())
    end

    test "passes when auth file is 0600" do
      path = tmp_path()
      File.write!(path, "{}")
      File.chmod!(path, 0o600)

      assert :ok = Store.validate_permissions(path)
    end

    test "rejects widened auth file permissions with chmod guidance" do
      path = tmp_path()
      File.write!(path, "{}")
      File.chmod!(path, 0o644)

      assert {:error, {:insecure_permissions, ^path, 0o644}} = Store.validate_permissions(path)

      assert_raise ArgumentError, ~r/chmod 600/, fn ->
        Store.validate_permissions!(path)
      end
    end
  end

  describe "delete_provider/2" do
    test "removes a provider, preserves others, and writes with 0600 permissions" do
      path = tmp_path()

      File.write!(
        path,
        Jason.encode!(%{
          "version" => 1,
          "providers" => %{
            "openai" => %{
              "auth_mode" => "api_key",
              "tokens" => %{"access_token" => "sk-test", "refresh_token" => nil}
            },
            "openai_codex" => %{
              "auth_mode" => "chatgpt",
              "tokens" => %{"access_token" => "AT", "refresh_token" => "RT"}
            }
          }
        })
      )

      assert :ok = Store.delete_provider(:openai_codex, path)

      data = path |> File.read!() |> Jason.decode!()
      refute Map.has_key?(data["providers"], "openai_codex")
      assert data["providers"]["openai"]["tokens"]["access_token"] == "sk-test"
      assert {:ok, %{mode: mode}} = File.stat(path)
      assert Bitwise.band(mode, 0o777) == 0o600

      tmp_pattern = Path.dirname(path) |> Path.join("#{Path.basename(path)}.tmp.*")
      assert Path.wildcard(tmp_pattern) == []
    end

    test "deleting openai_codex from flat M3-era shape prevents stale token resurrection" do
      path = tmp_path()

      File.write!(
        path,
        Jason.encode!(%{
          "auth_mode" => "chatgpt",
          "tokens" => %{"access_token" => "AT", "refresh_token" => "RT"},
          "expires_at" => future_iso8601(3600)
        })
      )

      assert :ok = Store.delete_provider(:openai_codex, path)
      assert {:error, {:provider_missing, :openai_codex}} = Store.read(:openai_codex, path)
      assert {:error, {:provider_missing, :openai}} = Store.read(:openai, path)
    end
  end
end
