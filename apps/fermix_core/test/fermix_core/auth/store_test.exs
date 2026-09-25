defmodule FermixCore.Auth.StoreTest do
  use ExUnit.Case, async: true

  alias FermixCore.Auth.RefreshClient
  alias FermixCore.Auth.Store
  alias FermixTestSupport.SafeRm

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

  describe "list_profiles/1" do
    test "returns an empty list when the auth file is missing" do
      assert {:ok, []} = Store.list_profiles(tmp_path())
    end

    test "returns every profile with a normalized entry" do
      path = tmp_path()

      File.write!(
        path,
        Jason.encode!(%{
          "version" => 1,
          "providers" => %{
            "openai_codex" => %{
              "auth_mode" => "chatgpt",
              "tokens" => %{"access_token" => "AT1", "refresh_token" => "RT1"},
              "expires_at" => future_iso8601(3600)
            },
            "gmail:primary" => %{
              "auth_mode" => "oauth2",
              "tokens" => %{"access_token" => "AT2", "refresh_token" => "RT2"},
              "expires_at" => future_iso8601(-7200)
            }
          }
        })
      )

      assert {:ok, profiles} = Store.list_profiles(path)
      by_name = Map.new(profiles)

      assert Map.has_key?(by_name, "openai_codex")
      assert Map.has_key?(by_name, "gmail:primary")
      assert %DateTime{} = by_name["openai_codex"].expires_at
    end

    test "skips entries without a usable access token" do
      path = tmp_path()

      File.write!(
        path,
        Jason.encode!(%{
          "version" => 1,
          "providers" => %{
            "openai" => %{
              "tokens" => %{"access_token" => "AT"},
              "expires_at" => future_iso8601(3600)
            },
            "broken" => %{"tokens" => %{"access_token" => ""}}
          }
        })
      )

      assert {:ok, profiles} = Store.list_profiles(path)
      names = Enum.map(profiles, &elem(&1, 0))

      assert "openai" in names
      refute "broken" in names
    end
  end

  # A regional provider (Tesla) records which Fleet API region its grant was
  # minted for, because the refresh path and the plugin's HTTP host both need it
  # and neither can re-derive it from the tokens.
  describe "region" do
    defp oauth_entry(extra) do
      Map.merge(
        %{
          auth_mode: "oauth2",
          provider: "tesla",
          granted_scopes: ["openid"],
          tokens: %{access_token: "AT", refresh_token: "RT"},
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          last_refresh: nil,
          status: "ready"
        },
        extra
      )
    end

    test "write/read round-trips the region through JSON" do
      path = tmp_path()

      assert :ok = Store.write("tesla:primary", oauth_entry(%{region: "eu"}), path)
      assert {:ok, entry} = Store.read("tesla:primary", path)
      assert entry.region == "eu"

      # The serialized key is a plain JSON string, not an inspected atom.
      stored = path |> File.read!() |> Jason.decode!() |> get_in(["providers", "tesla:primary"])
      assert Map.fetch!(stored, "region") == "eu"
    end

    test "a provider with no region reads back nil, and writes no region key" do
      path = tmp_path()

      assert :ok = Store.write("github:primary", oauth_entry(%{provider: "github"}), path)
      assert {:ok, entry} = Store.read("github:primary", path)
      assert entry.region == nil

      stored = path |> File.read!() |> Jason.decode!() |> get_in(["providers", "github:primary"])
      refute Map.has_key?(stored, "region")
    end

    test "a rewrite without a region keeps the stored one (merge, not clobber)" do
      path = tmp_path()

      assert :ok = Store.write("tesla:primary", oauth_entry(%{region: "na"}), path)
      assert :ok = Store.write("tesla:primary", oauth_entry(%{}), path)

      assert {:ok, entry} = Store.read("tesla:primary", path)
      assert entry.region == "na"
    end

    # The region the account is actually in, recorded beside the chosen one when
    # a sign-in finds they disagree. It travels the same way the chosen region
    # does, so a row reading the pair back gets both or neither.
    test "write/read round-trips the account's own region beside the chosen one" do
      path = tmp_path()

      entry = oauth_entry(%{region: "na", region_actual: "eu", status: "wrong_region"})
      assert :ok = Store.write("tesla:primary", entry, path)

      assert {:ok, read} = Store.read("tesla:primary", path)
      assert read.region == "na"
      assert read.region_actual == "eu"
      assert read.status == "wrong_region"

      stored = path |> File.read!() |> Jason.decode!() |> get_in(["providers", "tesla:primary"])
      assert Map.fetch!(stored, "region_actual") == "eu"
    end

    test "a grant with no mismatch reads back nil, and writes no key for it" do
      path = tmp_path()

      assert :ok = Store.write("tesla:primary", oauth_entry(%{region: "na"}), path)
      assert {:ok, entry} = Store.read("tesla:primary", path)
      assert entry.region_actual == nil

      stored = path |> File.read!() |> Jason.decode!() |> get_in(["providers", "tesla:primary"])
      refute Map.has_key?(stored, "region_actual")
    end

    # A refresh rewrites the tokens and the status and nothing else, so the pair
    # a row reads survives one unchanged rather than being re-derived from a
    # token response that never carried it.
    test "the keys a refreshed grant carries survive a round trip" do
      path = tmp_path()

      stored = oauth_entry(%{region: "na", region_actual: "eu", status: "wrong_region"})
      assert :ok = Store.write("tesla:primary", stored, path)
      assert {:ok, entry} = Store.read("tesla:primary", path)

      refreshed = %{
        entry
        | tokens: %{access_token: "AT2", refresh_token: "RT2"},
          status: "ready"
      }

      assert :ok = Store.write("tesla:primary", refreshed, path)
      assert {:ok, read} = Store.read("tesla:primary", path)

      assert read.status == "ready"
      assert read.region == "na"
      assert read.region_actual == "eu"
      assert read.tokens.access_token == "AT2"
    end
  end

  # One directory per test, so a lockfile a test leaves behind (or holds on
  # purpose) can never meet another test's.
  defp locked_home do
    dir = SafeRm.make_tmp_dir!("auth-store-lock")
    ExUnit.Callbacks.on_exit(fn -> SafeRm.rm_rf!(dir) end)
    Path.join(dir, "auth.json")
  end

  defp plain_entry(access) do
    %{
      auth_mode: "oauth2",
      tokens: %{access_token: access, refresh_token: "rt"},
      expires_at: nil,
      last_refresh: nil
    }
  end

  # A lockfile another VM holds: its mtime is now, so it is not stale.
  defp hold_lock!(lock), do: File.write!(lock, "0 another-vm\n")

  defp listed_names(path) do
    {:ok, listed} = Store.list_profiles(path)
    listed |> Enum.map(&elem(&1, 0)) |> Enum.sort()
  end

  # TOKEN-1 (tla/specs/token_refresh): every profile's manager, CLI VMs,
  # sign-ins and logouts write this one file, so without a cross-VM lock one
  # writer's rename can land between another's read and rename and drop it.
  describe "the store lock" do
    test "a write waits while another VM holds the store lock, then merges" do
      path = locked_home()
      :ok = Store.write("a:primary", plain_entry("a_at"), path)
      lock = Store.store_lock_path(path)
      hold_lock!(lock)

      writer = Task.async(fn -> Store.write("b:primary", plain_entry("b_at"), path) end)
      assert Task.yield(writer, 300) == nil

      SafeRm.rm!(lock)
      assert Task.await(writer) == :ok
      assert listed_names(path) == ["a:primary", "b:primary"]
    end

    test "a delete waits while another VM holds the store lock" do
      path = locked_home()
      :ok = Store.write("a:primary", plain_entry("a_at"), path)
      :ok = Store.write("b:primary", plain_entry("b_at"), path)
      lock = Store.store_lock_path(path)
      hold_lock!(lock)

      deleter = Task.async(fn -> Store.delete_provider("b:primary", path) end)
      assert Task.yield(deleter, 300) == nil

      SafeRm.rm!(lock)
      assert Task.await(deleter) == :ok
      assert listed_names(path) == ["a:primary"]
    end

    # A VM that died holding the lock leaves its file behind. Past the stale
    # threshold it is a dead holder's, and one wait breaks it.
    test "a lockfile a dead holder left is broken, and the write goes through" do
      path = locked_home()
      lock = Store.store_lock_path(path)
      hold_lock!(lock)
      File.touch!(lock, System.os_time(:second) - 60)

      assert :ok = Store.write("a:primary", plain_entry("a_at"), path)
      refute File.exists?(lock)
      assert {:ok, %{tokens: %{access_token: "a_at"}}} = Store.read("a:primary", path)
    end

    # Regression guard, not a fail-first reproduction: without the lock this
    # loses entries only when two renames happen to interleave. Waiters poll in
    # lockstep, one winner per 100 ms round, so the last of 16 waits 15 rounds,
    # well inside the 80-attempt budget.
    test "concurrent writers of distinct profiles keep every entry (regression guard)" do
      path = locked_home()
      profiles = for n <- 1..16, do: "p#{n}:primary"

      profiles
      |> Task.async_stream(&Store.write(&1, plain_entry(&1), path),
        max_concurrency: 16,
        timeout: 30_000
      )
      |> Enum.each(fn result -> assert result == {:ok, :ok} end)

      assert listed_names(path) == Enum.sort(profiles)
    end
  end

  describe "the profile lock" do
    # Every taker (a refresh, a sign-in, an import, a logout) waits the same
    # bounded time, then gives up with one typed answer and runs nothing, so a
    # sign-in refuses before it spends a code or another tool's refresh token.
    test "a lock another holder keeps past the wait is :profile_busy, and nothing runs" do
      path = locked_home()
      hold_lock!(Store.profile_lock_path("github:primary", path))
      parent = self()

      assert {:error, :profile_busy} =
               Store.with_profile_lock("github:primary", path, fn -> send(parent, :ran) end)

      refute_received :ran
    end
  end

  # A lockfile's age is judged from its whole-second mtime, so it can read up
  # to a second older or younger than it is. Each bound below keeps that
  # second of margin.
  describe "lock bounds" do
    defp wait_ms(opts), do: Keyword.fetch!(opts, :attempts) * Keyword.fetch!(opts, :delay_ms)

    # The profile lock is broken once it looks older than its stale threshold,
    # so a live refresh must always finish first: every attempt at its full
    # timeouts, the sleeps between them, and two store-lock waits.
    test "a live refresh finishes inside the profile lock's stale threshold" do
      section_ms = RefreshClient.worst_case_ms() + 2 * wait_ms(Store.lock_opts(:store))

      assert section_ms + 1_000 < Keyword.fetch!(Store.lock_opts(:profile), :stale_after_ms)
    end

    # A sign-in holds the profile lock from before it spends anything to its
    # write: at most three requests (the code exchange, the account lookup and
    # a region probe), each one bounded attempt, then one store-lock wait. The
    # Codex import's section is one refresh and one write, inside the bound
    # above.
    test "a sign-in finishes inside the profile lock's stale threshold" do
      bounds = RefreshClient.request_bounds()
      assert Keyword.fetch!(bounds, :retry) == false

      request_ms =
        Keyword.fetch!(bounds, :pool_timeout) +
          Keyword.fetch!(Keyword.fetch!(bounds, :connect_options), :timeout) +
          Keyword.fetch!(bounds, :receive_timeout)

      section_ms = 3 * request_ms + wait_ms(Store.lock_opts(:store))

      assert section_ms + 1_000 < Keyword.fetch!(Store.lock_opts(:profile), :stale_after_ms)
    end

    # A store writer never gives up on a dead holder's lockfile: it waits
    # longer than it takes to go stale. A profile-lock taker gives up first
    # (`:profile_busy`) and is retried by its caller.
    test "a store writer outwaits a dead holder" do
      opts = Store.lock_opts(:store)
      assert wait_ms(opts) > Keyword.fetch!(opts, :stale_after_ms) + 1_000
    end
  end
end
