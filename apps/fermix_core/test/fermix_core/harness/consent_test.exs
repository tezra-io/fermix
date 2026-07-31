defmodule FermixCore.Harness.ConsentTest do
  # async: false — the gate reads the global `[fermix_core.harness]` app env
  # (`Config.approved?`). Consent is a setup decision (design §23.3): there is no
  # prompt, no approval seam, and no ConfigStore write anywhere in this path, so
  # the unit is a config read plus its guidance wording.
  use ExUnit.Case, async: false

  alias FermixCore.Harness.Consent

  setup do
    prior = Application.get_env(:fermix_core, :harness)
    on_exit(fn -> restore(prior) end)
    :ok
  end

  describe "ensure_approved/0" do
    test "an approved machine returns :ok" do
      Application.put_env(:fermix_core, :harness, approved: true)
      assert :ok = Consent.ensure_approved()
    end

    test "an unapproved machine returns {:error, :consent_required}" do
      Application.put_env(:fermix_core, :harness, approved: false)
      assert {:error, :consent_required} = Consent.ensure_approved()
    end

    test "the default (key absent) is unapproved" do
      Application.put_env(:fermix_core, :harness, [])
      assert {:error, :consent_required} = Consent.ensure_approved()
    end
  end

  describe "scheduled_guidance/0" do
    test "points at the setup surface and the config key, with no tap-to-approve language" do
      guidance = Consent.scheduled_guidance()

      assert guidance =~ "not yet approved on this machine"
      assert guidance =~ "Setup → Coding Agents"
      assert guidance =~ "[fermix_core.harness] approved = true"

      # The interactive path is gone: no prompt, button, token, or "Always allow".
      refute guidance =~ "Always allow"
      refute guidance =~ "prompt"
      refute guidance =~ "/confirm"
      refute guidance =~ "button"
    end
  end

  defp restore(nil), do: Application.delete_env(:fermix_core, :harness)
  defp restore(prior), do: Application.put_env(:fermix_core, :harness, prior)
end
