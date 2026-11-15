defmodule FermixCore.Release.NativeRuntimeTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias FermixCore.Release.NativeRuntime

  # Burrito asks beam-machine for the build machine's own OTP version, and
  # beam-machine has built nothing after 28.5.0.6, so the step names that
  # runtime while the Erlang code comes from the build machine's OTP.
  test "a precompiled target takes the named native runtime, everything else kept" do
    context = context({:precompiled, version: "28.5.0.8"})

    {result, log} = with_io(fn -> NativeRuntime.run(context, otp_version: "28.5.0.8") end)

    assert %{target: target} = result
    assert log =~ "OTP 28.5.0.8's Erlang code on beam-machine's OTP 28.5.0.6 native runtime"
    assert target.erts_source == {:precompiled, version: NativeRuntime.native_runtime_otp()}
    assert target.os == :linux
    assert target.cpu == :x86_64
    assert NativeRuntime.native_runtime_otp() == "28.5.0.6"
  end

  # The pairing is proven for one Erlang-code release: a build machine on any
  # other OTP would ship code nobody checked against this runtime.
  test "refuses a build machine on any other OTP, by both versions" do
    for host <- ["28.5.0.6", "28.5.0.7", "28.5.0.9", "29.1.2"] do
      error =
        assert_raise RuntimeError, fn ->
          NativeRuntime.run(context({:precompiled, version: host}), otp_version: host)
        end

      assert error.message =~ host
      assert error.message =~ "28.5.0.8"
      assert error.message =~ "28.5.0.6"
    end
  end

  test "refuses a target whose runtime is not beam-machine's precompiled one" do
    for source <- [{:url, url: URI.parse("https://example.test/otp.tar.gz")}, {:runtime, []}] do
      assert_raise RuntimeError, ~r/precompiled/, fn ->
        NativeRuntime.run(context(source), otp_version: "28.5.0.8")
      end
    end
  end

  test "reads the build machine's full OTP version the way Burrito does" do
    assert NativeRuntime.build_otp_version() =~ ~r/^\d+(\.\d+)+$/
    assert String.starts_with?(NativeRuntime.build_otp_version(), System.otp_release())
  end

  defp context(source) do
    %{target: %{os: :linux, cpu: :x86_64, erts_source: source}, work_dir: "", halted: false}
  end
end
