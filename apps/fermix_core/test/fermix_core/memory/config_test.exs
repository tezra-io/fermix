defmodule FermixCore.Memory.ConfigTest do
  use ExUnit.Case, async: false

  alias FermixCore.Memory.Config

  setup do
    previous_memory_config = Application.get_env(:fermix_core, :memory, [])

    on_exit(fn ->
      Application.put_env(:fermix_core, :memory, previous_memory_config)
    end)

    :ok
  end

  test "review_interval_hours/1 defaults to 24 and allows zero to disable background review" do
    Application.put_env(:fermix_core, :memory, [])

    assert Config.review_interval_hours() == 24
    assert Config.review_interval_hours(review_interval_hours: 0) == 0
  end

  test "review interval and input caps honor configured overrides" do
    Application.put_env(:fermix_core, :memory,
      review_interval_hours: 12,
      review_max_messages: 10,
      review_input_token_budget: 2_000,
      review_failure_backoff_ms: 123
    )

    assert Config.review_interval_hours() == 12
    assert Config.review_max_messages() == 10
    assert Config.review_input_token_budget() == 2_000
    assert Config.review_failure_backoff_ms() == 123
  end
end
