defmodule FermixCore.ReadinessTest do
  use ExUnit.Case, async: false

  alias FermixCore.Readiness

  setup do
    personalization = Application.get_env(:fermix_core, :personalization, [])

    on_exit(fn ->
      Application.put_env(:fermix_core, :personalization, personalization)
    end)

    :ok
  end

  describe "personalization_failure/0" do
    test "returns failure when any personalization key is blank" do
      Application.put_env(:fermix_core, :personalization,
        user_name: "Sujeeth",
        timezone: "Asia/Singapore",
        communication_style: nil
      )

      assert %{component: "personalization", action: action} = Readiness.personalization_failure()
      assert action =~ "mix fermix.setup"
    end

    test "returns failure when personalization is empty" do
      Application.put_env(:fermix_core, :personalization, [])
      assert %{component: "personalization"} = Readiness.personalization_failure()
    end

    test "treats whitespace-only strings as blank" do
      Application.put_env(:fermix_core, :personalization,
        user_name: "Sujeeth",
        timezone: "",
        communication_style: "blunt"
      )

      assert %{component: "personalization"} = Readiness.personalization_failure()
    end

    test "returns nil when all three keys are populated" do
      Application.put_env(:fermix_core, :personalization,
        user_name: "Sujeeth",
        timezone: "Asia/Singapore",
        communication_style: "blunt"
      )

      assert is_nil(Readiness.personalization_failure())
    end
  end

  describe "report/0" do
    test "includes personalization failure alongside other failures" do
      Application.put_env(:fermix_core, :personalization, [])

      report = Readiness.report()

      assert report.status == :setup_required
      assert Enum.any?(report.failures, &(&1.component == "personalization"))
    end
  end
end
