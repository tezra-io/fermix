defmodule FermixCore.Setup.ReleaseBootConfigTest do
  @moduledoc """
  A release boot must keep every setting the file hydrated, including the
  sections the compile-time config also pins.

  The release's config provider reads sys.config, evaluates `runtime.exs`, and
  then re-applies the merged configuration over the application environment
  (`reboot_system_after_config` is false). `bootstrap_runtime_config/1` writes
  the file's values with `put_env` from inside that evaluation, so a key that
  sys.config also carries is overwritten by the provider unless `runtime.exs`
  restates it as configuration. `[fermix_core.meetings] enabled = true` came
  back as `false` on every restart of the app engine and the formula binary
  for exactly this reason, while every runtime save applied it.

  Nothing here evaluates `runtime.exs`; it reproduces the provider's own
  arithmetic with `Config.Reader.merge/2` over the compile-time config and the
  restatement `runtime.exs` emits, which is the merge the provider applies last.
  """
  use ExUnit.Case, async: false

  alias FermixCore.Setup.ConfigStore

  @config_exs Path.expand("../../../../../config/config.exs", __DIR__)

  setup do
    core = Application.get_all_env(:fermix_core)
    channels = Application.get_all_env(:fermix_channels)

    on_exit(fn ->
      Enum.each(core, fn {k, v} -> Application.put_env(:fermix_core, k, v) end)
      Enum.each(channels, fn {k, v} -> Application.put_env(:fermix_channels, k, v) end)
    end)

    {:ok, compiled: Config.Reader.read!(@config_exs, env: :prod)}
  end

  # The mechanism, stated so a reader can see why the restatement exists: the
  # compile-time config pins the sections the boot hydrates, so a bare
  # `put_env` for them is undone by the provider's final merge.
  test "the compile-time config pins sections the file hydrates", %{compiled: compiled} do
    pinned = Keyword.keys(compiled[:fermix_core])

    assert :meetings in pinned
    assert :transcription in pinned
    assert :jobs in pinned
    refute get_in(compiled, [:fermix_core, :meetings, :enabled])
  end

  test "a release boot keeps the hydrated value of every pinned section", %{compiled: compiled} do
    :ok =
      ConfigStore.apply_snapshot(
        %{
          fermix_core: [
            meetings: [enabled: true, bot_name: "Fermix Notetaker"],
            transcription: [backend: "deepgram", model: "nova-3"],
            jobs: [default_delivery_target: %{platform: "telegram", chat_id: "1"}]
          ]
        },
        supervised: false
      )

    booted = Config.Reader.merge(compiled, fermix_core: ConfigStore.hydrated_environment())

    assert get_in(booted, [:fermix_core, :meetings, :enabled]) == true
    assert get_in(booted, [:fermix_core, :transcription, :backend]) == "deepgram"

    assert get_in(booted, [:fermix_core, :jobs, :default_delivery_target, :platform]) ==
             "telegram"
  end

  # Structural: every compile-time pin is either restated by the boot or named
  # below as one the boot never hydrates. A pin added for a hydrated section that
  # the enumerator misses fails the first assertion; a key on the list below that
  # starts being hydrated fails the second; a name that no longer exists fails the
  # third. The same defect cannot return for one section quietly.
  test "every pinned key the boot hydrates is restated", %{compiled: compiled} do
    :ok = ConfigStore.apply_snapshot(%{}, supervised: false)

    pinned = compiled[:fermix_core] |> Keyword.keys() |> MapSet.new()
    restated = ConfigStore.hydrated_environment() |> Keyword.keys() |> MapSet.new()
    unhydrated = MapSet.new(unhydrated_pins())

    missing = pinned |> MapSet.difference(restated) |> MapSet.difference(unhydrated)

    assert MapSet.size(missing) == 0,
           "pinned keys the boot hydrates and runtime.exs does not restate: " <>
             inspect(MapSet.to_list(missing))

    assert MapSet.disjoint?(unhydrated, restated),
           "keys listed as never hydrated are now restated: " <>
             inspect(MapSet.to_list(MapSet.intersection(unhydrated, restated)))

    assert MapSet.subset?(unhydrated, pinned),
           "keys listed as pins that the compile-time config no longer pins: " <>
             inspect(MapSet.to_list(MapSet.difference(unhydrated, pinned)))
  end

  # Compile-time keys the boot never hydrates from the file. They are in the
  # environment before the boot and untouched by it, so the provider's merge
  # restores what was already there; they need no restatement.
  defp unhydrated_pins do
    [
      :context_window_limit,
      :harness_continuation_dispatcher,
      :iteration_limits,
      :log,
      :max_conversation_history,
      :prompt_bootstrap,
      :subagents,
      :trace,
      :ultra
    ]
  end
end
