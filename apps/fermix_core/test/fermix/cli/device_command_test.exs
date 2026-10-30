defmodule Fermix.CLI.DeviceCommandTest do
  # `fermix device grants [remove PATH]` over a stand-in management client
  # (M75 §11, re-check R1). Sync: the verb prints refusals on
  # `:standard_error`, one globally registered device that concurrent
  # captures would share.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Fermix.CLI.DeviceCommand

  @home "/invented/fermix-home"
  @grants [
    %{"path" => "/Users/ana/Downloads", "granted_at" => "2026-10-27T09:30:00Z"},
    %{"path" => "/Users/ana/Taxes", "granted_at" => "2026-10-27T10:00:00Z"}
  ]

  defp run(argv, client) do
    parent = self()

    err =
      capture_io(:stderr, fn ->
        out =
          capture_io(fn ->
            send(parent, {:status, DeviceCommand.run(argv, home: @home, client: client)})
          end)

        send(parent, {:out, out})
      end)

    assert_received {:status, status}
    assert_received {:out, out}
    {status, out, err}
  end

  defp answering(test, answer) do
    fn method, params, opts ->
      assert Keyword.fetch!(opts, :socket_path) == Path.join(@home, "daemon.sock")
      send(test, {:called, method, params})
      answer
    end
  end

  test "grants lists the folders the server may read here, with the engine's sentence" do
    sentence = "The server may read 2 folders on this computer beyond what its sandbox allows."
    client = answering(self(), {:ok, %{"grants" => @grants, "sentence" => sentence}})

    assert {0, out, ""} = run(["grants"], client)

    assert out ==
             sentence <>
               "\n  /Users/ana/Downloads (since 2026-10-27T09:30:00Z)" <>
               "\n  /Users/ana/Taxes (since 2026-10-27T10:00:00Z)\n"

    assert_received {:called, "device.grants.list", %{}}
  end

  test "grants remove sends the folder as typed here, expanded, and --json prints the result" do
    result = %{
      "removed" => "/Users/ana/Downloads",
      "grants" => tl(@grants),
      "sentence" => "The server can no longer read that folder on this computer."
    }

    client = answering(self(), {:ok, result})

    assert {0, out, ""} = run(["grants", "remove", "/Users/ana/Downloads", "--json"], client)
    assert Jason.decode!(out) == %{"schema_version" => 1, "ok" => true, "result" => result}
    assert_received {:called, "device.grants.remove", %{"path" => "/Users/ana/Downloads"}}

    assert {0, "Removed /Users/ana/Downloads.\n" <> _sentence, ""} =
             run(["grants", "remove", "~/Taxes/../Downloads"], client)

    expected = Path.expand("~/Downloads")
    assert_received {:called, "device.grants.remove", %{"path" => ^expected}}
  end

  test "a refusal is the engine's own sentence, and a stopped engine is said so" do
    refusal =
      {:error,
       {:management_error, "invalid_params", "Request parameters are invalid.",
        %{"field" => "path", "sentence" => "This computer has no read grant for that folder."}}}

    assert {1, "", err} =
             run(["grants", "remove", "/Users/ana/Photos"], answering(self(), refusal))

    assert err ==
             "fermix device: Fermix did not do that on this computer. It said: This computer " <>
               "has no read grant for that folder.\n"

    assert {1, out, ""} = run(["grants", "--json"], answering(self(), {:error, :not_running}))
    assert %{"ok" => false, "error" => %{"code" => "engine_stopped"}} = Jason.decode!(out)
  end

  test "anything else is a usage error, and nothing is asked" do
    client = fn _method, _params, _opts -> flunk("no call on a usage error") end

    for argv <- [[], ["grants", "remove"], ["grants", "wipe"], ["grants", "--all"], ["list"]] do
      assert {2, "", err} = run(argv, client)
      assert err =~ "fermix device grants remove PATH"
    end
  end
end
