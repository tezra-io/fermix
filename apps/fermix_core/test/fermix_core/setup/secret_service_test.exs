defmodule FermixCore.Setup.SecretWriter.SecretServiceTest do
  use ExUnit.Case, async: true

  alias FermixCore.Setup.SecretWriter.SecretService

  @alias_path "/org/freedesktop/secrets/collection/login"

  describe "state/1" do
    test "a locked default collection is locked, read from the alias it resolves" do
      {state, calls} = probe(alias_reply(@alias_path), locked_reply(true))

      assert state == :locked

      # The collection is whichever the default alias names — never a
      # hardcoded /collection/login, which KWallet and KeePassXC do not use.
      assert ["ReadAlias", "s", "default"] = Enum.take(Enum.at(calls, 0), -3)
      assert @alias_path in Enum.at(calls, 1)
    end

    test "an unlocked default collection is ready" do
      {state, _calls} = probe(alias_reply(@alias_path), locked_reply(false))

      assert state == :ready
    end

    test "a bus with no default alias is unavailable rather than locked" do
      # No alias is no Secret Service this engine can write through. Calling it
      # locked would offer an unlock for a keyring that is not there.
      {state, calls} = probe({:ok, %{exit: 1, stdout: "", truncated?: false}}, locked_reply(true))

      assert state == :unavailable
      assert length(calls) == 1
    end

    test "a bus that answers nothing readable is unavailable, not a guess" do
      {state, _calls} =
        probe(alias_reply(@alias_path), {:ok, %{exit: 0, stdout: "b maybe\n", truncated?: false}})

      assert state == :unavailable
    end

    test "no busctl on the host is unavailable, and nothing is run" do
      state = SecretService.state(busctl: nil, runner: fn _b, _a, _o -> flunk("ran a probe") end)

      assert state == :unavailable
    end

    test "a probe that hangs is bounded and unavailable" do
      timeout = SecretService.probe_timeout_ms()

      {state, _calls} = probe({:error, {:timeout, timeout}}, locked_reply(true))

      assert state == :unavailable
    end
  end

  defp probe(first, second) do
    owner = self()
    replies = :counters.new(1, [])

    runner = fn binary, args, _opts ->
      send(owner, {:probe, [binary | args]})

      case :counters.get(replies, 1) do
        0 ->
          :counters.add(replies, 1, 1)
          first

        _later ->
          second
      end
    end

    state = SecretService.state(busctl: "/usr/bin/busctl", runner: runner)
    {state, collect_calls()}
  end

  defp collect_calls(acc \\ []) do
    receive do
      {:probe, call} -> collect_calls(acc ++ [call])
    after
      0 -> acc
    end
  end

  defp alias_reply(path), do: {:ok, %{exit: 0, stdout: ~s(o "#{path}"\n), truncated?: false}}

  defp locked_reply(locked?),
    do: {:ok, %{exit: 0, stdout: "b #{locked?}\n", truncated?: false}}
end
