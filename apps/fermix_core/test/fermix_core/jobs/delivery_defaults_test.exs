defmodule FermixCore.Jobs.DeliveryDefaultsTest do
  @moduledoc """
  A job's delivery target is a chat (M76 §10): this computer takes reminders
  alone, so neither an explicit target nor the shared configured default can
  point a job's results at it, and the refusal says what to pass instead.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Jobs.DeliveryDefaults

  @computer %{"platform" => "computer", "target" => "local"}
  @telegram %{"platform" => "telegram", "chat_id" => "42"}

  test "an explicit delivery target on this computer is refused, on create and on edit" do
    for result <- [
          DeliveryDefaults.resolve(%{"delivery_target" => @computer}, %{}, jobs_config: []),
          DeliveryDefaults.resolve_update(%{"delivery_target" => @computer}, %{}, jobs_config: [])
        ] do
      assert {:error, {:invalid_delivery_target, sentence}} = result
      assert sentence =~ "takes reminders only"
    end
  end

  test "a configured default delivery target on this computer serves reminders alone" do
    config = [default_delivery_target: @computer]

    assert {:error, {:invalid_delivery_target, sentence}} =
             DeliveryDefaults.resolve(%{}, %{}, jobs_config: config)

    assert sentence =~ "default_delivery_target"
  end

  test "a chat target is still a job's target" do
    assert {:ok, {"channel", %{"platform" => "telegram", "chat_id" => "42"}}} =
             DeliveryDefaults.resolve(%{"delivery_target" => @telegram}, %{}, jobs_config: [])
  end
end
