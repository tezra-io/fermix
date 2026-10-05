defmodule Fermix.CLI.Doctor.IMessageCheckTest do
  @moduledoc """
  The two iMessage Doctor rows (M54 §10.4): the helper and its permissions.

  Both are non-prompting and both are hermetic here: the platform, the switch,
  the install, the signature check and the probe are injected, so no case
  reads this host, spawns a helper or touches a keychain.
  """

  use ExUnit.Case, async: true

  alias Fermix.CLI.Doctor.Checks

  @config [
    enabled: true,
    owner_user_id: "+15551234567",
    allowed_sender_ids: []
  ]

  @granted %{
    helper_version: "0.1.0",
    full_disk_access: :granted,
    db: :readable,
    automation: :granted,
    messages_running: true,
    signed_in: true,
    user_session: true,
    policy: :confirmed,
    self_aliases: nil
  }

  @matching_policy %{
    posture: :dedicated_account,
    owner_handle: "+15551234567",
    handles: ["+15551234567"],
    confirmed_at: "2026-10-01T10:00:00Z"
  }

  describe "imessage_helper/1" do
    test "off a Mac the row does not apply" do
      assert %{name: "imessage helper", status: :not_applicable} =
               Checks.imessage_helper(macos?: false, enabled?: true)
    end

    test "not installed while iMessage is off is quiet" do
      assert %{status: :ok, detail: detail} =
               Checks.imessage_helper(
                 macos?: true,
                 enabled?: false,
                 bundle: {:error, :not_installed}
               )

      assert detail =~ "not installed"
    end

    test "not installed while iMessage is on warns and says how to install it" do
      assert %{status: :warn, detail: detail} =
               Checks.imessage_helper(
                 macos?: true,
                 enabled?: true,
                 bundle: {:error, :not_installed}
               )

      assert detail =~ "Fermix Messages is not installed"
    end

    test "an installed bundle reports the pinned version and its verified signature" do
      assert %{status: :ok, detail: detail} =
               Checks.imessage_helper(
                 macos?: true,
                 enabled?: true,
                 bundle: {:ok, "/x/Fermix Messages.app"},
                 verify: fn "/x/Fermix Messages.app" -> :ok end
               )

      assert detail =~ "pinned 0.1.2"
      assert detail =~ "signature verified"
    end

    test "a bundle that fails codesign verification fails the row with codesign's words" do
      assert %{status: :fail, detail: detail} =
               Checks.imessage_helper(
                 macos?: true,
                 enabled?: true,
                 bundle: {:ok, "/x/Fermix Messages.app"},
                 verify: fn _app ->
                   {:error, {:helper_unverified, "a sealed resource is missing"}}
                 end
               )

      assert detail =~ "a sealed resource is missing"
    end
  end

  describe "imessage_permissions/1" do
    test "off a Mac the row does not apply" do
      assert %{name: "imessage permissions", status: :not_applicable} =
               Checks.imessage_permissions(macos?: false, enabled?: true)
    end

    test "iMessage off probes nothing" do
      assert %{status: :ok} =
               Checks.imessage_permissions(
                 macos?: true,
                 enabled?: false,
                 probe: fn -> flunk("probed while off") end
               )
    end

    test "every grant, the account and the confirmed recipients is ok" do
      assert %{status: :ok, detail: detail} = permissions(@granted, {:ok, @matching_policy})

      assert detail =~ "Full Disk Access: granted"
      assert detail =~ "automation: granted"
      assert detail =~ "recipients: confirmed"
    end

    test "missing Full Disk Access fails and names the exact identity to grant" do
      probe = %{@granted | full_disk_access: :denied, db: :unreadable}

      assert %{status: :fail, detail: detail} = permissions(probe, {:ok, @matching_policy})
      assert detail =~ "Fermix Messages, in Full Disk Access"
    end

    test "automation not yet asked warns" do
      probe = %{@granted | automation: :not_determined, signed_in: :unknown}

      assert %{status: :warn, detail: detail} = permissions(probe, {:ok, @matching_policy})
      assert detail =~ "automation: not asked yet"
    end

    test "recipients that differ from the saved settings are awaiting confirmation" do
      other = %{@matching_policy | handles: ["+15550000000"]}

      assert %{status: :warn, detail: detail} = permissions(@granted, {:ok, other})
      assert detail =~ "awaiting confirmation"
    end

    test "no stored policy is awaiting confirmation" do
      probe = %{@granted | policy: :absent}

      assert %{status: :warn, detail: detail} =
               permissions(probe, fn -> flunk("read a policy the probe says is absent") end)

      assert detail =~ "awaiting confirmation"
    end

    test "a probe that fails fails the row with the class" do
      assert %{status: :fail, detail: detail} =
               Checks.imessage_permissions(
                 macos?: true,
                 enabled?: true,
                 installed?: true,
                 config: @config,
                 probe: fn -> {:error, {:helper_exit, :disclaim_refused}} end
               )

      assert detail =~ "disclaim_refused"
    end

    test "a helper that is not installed cannot be probed" do
      assert %{status: :warn} =
               Checks.imessage_permissions(
                 macos?: true,
                 enabled?: true,
                 installed?: false,
                 probe: fn -> flunk("probed a helper that is not installed") end
               )
    end
  end

  defp permissions(probe, policy) do
    policy_reader = if is_function(policy, 0), do: policy, else: fn -> policy end

    Checks.imessage_permissions(
      macos?: true,
      enabled?: true,
      installed?: true,
      config: @config,
      probe: fn -> {:ok, probe} end,
      policy: policy_reader
    )
  end
end
