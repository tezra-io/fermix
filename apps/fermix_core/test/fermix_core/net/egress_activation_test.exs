defmodule FermixCore.Net.EgressActivationTest do
  @moduledoc """
  One source for the egress a process runs on. The record `activate/0` makes is
  what every connector reads; a setting saved later does not change it.
  """

  # async: false — this is the one place that reads and writes the `:network`
  # and `:egress` application environment, and it restores both.
  use ExUnit.Case, async: false

  alias FermixCore.Net.Egress

  setup do
    saved = Map.new([:network, :egress], &{&1, Application.get_env(:fermix_core, &1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> Application.delete_env(:fermix_core, key)
        {key, value} -> Application.put_env(:fermix_core, key, value)
      end)
    end)

    :ok
  end

  test "activate/0 records the section, and a later save does not move the answer" do
    Application.put_env(:fermix_core, :network, proxy: "http://proxy.test:3128")

    assert %Egress{proxy: %{host: "proxy.test", port: 3128}} = booted = Egress.activate()
    assert Egress.active() == booted

    Application.put_env(:fermix_core, :network, [])

    assert Egress.active() == booted
  end

  # A CLI verb starts no pools. Its first connector makes the record, so a
  # second one cannot read a different section.
  test "active/0 makes the record on first use in a process that started no pools" do
    Application.delete_env(:fermix_core, :egress)
    Application.put_env(:fermix_core, :network, proxy: "http://proxy.test:3128")

    first = Egress.active()
    Application.put_env(:fermix_core, :network, [])

    assert Egress.active() == first
    assert Egress.describe(first) == "http://proxy.test:3128"
  end
end
