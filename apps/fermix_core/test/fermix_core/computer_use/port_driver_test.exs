defmodule FermixCore.ComputerUse.PortDriverTest do
  use ExUnit.Case, async: false

  alias FermixCore.ComputerUse.PortDriver

  setup do
    dir =
      Path.join([
        System.tmp_dir!(),
        "fermix-cu-portdriver",
        "run-#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(dir)
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf(dir) end)
    %{dir: dir}
  end

  # A benign fake sidecar: read each request line, echo a canned JSON response
  # (from $FAKE_RESPONSE) back. Exercises the Port framing/round-trip without the
  # native Rust binary; it mutates no host state.
  defp fake_sidecar(dir) do
    path = Path.join(dir, "fake-sidecar.sh")

    File.write!(
      path,
      ~s(#!/bin/sh\nwhile IFS= read -r line; do printf '%s\\n' "$FAKE_RESPONSE"; done\n)
    )

    File.chmod!(path, 0o755)
    path
  end

  defp env(json), do: [env: [{~c"FAKE_RESPONSE", String.to_charlist(json)}]]

  test "start fails loud when the sidecar binary is absent (no degrade)" do
    assert {:error, {:sidecar_missing, "/no/such/fermix-cu"}} =
             PortDriver.start(binary_path: "/no/such/fermix-cu")
  end

  test "execute round-trips a request through the Port and decodes the response", %{dir: dir} do
    path = fake_sidecar(dir)

    assert {:ok, state} =
             PortDriver.start(
               [binary_path: path] ++ env(~s({"ok":true,"width":1280,"height":800}))
             )

    assert {:ok, %{"ok" => true, "width" => 1280}} =
             PortDriver.execute(state, %{"action" => "screenshot"})

    assert :ok = PortDriver.stop(state)
  end

  test "a sidecar error response is surfaced as an error", %{dir: dir} do
    path = fake_sidecar(dir)

    {:ok, state} =
      PortDriver.start([binary_path: path] ++ env(~s({"ok":false,"error":"permission denied"})))

    assert {:error, "permission denied"} =
             PortDriver.execute(state, %{"action" => "left_click", "x" => 0, "y" => 0})

    PortDriver.stop(state)
  end

  test "stop is idempotent / safe after the port is gone", %{dir: dir} do
    path = fake_sidecar(dir)
    {:ok, state} = PortDriver.start([binary_path: path] ++ env(~s({"ok":true})))
    assert :ok = PortDriver.stop(state)
    assert :ok = PortDriver.stop(state)
  end
end
