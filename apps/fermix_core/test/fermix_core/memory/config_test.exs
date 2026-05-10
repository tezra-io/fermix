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

  test "extraction_debounce_ms/1 reads explicit millisecond opts" do
    assert Config.extraction_debounce_ms(extraction_debounce_ms: 25) == 25
  end

  test "extraction_debounce_ms/1 converts configured seconds" do
    Application.put_env(:fermix_core, :memory, extraction_debounce_seconds: 2)

    assert Config.extraction_debounce_ms() == 2_000
  end

  test "extraction_debounce_ms/1 allows zero to run extraction immediately" do
    assert Config.extraction_debounce_ms(extraction_debounce_seconds: 0) == 0
  end

  test "extraction_timeout_ms/1 defaults to 90s so reasoning models have headroom" do
    Application.put_env(:fermix_core, :memory, [])

    assert Config.extraction_timeout_ms() == 90_000
  end

  test "extraction_timeout_ms/1 honors a configured override" do
    Application.put_env(:fermix_core, :memory, extraction_timeout_ms: 30_000)

    assert Config.extraction_timeout_ms() == 30_000
  end
end
