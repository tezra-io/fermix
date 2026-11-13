defmodule Fermix.CLI.Doctor.ReadinessCheckTest do
  # M97 F8: `fermix doctor` runs with no engine tree, so it judges readiness
  # for the role the home is configured for: a computer that joined a home
  # agrees with its own `setup.state`, which judges only what a device needs.
  # async: false: readiness reads the provider, channel and voice settings
  # from application env, which each case establishes and restores.
  use ExUnit.Case, async: false

  alias Fermix.CLI.Doctor.Checks
  alias FermixTestSupport.SafeRm

  setup do
    saved = [
      {:fermix_core, :providers},
      {:fermix_core, :personalization},
      {:fermix_core, :realtime},
      {:fermix_channels, :telegram}
    ]

    previous = for {app, key} <- saved, do: {app, key, Application.get_env(app, key, [])}

    on_exit(fn ->
      for {app, key, value} <- previous, do: Application.put_env(app, key, value)
    end)

    # A fresh Linux box: nothing but the shipped defaults.
    Application.put_env(:fermix_core, :providers, [])
    Application.put_env(:fermix_core, :personalization, [])
    Application.put_env(:fermix_channels, :telegram, enabled: true)
    Application.put_env(:fermix_core, :realtime, enabled: true, provider: "openai")

    tmp = SafeRm.make_tmp_dir!("doctor_readiness")
    on_exit(fn -> SafeRm.rm_rf!(tmp) end)
    %{tmp: tmp}
  end

  defp home!(tmp, name, settings) do
    home = Path.join(tmp, name)
    File.mkdir_p!(home)
    File.write!(Path.join(home, "config.toml"), settings)
    home
  end

  test "a computer that joined a home is judged as a device: no provider is its to need", ctx do
    home = home!(ctx.tmp, "joined", ~s([fermix_core.engine]\nrole = "device"\n))

    assert %{name: "readiness", status: :ok} = Checks.readiness(home: home)
  end

  test "a home configured as the primary is judged on every row, as before", ctx do
    home = home!(ctx.tmp, "primary", "[fermix_core]\n")

    assert %{name: "readiness", status: :fail, detail: detail} = Checks.readiness(home: home)
    assert detail =~ "provider"
  end

  test "a home whose role cannot be read fails the row and says why", ctx do
    home = home!(ctx.tmp, "unreadable", ~s([fermix_core.engine]\nrole = "lighthouse"\n))

    assert %{name: "readiness", status: :fail, detail: detail} = Checks.readiness(home: home)
    assert detail =~ "role"
  end
end
