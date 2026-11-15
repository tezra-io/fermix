defmodule FermixCore.Release.NativeRuntime do
  @moduledoc """
  The Burrito fetch pre-step that names the native runtime every standalone and
  Linux package build is packed with.

  A Burrito build takes its parts from two places. The Erlang code (`ssl`,
  `public_key`, `stdlib`, everything under `lib/`) is the build machine's OTP,
  copied in by `mix release`. The native runtime (`erts-*/bin` and the native
  libraries the target loads) is beam-machine's precompiled build for the
  target, which Burrito downloads by the build machine's OTP version.
  beam-machine has built nothing after OTP 28.5.0.6, so a build machine on
  28.5.0.8 would be answered 404.

  The Erlang code must still be 28.5.0.8's. OTP 28.5.0.7 fixes the TLS 1.3
  client, which could skip checking the server (CVE-2026-89422), and the
  certificate decoder (CVE-2026-65634), and 28.5.0.8 carries further `ssl` and
  `public_key` fixes, all of them Erlang code. From 28.5.0.6 to
  28.5.0.8 the only change to C is in `erl_trace.c` (garbage-collection tracing
  across trace sessions, which Fermix does not use), so 28.5.0.6's native
  runtime runs 28.5.0.8's code as its own. This step names that runtime and
  keeps the source `:precompiled`, so Burrito's support check, its musl
  download and its cache behave exactly as they did.

  The pairing is proven for one build-machine OTP. Any other is refused, naming
  both versions, so moving either is a change to this module, made after the
  same check: that the native code between the two did not change.
  `FermixCore.Release.NativeLibraries` then puts the runtime's native libraries
  where an app whose version moved loads them.

  Burrito is a dependency of the umbrella root rather than of this app, so
  nothing here names a `Burrito.*` module. `execute/1` is Burrito's step
  contract and the build context is matched as the plain map it is.
  """

  @native_runtime_otp "28.5.0.6"
  @build_otp "28.5.0.8"

  @doc "Burrito's step entry point, run before the fetch phase."
  @spec execute(map()) :: map()
  def execute(context) when is_map(context), do: run(context, [])

  @doc """
  The step, with the build machine's OTP version injectable as `:otp_version`.
  """
  @spec run(map(), keyword()) :: map()
  def run(%{target: %{erts_source: {:precompiled, _}} = target} = context, opts)
      when is_list(opts) do
    build_otp = Keyword.get_lazy(opts, :otp_version, &build_otp_version/0)

    if build_otp != @build_otp do
      raise "this build packs beam-machine's OTP #{@native_runtime_otp} native runtime, " <>
              "proven to run OTP #{@build_otp}'s Erlang code, and the build machine runs " <>
              "OTP #{build_otp}: build on #{@build_otp}, or prove the new pairing and " <>
              "change FermixCore.Release.NativeRuntime"
    end

    IO.puts(
      "fermix: OTP #{build_otp}'s Erlang code on beam-machine's OTP " <>
        "#{@native_runtime_otp} native runtime"
    )

    %{context | target: %{target | erts_source: {:precompiled, version: @native_runtime_otp}}}
  end

  def run(%{target: %{erts_source: source}}, opts) when is_list(opts) do
    raise "the native runtime step expects Burrito's precompiled beam-machine runtime, " <>
            "and this target names #{inspect(source)}"
  end

  @doc "The OTP release whose beam-machine native runtime every Burrito build packs."
  @spec native_runtime_otp() :: String.t()
  def native_runtime_otp, do: @native_runtime_otp

  @doc "The build machine's full OTP version, read as Burrito reads it."
  @spec build_otp_version() :: String.t()
  def build_otp_version do
    [to_string(:code.root_dir()), "releases", System.otp_release(), "OTP_VERSION"]
    |> Path.join()
    |> File.read!()
    |> String.trim()
  end
end
