defmodule FermixChannels.X.DoctorReadinessTest do
  # The X channel's Doctor row and readiness rows in the world they inspect
  # (docs/lessons.md, "Gates and the world they inspect"): nothing of the
  # channel runs, only its config and the pairing files under a fresh
  # FERMIX_HOME, exactly what the tree-less `fermix doctor` VM and a first
  # boot see. Core holds no seam here: these are the default paths, through
  # the channels app the core rows call by name.
  use ExUnit.Case, async: false

  alias Fermix.CLI.Doctor.Checks
  alias FermixChannels.Test.XConnectHelper, as: Fixtures
  alias FermixChannels.X.Pairing
  alias FermixCore.Management.X
  alias FermixCore.Net.Egress
  alias FermixCore.Readiness
  alias FermixTestSupport.SafeRm

  setup do
    home = SafeRm.make_tmp_dir!("x-doctor-readiness")
    previous_home = System.get_env("FERMIX_HOME")
    previous_x = Application.fetch_env(:fermix_channels, :x)
    previous_egress = Application.fetch_env(:fermix_core, :egress)
    previous_memory = Application.fetch_env(:fermix_core, :memory)

    System.put_env("FERMIX_HOME", home)
    Application.put_env(:fermix_core, :egress, %Egress{})

    on_exit(fn ->
      restore_home(previous_home)
      restore(:fermix_channels, :x, previous_x)
      restore(:fermix_core, :egress, previous_egress)
      restore(:fermix_core, :memory, previous_memory)
      SafeRm.rm_rf(home)
    end)

    %{home: home, memory: memory_config(previous_memory)}
  end

  defp restore_home(nil), do: System.delete_env("FERMIX_HOME")
  defp restore_home(home), do: System.put_env("FERMIX_HOME", home)

  defp restore(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore(app, key, :error), do: Application.delete_env(app, key)

  defp memory_config({:ok, config}), do: config
  defp memory_config(:error), do: []

  defp x!(config), do: Application.put_env(:fermix_channels, :x, config)

  defp pair!(home) do
    {:ok, public_key} = Pairing.ensure_key(root: home)
    {connect_public, _seed} = Fixtures.connect_key()
    record = Fixtures.record(connect_public, %{key_id: Pairing.key_id(public_key)})
    :ok = Pairing.save(record, root: home)
    {record, public_key}
  end

  defp x_rows, do: Enum.filter(Readiness.report().failures, &(&1.component == "channel:x"))

  test "a fresh machine with the channel off: no row, and Doctor says off", ctx do
    x!(enabled: false)

    refute File.exists?(Path.join(ctx.home, "x"))
    assert x_rows() == []

    assert %{name: "x channel", status: :ok, detail: "off; not paired with Fermix Connect"} =
             Checks.x_channel()

    refute File.exists?(Path.join(ctx.home, "x"))
  end

  test "a fresh machine with the channel on is refused by name on both", _ctx do
    x!(enabled: true)

    assert [%{detail_key: "channel:x:not_paired", action: action}] = x_rows()
    assert action == X.refusal_sentence(:not_paired)

    assert %{status: :warn, detail: ^action} = Checks.x_channel()
  end

  test "a pairing whose key is gone is the pairing_invalid refusal", ctx do
    x!(enabled: true)
    pair!(ctx.home)
    SafeRm.rm!(Pairing.key_path(root: ctx.home))

    assert [%{detail_key: "channel:x:pairing_invalid"}] = x_rows()
    assert %{status: :warn, detail: detail} = Checks.x_channel()
    assert detail == X.refusal_sentence(:pairing_invalid)
  end

  test "paired and on: no row, and Doctor names the pairing from its files", ctx do
    x!(enabled: true)
    Application.put_env(:fermix_core, :memory, Keyword.put(ctx.memory, :enabled, true))
    {record, public_key} = pair!(ctx.home)

    assert x_rows() == []

    assert %{status: :ok, detail: detail} = Checks.x_channel()

    assert detail ==
             "on; paired as #{record.handle} with #{record.origin}, key " <>
               Pairing.fingerprint(public_key)
  end

  test "paired and on with the memory store off is that refusal", ctx do
    x!(enabled: true)
    Application.put_env(:fermix_core, :memory, Keyword.put(ctx.memory, :enabled, false))
    pair!(ctx.home)

    assert %{status: :warn, detail: detail} = Checks.x_channel()
    assert detail == X.refusal_sentence(:memory_disabled)
  end

  test "a proxy that would carry the socket is its own row", ctx do
    x!(enabled: true)
    pair!(ctx.home)

    Application.put_env(
      :fermix_core,
      :egress,
      Egress.new(proxy: "http://proxy.fermix.example:3128")
    )

    assert [%{detail_key: "channel:x:proxy_unsupported", action: action}] = x_rows()
    assert action == X.refusal_sentence(:proxy_unsupported)
  end
end
