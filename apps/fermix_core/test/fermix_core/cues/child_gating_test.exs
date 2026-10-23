defmodule FermixCore.Cues.ChildGatingTest do
  # async: false — exercises the enabled/memory branches through global app env.
  use ExUnit.Case, async: false

  alias FermixCore.Application, as: CoreApplication
  alias FermixCore.Cues.Supervisor, as: CuesSupervisor

  setup do
    cues = Application.get_env(:fermix_core, :cues)
    memory = Application.get_env(:fermix_core, :memory, [])

    on_exit(fn ->
      case cues do
        nil -> Application.delete_env(:fermix_core, :cues)
        value -> Application.put_env(:fermix_core, :cues, value)
      end

      Application.put_env(:fermix_core, :memory, memory)
    end)

    :ok
  end

  test "the tree is absent under mix test, whatever the config says" do
    Application.put_env(:fermix_core, :cues, enabled: true)
    Application.put_env(:fermix_core, :memory, enabled: true)

    assert CoreApplication.maybe_cues_supervisor() == []
  end

  test "outside test it needs the switch on and memory on" do
    Application.put_env(:fermix_core, :cues, enabled: true)
    Application.put_env(:fermix_core, :memory, enabled: true)
    assert CoreApplication.maybe_cues_supervisor(:dev) == [CuesSupervisor]

    Application.put_env(:fermix_core, :cues, enabled: false)
    assert CoreApplication.maybe_cues_supervisor(:dev) == []

    Application.put_env(:fermix_core, :cues, enabled: true)
    Application.put_env(:fermix_core, :memory, enabled: false)
    assert CoreApplication.maybe_cues_supervisor(:dev) == []
  end

  test "the switch is off when nothing is configured" do
    Application.put_env(:fermix_core, :cues, [])
    Application.put_env(:fermix_core, :memory, enabled: true)

    assert CoreApplication.maybe_cues_supervisor(:dev) == []
  end

  test "the cue tree is the last child of the core tree" do
    source = File.read!(Path.expand("../../../lib/fermix_core/application.ex", __DIR__))
    [children] = Regex.run(~r/children =\s*\[(.*?)\n      \]/s, source, capture: :all_but_first)

    assert children |> String.trim_trailing() |> String.ends_with?("maybe_cues_supervisor()")
  end
end
