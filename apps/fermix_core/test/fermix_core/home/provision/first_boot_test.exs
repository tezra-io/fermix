defmodule FermixCore.Home.Provision.FirstBootTest do
  # M75 lean v1 §4.3: a server Fermix creates runs the provider-neutral first
  # boot (`packaging/cloud/first-boot.sh`) from its cloud-init user data, with
  # the enrollment code in `FERMIX_ENROLL_CODE`, as the cloud README says to
  # pass it.
  use ExUnit.Case, async: true

  alias FermixCore.Home.Provision.FirstBoot

  @script Path.expand("../../../../../../packaging/cloud/first-boot.sh", __DIR__)
  @code "fxenroll1.eyJ2IjoxLCJuYW1lIjoiaW52ZW50ZWQifQ_-Zx9"

  test "the user data unpacks the first boot byte for byte and checks it before it runs" do
    {:ok, user_data} = FirstBoot.user_data(@code)

    assert String.starts_with?(user_data, "#!/bin/sh\n")

    [blob] =
      Regex.run(~r/<<'FERMIX_FIRST_BOOT'[^\n]*\n(.*)\nFERMIX_FIRST_BOOT\n/s, user_data,
        capture: :all_but_first
      )

    script = File.read!(@script)
    assert blob |> String.replace("\n", "") |> Base.decode64!() |> :zlib.gunzip() == script

    digest = :crypto.hash(:sha256, script) |> Base.encode16(case: :lower)
    assert FirstBoot.script_sha256() == digest

    assert user_data =~
             "printf '%s  %s\\n' #{digest} /usr/local/lib/fermix-always-on/first-boot.sh | sha256sum -c --quiet"
  end

  test "the code reaches the first boot only in its environment, never on a command line" do
    {:ok, user_data} = FirstBoot.user_data(@code)

    assert user_data =~
             "FERMIX_ENROLL_CODE='#{@code}' sh /usr/local/lib/fermix-always-on/first-boot.sh\n"

    assert length(String.split(user_data, @code)) == 2
  end

  test "the user data is shell the server can parse, and fits the 32 KiB Hetzner takes" do
    {:ok, user_data} = FirstBoot.user_data(@code)
    assert byte_size(user_data) <= FirstBoot.max_bytes()
    assert FirstBoot.max_bytes() == 32_768

    {output, status} = System.cmd("sh", ["-n", "-c", user_data], stderr_to_stdout: true)
    assert {output, status} == {"", 0}
  end

  test "anything but an enrollment code is refused before it can reach a shell" do
    for bad <- [
          "fxenroll1.a'b",
          "fxenroll1.a b",
          "fxenroll1.",
          "fxenroll2.abc",
          "fxenroll1.abc\nrm",
          String.duplicate("a", 10)
        ] do
      assert FirstBoot.user_data(bad) == {:error, :invalid_code}, inspect(bad)
    end
  end
end
