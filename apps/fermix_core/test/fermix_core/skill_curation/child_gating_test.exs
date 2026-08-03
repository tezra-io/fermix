defmodule FermixCore.SkillCuration.ChildGatingTest do
  # async: false — exercises the enabled/memory branches through global app env.
  use ExUnit.Case, async: false

  alias FermixCore.Application, as: CoreApplication
  alias FermixCore.SkillCuration.Scheduler, as: SkillCurationScheduler

  setup do
    skill_curation = Application.get_env(:fermix_core, :skill_curation, [])
    memory = Application.get_env(:fermix_core, :memory, [])

    on_exit(fn ->
      Application.put_env(:fermix_core, :skill_curation, skill_curation)
      Application.put_env(:fermix_core, :memory, memory)
    end)

    :ok
  end

  test "the child is absent under mix test regardless of config" do
    Application.put_env(:fermix_core, :skill_curation, enabled: true)
    Application.put_env(:fermix_core, :memory, enabled: true)

    # The compile-time env gate dominates: `mix test` never starts the clock,
    # even with everything else switched on (the env-flag-is-not-an-env-gate
    # lesson).
    assert CoreApplication.maybe_skill_curation_scheduler() == []
  end

  test "outside test env the child requires enabled config AND memory" do
    Application.put_env(:fermix_core, :skill_curation, enabled: true)
    Application.put_env(:fermix_core, :memory, enabled: true)
    assert CoreApplication.maybe_skill_curation_scheduler(:prod) == [SkillCurationScheduler]

    Application.put_env(:fermix_core, :skill_curation, enabled: false)
    assert CoreApplication.maybe_skill_curation_scheduler(:prod) == []

    Application.put_env(:fermix_core, :skill_curation, enabled: true)
    Application.put_env(:fermix_core, :memory, enabled: false)
    assert CoreApplication.maybe_skill_curation_scheduler(:prod) == []
  end

  test "default config is on (absent key means enabled)" do
    Application.put_env(:fermix_core, :skill_curation, [])
    Application.put_env(:fermix_core, :memory, [])

    assert CoreApplication.maybe_skill_curation_scheduler(:prod) == [SkillCurationScheduler]
  end
end
