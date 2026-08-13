defmodule FermixCore.TelemetryTest do
  # Sync: the capture-content tests mutate the global :telemetry app env.
  use ExUnit.Case, async: false

  alias FermixCore.Telemetry

  test "timed_us returns the function result and elapsed microseconds" do
    assert {:ok, duration_us} = Telemetry.timed_us(fn -> :ok end)
    assert is_integer(duration_us)
    assert duration_us >= 0
  end

  # `config/runtime.exs` decides the product default (content ON) and runs AFTER
  # `config/test.exs`, so it would clobber the suite's posture unless it honours
  # an already-set compile-time value. This asserts that precedence from the
  # outside: if the resolver goes back to overwriting, every content assertion in
  # the suite silently flips and this fails first, naming why.
  test "the test env keeps its pinned lean posture through runtime config" do
    assert Application.get_env(:fermix_core, :telemetry)[:capture_content] == false
    refute Telemetry.capture_content?()
  end

  # The companion to the test above, from the other side. `config/runtime.exs`
  # owns the PRODUCT default and reaches it with
  # `Keyword.get(existing_telemetry, :capture_content, true)` — which returns that
  # `true` only when the key is ABSENT. So a pin in the BASE config (which applies
  # to every environment, not just the one that wanted it) silently shadows the
  # default everywhere, and nothing downstream can tell a deliberate `false` from
  # an inherited one.
  #
  # That is exactly how content capture shipped OFF under a change titled "capture
  # trace content by default": `config/config.exs` still pinned `false`, so every
  # dev-daemon turn traced with `input: nil`, and the behavioral eval — which
  # correlates a turn by its exact input text — matched zero traces and reported
  # every case INCOMPLETE. The runtime assertion above cannot catch it, because the
  # test env is *supposed* to be pinned; only reading the compile-time chain per
  # environment separates "pinned for the suite" from "pinned for everyone".
  describe "trace content capture defaults, per compile-time environment" do
    test "the base config leaves capture_content unpinned for dev and prod" do
      for env <- [:dev, :prod] do
        telemetry = compile_time_telemetry(env)

        refute Keyword.has_key?(telemetry, :capture_content),
               "config/config.exs must not pin :capture_content — it shadows the " <>
                 "config/runtime.exs default for #{env}, which only applies when the key is absent"

        assert Keyword.get(telemetry, :capture_content, true) == true
      end
    end

    test "the test env pins the lean posture the suite asserts against" do
      assert Keyword.get(compile_time_telemetry(:test), :capture_content, true) == false
    end
  end

  describe "with content capture off" do
    setup do
      set_capture(false)
    end

    test "preview truncates long strings to the 2k bound" do
      long = String.duplicate("a", 3_000)

      assert Telemetry.preview(long) ==
               String.duplicate("a", 2_000) <> "…[truncated]"
    end

    test "preview elides large terms via inspect limits" do
      assert Telemetry.preview(Enum.to_list(1..200)) =~ "..."
    end
  end

  describe "with content capture on" do
    setup do
      set_capture(true)
    end

    test "preview returns long strings whole" do
      long = String.duplicate("a", 3_000)
      assert Telemetry.preview(long) == long
    end

    test "preview inspects terms without eliding" do
      preview = Telemetry.preview(Enum.to_list(1..200))
      refute preview =~ "..."
      assert preview =~ "200"
    end
  end

  # Reads the real umbrella config chain for one environment (config.exs, which
  # ends in `import_config "#{config_env()}.exs"`). Anchored on __DIR__ rather than
  # cwd so it resolves the same from the umbrella root and from this app, and it
  # touches no Application env, no FERMIX_HOME, and no shell variable.
  defp compile_time_telemetry(env) do
    config =
      "../../../../config/config.exs"
      |> Path.expand(__DIR__)
      |> Config.Reader.read!(env: env)

    get_in(config, [:fermix_core, :telemetry]) || []
  end

  defp set_capture(value) do
    prior = Application.get_env(:fermix_core, :telemetry, [])
    Application.put_env(:fermix_core, :telemetry, Keyword.put(prior, :capture_content, value))
    on_exit(fn -> Application.put_env(:fermix_core, :telemetry, prior) end)
    :ok
  end
end
