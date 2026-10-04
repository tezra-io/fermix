defmodule FermixCore.IMessage.ControlTest do
  use ExUnit.Case, async: true

  alias FermixCore.IMessage.Control
  alias FermixTestSupport.SafeRm

  @probe %{
    "helper_version" => "0.1.0",
    "full_disk_access" => "granted",
    "db" => "readable",
    "automation" => "not_determined",
    "messages_running" => true,
    "signed_in" => "unknown",
    "user_session" => true,
    "policy" => "absent",
    "self_aliases" => nil
  }

  setup do
    dir = SafeRm.make_tmp_dir!("imessage-control")
    on_exit(fn -> SafeRm.rm_rf(dir) end)
    %{dir: dir}
  end

  describe "parse/2 (pure)" do
    test "a probe becomes the closed vocabulary" do
      assert {:ok, probe} = Control.parse(:probe, Jason.encode!(@probe))

      assert probe == %{
               helper_version: "0.1.0",
               full_disk_access: :granted,
               db: :readable,
               automation: :not_determined,
               messages_running: true,
               signed_in: :unknown,
               user_session: true,
               policy: :absent,
               self_aliases: nil
             }
    end

    test "a probe word outside the vocabulary is a protocol error naming the field" do
      frame = Jason.encode!(Map.put(@probe, "db", "sort_of"))

      assert Control.parse(:probe, frame) ==
               {:error, {:helper_protocol, {:invalid_field, "db", "sort_of"}}}
    end

    test "a probe missing a field is a protocol error naming the field" do
      frame = Jason.encode!(Map.delete(@probe, "user_session"))

      assert Control.parse(:probe, frame) ==
               {:error, {:helper_protocol, {:invalid_field, "user_session", nil}}}
    end

    test "an error object maps onto the closed helper error kinds" do
      frame = ~s({"error": {"kind": "policy_refused", "message": "Cancelled"}})

      assert Control.parse(:policy_set, frame) ==
               {:error, {:helper_error, :policy_refused, "Cancelled"}}
    end

    test "an error kind outside the closed set is refused, not passed through" do
      frame = ~s({"error": {"kind": "made_up", "message": "?"}})

      assert Control.parse(:probe, frame) ==
               {:error, {:helper_protocol, {:unknown_error_kind, "made_up"}}}
    end

    test "stdout that is not one JSON object is a protocol error" do
      assert Control.parse(:probe, "not json") == {:error, {:helper_protocol, :invalid_json}}
      assert Control.parse(:probe, "[1, 2]") == {:error, {:helper_protocol, :invalid_json}}
    end

    test "a stored policy and an absent one" do
      frame =
        Jason.encode!(%{
          "posture" => "dedicated_account",
          "owner_handle" => "+15551234567",
          "handles" => ["+15551234567", "friend@example.com"],
          "confirmed_at" => "2026-10-01T10:00:00Z"
        })

      assert Control.parse(:policy_get, frame) ==
               {:ok,
                %{
                  posture: :dedicated_account,
                  owner_handle: "+15551234567",
                  handles: ["+15551234567", "friend@example.com"],
                  confirmed_at: "2026-10-01T10:00:00Z"
                }}

      assert Control.parse(:policy_get, "null") == {:ok, nil}
    end

    test "a confirmed policy set" do
      assert Control.parse(:policy_set, ~s({"confirmed_at": "2026-10-01T10:00:00Z"})) ==
               {:ok, %{confirmed_at: "2026-10-01T10:00:00Z"}}
    end
  end

  describe "exit_error/1 (pure)" do
    test "the disclaim and protocol exit codes are typed classes" do
      assert Control.exit_error(64) == {:helper_exit, :usage}
      assert Control.exit_error(70) == {:helper_exit, :disclaim_unavailable}
      assert Control.exit_error(71) == {:helper_exit, :disclaim_refused}
      assert Control.exit_error(72) == {:helper_exit, :exec_failed}
      assert Control.exit_error(74) == {:helper_exit, :io}
      assert Control.exit_error(75) == {:helper_exit, :temporary}
      assert Control.exit_error(76) == {:helper_exit, :protocol}
      assert Control.exit_error(1) == {:helper_exit, {:unexpected, 1}}
    end
  end

  describe "the one-shot spawn" do
    test "probe runs the probe subcommand against the Fermix home", %{dir: dir} do
      binary = fake_helper(dir, Jason.encode!(@probe), 0)

      assert {:ok, %{full_disk_access: :granted}} =
               Control.probe(binary_path: binary, home: "/homes/fermix")

      assert recorded_args(dir) == ["probe", "--home", "/homes/fermix"]
    end

    test "grant names the service it asks for", %{dir: dir} do
      binary = fake_helper(dir, Jason.encode!(@probe), 0)

      assert {:ok, _probe} = Control.grant(:full_disk_access, binary_path: binary, home: "/h")
      assert recorded_args(dir) == ["grant", "--home", "/h", "--service", "full_disk_access"]
    end

    test "policy_set passes the posture, the owner and every handle", %{dir: dir} do
      binary = fake_helper(dir, ~s({"confirmed_at": "2026-10-01T10:00:00Z"}), 0)

      policy = %{
        posture: :dedicated_account,
        owner_handle: "+15551234567",
        handles: ["+15551234567", "friend@example.com"]
      }

      assert {:ok, %{confirmed_at: _at}} =
               Control.policy_set(policy, binary_path: binary, home: "/h")

      assert recorded_args(dir) == [
               "policy-set",
               "--home",
               "/h",
               "--posture",
               "dedicated_account",
               "--owner",
               "+15551234567",
               "--handle",
               "+15551234567",
               "--handle",
               "friend@example.com"
             ]
    end

    test "policy_get reads the stored policy", %{dir: dir} do
      binary = fake_helper(dir, "null", 0)

      assert Control.policy_get(binary_path: binary, home: "/h") == {:ok, nil}
      assert recorded_args(dir) == ["policy-get", "--home", "/h"]
    end

    test "an exit code names its class and stdout is not read", %{dir: dir} do
      binary = fake_helper(dir, "garbage", 71)

      assert Control.probe(binary_path: binary, home: "/h") ==
               {:error, {:helper_exit, :disclaim_refused}}
    end

    test "a helper that never answers is killed at the bound", %{dir: dir} do
      binary = fake_helper(dir, Jason.encode!(@probe), 0, sleep: 30)
      started = System.monotonic_time(:millisecond)

      assert Control.probe(binary_path: binary, home: "/h", timeout_ms: 200) == {:error, :timeout}
      assert System.monotonic_time(:millisecond) - started < 5_000
    end

    test "a missing helper is not installed, never a crash" do
      assert Control.probe(binary_path: "/nonexistent/fermix-messages", home: "/h") ==
               {:error, :not_installed}
    end
  end

  describe "policy_matches_config?/2" do
    @config [
      enabled: true,
      posture: :dedicated_account,
      owner_user_id: "+1 555 123 4567",
      allowed_sender_ids: ["Friend@Example.com"]
    ]

    test "the stored policy that names exactly the saved recipients matches" do
      policy = %{
        posture: :dedicated_account,
        owner_handle: "+15551234567",
        handles: ["friend@example.com", "+15551234567"],
        confirmed_at: "2026-10-01T10:00:00Z"
      }

      assert Control.policy_matches_config?(policy, @config)
    end

    test "a guest added since the confirmation does not match" do
      policy = %{
        posture: :dedicated_account,
        owner_handle: "+15551234567",
        handles: ["+15551234567"],
        confirmed_at: "2026-10-01T10:00:00Z"
      }

      refute Control.policy_matches_config?(policy, @config)
    end

    test "a different posture or owner does not match" do
      policy = %{
        posture: :own_account,
        owner_handle: "+15551234567",
        handles: ["+15551234567", "friend@example.com"],
        confirmed_at: "2026-10-01T10:00:00Z"
      }

      refute Control.policy_matches_config?(policy, @config)

      refute Control.policy_matches_config?(
               %{policy | posture: :dedicated_account, owner_handle: "+15550000000"},
               @config
             )
    end

    test "no stored policy, or no owner saved, never matches" do
      refute Control.policy_matches_config?(nil, @config)

      policy = %{
        posture: :dedicated_account,
        owner_handle: "+15551234567",
        handles: ["+15551234567"],
        confirmed_at: "2026-10-01T10:00:00Z"
      }

      refute Control.policy_matches_config?(policy, posture: :dedicated_account)
    end
  end

  test "policy_for_config/1 is the policy a confirmation sets from the saved section" do
    assert Control.policy_for_config(@config) ==
             {:ok,
              %{
                posture: :dedicated_account,
                owner_handle: "+15551234567",
                handles: ["+15551234567", "friend@example.com"]
              }}

    assert Control.policy_for_config(posture: :dedicated_account) == {:error, :owner_missing}
    assert Control.policy_for_config(owner_user_id: "+15551234567") == {:error, :posture_missing}
  end

  # A shell script standing in for the helper: it records its argv one per line
  # and prints the canned object, optionally after a delay.
  defp fake_helper(dir, stdout, status, opts \\ []) do
    path = Path.join(dir, "fermix-messages")
    sleep = Keyword.get(opts, :sleep)

    File.write!(path, """
    #!/bin/sh
    printf '%s\\n' "$@" > '#{Path.join(dir, "args")}'
    #{if sleep, do: "sleep #{sleep}", else: ""}
    printf '%s' '#{stdout}'
    exit #{status}
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp recorded_args(dir) do
    dir |> Path.join("args") |> File.read!() |> String.split("\n", trim: true)
  end
end
