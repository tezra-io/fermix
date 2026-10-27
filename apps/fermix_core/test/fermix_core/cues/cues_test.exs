defmodule FermixCore.CuesTest do
  # `enabled?/0` reads the global `:cues` and `:memory` app env, so this module
  # establishes both and runs alone.
  use ExUnit.Case, async: false

  alias FermixCore.Cues

  setup do
    prior_cues = Application.fetch_env(:fermix_core, :cues)
    prior_memory = Application.fetch_env(:fermix_core, :memory)

    on_exit(fn ->
      restore(:cues, prior_cues)
      restore(:memory, prior_memory)
    end)

    Application.delete_env(:fermix_core, :cues)
    Application.put_env(:fermix_core, :memory, enabled: true)
    :ok
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:fermix_core, key, value)
  defp restore(key, :error), do: Application.delete_env(:fermix_core, key)

  test "enabled only with the flag on and memory on" do
    refute Cues.enabled?()

    Application.put_env(:fermix_core, :cues, enabled: true)
    assert Cues.enabled?()

    Application.put_env(:fermix_core, :memory, enabled: false)
    refute Cues.enabled?()
  end

  # Runtime checks ask whether the tree runs, never the switch: the tree starts
  # only at boot, so a live flip must neither half-enable nor half-disable.
  test "running only while the cue tree is up, whatever the switch says now" do
    Application.put_env(:fermix_core, :cues, enabled: true)
    assert Cues.enabled?()
    refute Cues.running?()

    true = Process.register(self(), FermixCore.Cues.Supervisor)
    assert Cues.running?()

    Application.put_env(:fermix_core, :cues, enabled: false)
    refute Cues.enabled?()
    assert Cues.running?()

    Process.unregister(FermixCore.Cues.Supervisor)
    refute Cues.running?()
  end

  test "ids carry their prefix and 24 random hex characters" do
    id = Cues.id("cgp")
    assert id =~ ~r/^cgp_[0-9a-f]{24}$/
    refute Cues.id("cgp") == id
    assert_raise FunctionClauseError, fn -> Cues.id("Not a prefix") end
  end

  test "wake-ups are no-ops while their receivers are absent" do
    assert Cues.wake_filters() == :ok
    assert Cues.wake_scheduler() == :ok
  end
end
