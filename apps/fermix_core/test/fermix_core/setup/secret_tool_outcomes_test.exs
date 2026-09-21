defmodule FermixCore.Setup.SecretWriter.SecretToolOutcomesTest do
  use ExUnit.Case, async: true

  alias FermixCore.Setup.SecretWriter.SecretTool

  @key :openai_api_key

  describe "put/3, the three outcomes" do
    test "an unlocked collection stores the value" do
      assert :ok = put(:ready)
    end

    test "a locked collection refuses without raising a prompt nobody asked for" do
      # The caller may be a headless daemon and the owner may not be at the
      # machine, so nothing runs: the refusal is the answer.
      assert {:error, :keyring_locked} = put(:locked, unlock: false)
    end

    # A promise, not an accident, and the reason it is one: on a locked
    # collection `secret-tool` behaves differently by environment — with a
    # display it blocks on gcr-prompter, without one it exits 1 — so the same
    # machine state would produce two different reasons if the helper were
    # consulted. Once the property says locked, the helper is not asked.
    test "a locked collection runs no helper at all, so its exit cannot decide the answer" do
      runner = fn binary, args, _opts -> flunk("ran #{binary} #{Enum.join(args, " ")}") end

      assert {:error, :keyring_locked} = put(:locked, unlock: false, runner: runner)
    end

    test "no Secret Service is unavailable, which is a different problem" do
      assert {:error, :unavailable} = put(:unavailable)
    end
  end

  describe "put/3 with unlock: true" do
    test "waits for the owner to answer the prompt, on its own bound" do
      owner = self()

      runner = fn binary, args, opts ->
        send(owner, {:ran, binary, args, opts[:timeout_ms]})
        {:ok, %{exit: 0, stdout: "", truncated?: false}}
      end

      assert :ok = put(:locked, unlock: true, runner: runner)

      assert_received {:ran, _binary, _args, timeout}
      assert timeout == SecretTool.unlock_timeout_ms()
      # The 3-second default must not reach this path.
      assert timeout > 3_000
    end

    test "an unlock that is never completed refuses as locked, at the cap" do
      cap = SecretTool.unlock_timeout_ms()
      runner = fn _binary, _args, _opts -> {:error, {:timeout, cap}} end

      assert {:error, :keyring_locked} = put(:locked, unlock: true, runner: runner)
    end

    test "the cap stays under the deadline the desktop client allows it" do
      # slice5-app gives an unlock call about 105 s. The engine's own answer
      # must arrive first, or the person sees the app's timeout instead of the
      # reason they can act on.
      assert SecretTool.unlock_timeout_ms() < 105_000
    end
  end

  defp put(state, opts \\ []) do
    runner =
      Keyword.get(opts, :runner, fn _binary, _args, _opts ->
        {:ok, %{exit: 0, stdout: "", truncated?: false}}
      end)

    SecretTool.put(@key, "sk-value",
      secret_service_state: state,
      unlock: Keyword.get(opts, :unlock, false),
      secret_tool: "/usr/bin/secret-tool",
      shell: "/bin/sh",
      runner: runner
    )
  end
end
