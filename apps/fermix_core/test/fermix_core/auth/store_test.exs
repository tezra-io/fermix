defmodule FermixCore.Auth.StoreTest do
  use ExUnit.Case, async: true

  alias FermixCore.Auth.Store

  defp tmp_path do
    Path.join(System.tmp_dir!(), "fermix_store_#{System.unique_integer([:positive])}.json")
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

    test "migrates flat M3-era shape into openai provider" do
      path = tmp_path()

      flat = %{
        "auth_mode" => "chatgpt",
        "tokens" => %{"access_token" => "AT", "refresh_token" => "RT"},
        "expires_at" => future_iso8601(3600)
      }

      File.write!(path, Jason.encode!(flat))
      assert {:ok, entry} = Store.read(:openai, path)
      assert entry.tokens.access_token == "AT"
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
  end
end
