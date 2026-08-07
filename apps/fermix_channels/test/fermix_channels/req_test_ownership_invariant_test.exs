defmodule FermixChannels.ReqTestOwnershipInvariantTest do
  @moduledoc """
  `Req.Test.set_req_test_to_shared/1` may only be called from an `async: false`
  module.

  Shared mode is VM-global: `Req.Test.Ownership` records one owner pid, and every
  `Req.Test.stub/2` from any other process is then refused with
  `{:not_shared_owner, pid}`. It reverts when the owner exits, so the damage
  window is one test long — which is precisely why this is a concurrency bug and
  not a leak you can find by reading the file. An `async: false` module cannot
  overlap an `async: true` one, so confining shared mode to sync modules removes
  the window entirely.

  Written as a whole-surface invariant rather than a fix to one file: the
  offending call was a single vestigial line in `dispatcher_test.exs`
  (`async: true`), and it turned eight unrelated `media_download` tests red on
  linux-x64 while arm64 and macOS passed the same commit — same code, green five
  minutes earlier. A file added later either joins this invariant or fails it.
  """
  use ExUnit.Case, async: true

  @shared_call "set_req_test_to_shared"

  test "shared Req.Test ownership is confined to async: false modules" do
    offenders =
      test_files()
      |> Enum.filter(&calls_shared_mode?/1)
      |> Enum.filter(&async?/1)

    assert offenders == [],
           """
           These test modules put Req.Test into VM-global shared mode while running
           concurrently, so any other async test that stubs is refused with
           {:not_shared_owner, _}:

           #{Enum.map_join(offenders, "\n", &"  - #{&1}")}

           Either drop the call (it is often vestigial — a private-mode stub already
           covers a request issued in the test process), grant the specific spawned
           process with Req.Test.allow/3, or make the module async: false.
           """
  end

  defp test_files do
    Path.wildcard(Path.join([__DIR__, "..", "**", "*_test.exs"]))
    |> Enum.map(&Path.expand/1)
    |> Enum.reject(&(&1 == Path.expand(__ENV__.file)))
  end

  defp calls_shared_mode?(file), do: file |> File.read!() |> String.contains?(@shared_call)

  # `use ExUnit.Case` defaults to async: false, so only an explicit `async: true`
  # makes a module concurrent.
  defp async?(file), do: file |> File.read!() =~ ~r/async:\s*true/
end
