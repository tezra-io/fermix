defmodule FermixCore.Release.NativeLibrariesTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias FermixCore.Release.NativeLibraries

  # Burrito's own copy step has already run: it copied every native library of
  # the target's runtime into the release under the runtime's app folder names.
  # Where an app's version moved, that is a folder the release does not load,
  # and the release's own folder still holds the build machine's library.
  setup do
    root = FermixTestSupport.SafeRm.make_tmp_dir!("native-libraries")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(root) end)

    erts = Path.join(root, "unpacked")
    work_dir = Path.join(root, "work")

    write!(erts, "otp_x86_64_linux_28.5.0.6/erts-16.4.0.6/bin/beam.smp", "beam")
    write!(erts, "otp_x86_64_linux_28.5.0.6/erts-16.4.0.6/lib/internal/liberts.a", "erts lib")
    write!(erts, "otp_x86_64_linux_28.5.0.6/lib/asn1-5.4.3/priv/lib/asn1rt_nif.so", "target asn1")

    write!(
      erts,
      "otp_x86_64_linux_28.5.0.6/lib/crypto-5.8.3.3/priv/lib/crypto.so",
      "target crypto"
    )

    write!(erts, "otp_x86_64_linux_28.5.0.6/lib/wx-2.5.4/priv/wxe_driver.so", "target wx")

    %{erts: erts, work_dir: work_dir}
  end

  test "puts the target's library in the folder the release loads, and drops Burrito's stray copy",
       %{erts: erts, work_dir: work_dir} do
    app!(work_dir, "asn1-5.4.3.1", %{"priv/lib/asn1rt_nif.so" => "build machine asn1"})
    burrito_copy!(work_dir, "asn1-5.4.3/priv/lib/asn1rt_nif.so", "target asn1")
    app!(work_dir, "crypto-5.8.3.3", %{"priv/lib/crypto.so" => "target crypto"})

    log = capture_io(fn -> NativeLibraries.run(context(erts, work_dir)) end)

    assert File.read!(Path.join(work_dir, "lib/asn1-5.4.3.1/priv/lib/asn1rt_nif.so")) ==
             "target asn1"

    refute File.exists?(Path.join(work_dir, "lib/asn1-5.4.3"))

    assert File.read!(Path.join(work_dir, "lib/crypto-5.8.3.3/priv/lib/crypto.so")) ==
             "target crypto"

    assert log =~ "asn1-5.4.3.1"
  end

  # The build machine's OTP can carry a library the target's runtime has no
  # copy of at all (crypto_callback.so); that is not this step's to judge.
  test "leaves a library the target's runtime does not carry", %{erts: erts, work_dir: work_dir} do
    app!(work_dir, "crypto-5.8.3.3", %{
      "priv/lib/crypto.so" => "target crypto",
      "priv/lib/crypto_callback.so" => "build machine callback"
    })

    capture_io(fn -> NativeLibraries.run(context(erts, work_dir)) end)

    assert File.read!(Path.join(work_dir, "lib/crypto-5.8.3.3/priv/lib/crypto_callback.so")) ==
             "build machine callback"
  end

  test "an app the release does not include is left alone", %{erts: erts, work_dir: work_dir} do
    app!(work_dir, "crypto-5.8.3.3", %{"priv/lib/crypto.so" => "target crypto"})
    burrito_copy!(work_dir, "wx-2.5.4/priv/wxe_driver.so", "target wx")

    capture_io(fn -> NativeLibraries.run(context(erts, work_dir)) end)

    assert File.read!(Path.join(work_dir, "lib/wx-2.5.4/priv/wxe_driver.so")) == "target wx"
  end

  # The step's proof: every library the target's runtime carries is, byte for
  # byte, the one in the folder the release loads. A build machine's library
  # there would load on the build machine and nowhere else.
  test "refuses a release whose loaded library is not the target's", %{
    erts: erts,
    work_dir: work_dir
  } do
    app!(work_dir, "crypto-5.8.3.3", %{"priv/lib/crypto.so" => "build machine crypto"})

    error =
      assert_raise RuntimeError, fn ->
        capture_io(fn -> NativeLibraries.run(context(erts, work_dir)) end)
      end

    assert error.message =~ "lib/crypto-5.8.3.3/priv/lib/crypto.so"
    assert error.message =~ "target"
  end

  test "refuses a release that holds two versions of one app", %{erts: erts, work_dir: work_dir} do
    app!(work_dir, "asn1-5.4.3.1", %{"priv/lib/asn1rt_nif.so" => "target asn1"})
    app!(work_dir, "asn1-5.4.4", %{"priv/lib/asn1rt_nif.so" => "target asn1"})

    assert_raise RuntimeError,
                 ~r/asn1-5\.4\.3\.1.*asn1-5\.4\.4|asn1-5\.4\.4.*asn1-5\.4\.3\.1/,
                 fn ->
                   capture_io(fn -> NativeLibraries.run(context(erts, work_dir)) end)
                 end
  end

  test "refuses a target whose runtime was never unpacked", %{work_dir: work_dir} do
    context = %{target: %{erts_source: {:precompiled, version: "28.5.0.6"}}, work_dir: work_dir}

    assert_raise RuntimeError, ~r/unpacked/, fn -> NativeLibraries.run(context) end
  end

  defp context(erts, work_dir) do
    %{target: %{erts_source: {:local_unpacked, path: erts}}, work_dir: work_dir}
  end

  defp app!(work_dir, folder, files) do
    File.mkdir_p!(Path.join([work_dir, "lib", folder, "ebin"]))

    Enum.each(files, fn {relative, bytes} ->
      write!(work_dir, Path.join(["lib", folder, relative]), bytes)
    end)
  end

  defp burrito_copy!(work_dir, relative, bytes),
    do: write!(work_dir, Path.join("lib", relative), bytes)

  defp write!(root, relative, bytes) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
  end
end
