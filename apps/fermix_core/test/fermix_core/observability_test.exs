defmodule FermixCore.ObservabilityTest do
  use ExUnit.Case, async: true

  alias FermixCore.Observability

  # All probes are injected so every state is reachable under `mix test`, where
  # `fermix_opik` is never loaded (it is `only: [:dev, :prod]`).
  describe "report/1" do
    test "disabled when the env flag is not set, even if loaded" do
      report =
        Observability.report(
          enabled_env?: fn -> false end,
          loaded?: fn -> true end,
          attached?: fn -> true end,
          config: fn -> {"http://localhost:5173/api", "fermix"} end
        )

      assert report.status == :disabled
      assert report.enabled_env == false
    end

    test "enabled_missing_app when enabled but FermixOpik is not loaded" do
      report =
        Observability.report(
          enabled_env?: fn -> true end,
          loaded?: fn -> false end,
          attached?: fn -> false end
        )

      assert report.status == :enabled_missing_app
      assert report.loaded == false
      assert report.base_url == nil
      assert report.project == nil
    end

    test "enabled_not_attached when loaded but the reporter is not attached" do
      report =
        Observability.report(
          enabled_env?: fn -> true end,
          loaded?: fn -> true end,
          attached?: fn -> false end,
          config: fn -> {"http://localhost:5173/api", "fermix"} end
        )

      assert report.status == :enabled_not_attached
      assert report.loaded == true
      assert report.attached == false
      assert report.base_url == "http://localhost:5173/api"
    end

    test "enabled_ready when enabled, loaded, and attached" do
      report =
        Observability.report(
          enabled_env?: fn -> true end,
          loaded?: fn -> true end,
          attached?: fn -> true end,
          config: fn -> {"http://localhost:5173/api", "fermix"} end
        )

      assert report.status == :enabled_ready
      assert report.attached == true
      assert report.base_url == "http://localhost:5173/api"
      assert report.project == "fermix"
    end

    test "attached is forced false when not loaded, regardless of the probe" do
      report =
        Observability.report(
          enabled_env?: fn -> true end,
          loaded?: fn -> false end,
          attached?: fn -> true end
        )

      assert report.attached == false
      assert report.status == :enabled_missing_app
    end
  end
end
