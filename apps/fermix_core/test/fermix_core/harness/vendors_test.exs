defmodule FermixCore.Harness.VendorsTest do
  # async: false — the binary-detection cases mutate the process PATH so the real
  # System.find_executable resolves the fake CLIs (a sync test never runs
  # concurrently with another). Version probing runs the fakes with
  # supervised: false (no CommandHost tree). Auth-state cases inject the config
  # dirs so nothing reads the operator's real ~/.codex / ~/.claude.
  use ExUnit.Case, async: false

  alias FermixCore.Harness.Vendors

  setup do
    bin = FermixTestSupport.SafeRm.make_tmp_dir!("harness-vendors-bin")
    write_fake(bin, "codex", "codex-cli 9.9.9")
    write_fake(bin, "claude", "9.9.9 (Claude Code)")

    original_path = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> (original_path || ""))

    on_exit(fn ->
      restore_path(original_path)
      FermixTestSupport.SafeRm.rm_rf!(bin)
    end)

    %{bin: bin}
  end

  describe "detect/2 — binary + version on a temp PATH" do
    test "codex resolves to the fake binary and its version line", %{bin: bin} do
      codex_home = home_with_auth("harness-vendors-codex")

      detection = Vendors.detect("codex", supervised: false, codex_home: codex_home)

      assert detection.vendor == "codex"
      assert detection.binary == Path.join(bin, "codex")
      assert detection.available? == true
      assert detection.version == "codex-cli 9.9.9"
      assert detection.auth == :authenticated
    end

    test "claude resolves to the fake binary and its version line", %{bin: bin} do
      config_dir = FermixTestSupport.SafeRm.make_tmp_dir!("harness-vendors-claude-cfg")
      File.write!(Path.join(config_dir, ".credentials.json"), ~s({"claudeAiOauth":{}}))
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(config_dir) end)

      detection = Vendors.detect("claude", supervised: false, claude_config_dir: config_dir)

      assert detection.binary == Path.join(bin, "claude")
      assert detection.available? == true
      assert detection.version == "9.9.9 (Claude Code)"
      assert detection.auth == :authenticated
    end

    test "available?/2 reflects PATH presence" do
      assert Vendors.available?("codex")
      assert Vendors.available?("claude")
    end
  end

  describe "detect/2 — a missing binary" do
    test "reports unavailable with no version and no probe" do
      detection = Vendors.detect("codex", find_executable: fn _name -> nil end)

      assert detection.binary == nil
      assert detection.available? == false
      assert detection.version == nil
    end

    test "available?/2 is false with an injected miss" do
      refute Vendors.available?("codex", find_executable: fn _name -> nil end)
    end
  end

  describe "network-free auth state" do
    test "codex is :authenticated only with a non-empty refresh token" do
      with_token = home_with_auth("harness-vendors-codex-auth")
      without = FermixTestSupport.SafeRm.make_tmp_dir!("harness-vendors-codex-noauth")
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(without) end)

      assert Vendors.detect("codex", find_executable: fn _ -> nil end, codex_home: with_token).auth ==
               :authenticated

      assert Vendors.detect("codex", find_executable: fn _ -> nil end, codex_home: without).auth ==
               :absent
    end

    test "claude is :unverified when the config dir exists but carries no credentials file" do
      config_dir = FermixTestSupport.SafeRm.make_tmp_dir!("harness-vendors-claude-unverified")
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(config_dir) end)

      detection =
        Vendors.detect("claude", find_executable: fn _ -> nil end, claude_config_dir: config_dir)

      assert detection.auth == :unverified
    end

    test "claude is :absent when the config dir does not exist" do
      missing =
        Path.join(
          System.tmp_dir!(),
          "fermix-vendors-absent-#{System.unique_integer([:positive])}"
        )

      detection =
        Vendors.detect("claude", find_executable: fn _ -> nil end, claude_config_dir: missing)

      assert detection.auth == :absent
    end
  end

  describe "binary/2 — absolute resolution with no version/auth probe" do
    test "resolves the injected absolute path" do
      resolver = fn "codex" -> "/opt/fake/bin/codex" end
      assert Vendors.binary("codex", find_executable: resolver) == {:ok, "/opt/fake/bin/codex"}
    end

    test "a miss is a clean cli_unavailable" do
      assert Vendors.binary("codex", find_executable: fn _ -> nil end) ==
               {:error, :cli_unavailable}
    end
  end

  describe "detect_all/1" do
    test "keys every supported vendor" do
      all = Vendors.detect_all(find_executable: fn _ -> nil end)
      assert Map.keys(all) |> Enum.sort() == ["claude", "codex"]
    end
  end

  describe "advertise_vendor?/1 — default_vendor gates advertisement" do
    setup do
      prior_harness = Application.get_env(:fermix_core, :harness)
      prior_detector = Application.get_env(:fermix_core, :harness_vendor_detector)

      on_exit(fn ->
        restore_env(:harness, prior_harness)
        restore_env(:harness_vendor_detector, prior_detector)
      end)

      :ok
    end

    test "no default_vendor → both advertise, even with both installed" do
      put_detector(true, true)
      Application.delete_env(:fermix_core, :harness)

      assert Vendors.advertise_vendor?("codex")
      assert Vendors.advertise_vendor?("claude")
    end

    test "default_vendor codex + both installed → only codex advertises" do
      put_detector(true, true)
      Application.put_env(:fermix_core, :harness, default_vendor: "codex")

      assert Vendors.advertise_vendor?("codex")
      refute Vendors.advertise_vendor?("claude")
    end

    test "default_vendor claude + both installed → only claude advertises" do
      put_detector(true, true)
      Application.put_env(:fermix_core, :harness, default_vendor: "claude")

      refute Vendors.advertise_vendor?("codex")
      assert Vendors.advertise_vendor?("claude")
    end

    test "the non-default vendor advertises when it is the sole installed option" do
      # default is codex, but codex is NOT installed — claude is the only option.
      put_detector(false, true)
      Application.put_env(:fermix_core, :harness, default_vendor: "codex")

      assert Vendors.advertise_vendor?("claude")
    end

    test "only codex installed → codex advertises regardless of default_vendor" do
      put_detector(true, false)
      Application.put_env(:fermix_core, :harness, default_vendor: "claude")

      assert Vendors.advertise_vendor?("codex")
    end

    test "fails open (both advertise) when detection raises" do
      Application.put_env(:fermix_core, :harness_vendor_detector, fn -> raise "boom" end)
      Application.put_env(:fermix_core, :harness, default_vendor: "codex")

      # codex is the default → true without detection; claude needs detection,
      # which raises → fail open → true (advertise? must never crash).
      assert Vendors.advertise_vendor?("codex")
      assert Vendors.advertise_vendor?("claude")
    end
  end

  defp put_detector(codex_available?, claude_available?) do
    detections = %{
      "codex" => %{vendor: "codex", available?: codex_available?},
      "claude" => %{vendor: "claude", available?: claude_available?}
    }

    Application.put_env(:fermix_core, :harness_vendor_detector, fn -> detections end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore_env(key, value), do: Application.put_env(:fermix_core, key, value)

  defp write_fake(bin, name, version_line) do
    path = Path.join(bin, name)
    File.write!(path, "#!/bin/sh\necho \"#{version_line}\"\n")
    File.chmod!(path, 0o755)
  end

  defp home_with_auth(prefix) do
    home = FermixTestSupport.SafeRm.make_tmp_dir!(prefix)
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
    File.write!(Path.join(home, "auth.json"), ~s({"tokens":{"refresh_token":"rt-abc"}}))
    home
  end

  defp restore_path(nil), do: System.delete_env("PATH")
  defp restore_path(value), do: System.put_env("PATH", value)
end
