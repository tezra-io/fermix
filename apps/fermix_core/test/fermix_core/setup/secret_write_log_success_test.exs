defmodule FermixCore.Setup.SecretWriteLogSuccessTest do
  use ExUnit.Case, async: true

  alias FermixCore.Setup.SecretWriteLog
  alias FermixCore.Setup.SecretWriter.SecretTool

  # The regression this pins is not in the writer but in what its CALLERS can
  # match on. `secret-tool` exits 0 and prints nothing, and the writer used to
  # hand that stdout back as `{:ok, ""}`; every caller matches `:ok`, so a
  # SUCCESSFUL Linux store raised CaseClauseError here — after the item was
  # written. The person was told the save failed while their credential sat in
  # the keyring. A writer-level assertion would not have caught it: the writer
  # was answering consistently, just not in the shape its callers accept.
  test "a store the helper accepted returns success to its caller" do
    runner = fn _binary, _args, _opts -> {:ok, %{exit: 0, stdout: "", truncated?: false}} end

    result =
      SecretWriteLog.put(:openai_api_key, "sk-live",
        impl: SecretTool,
        secret_service_state: :ready,
        secret_tool: "/usr/bin/secret-tool",
        shell: "/bin/sh",
        runner: runner,
        home: unused_home()
      )

    assert result == :ok
  end

  # A home no file store will ever write to: this test exercises the keyring
  # path, and the keyring write's own cleanup of a superseded file copy must
  # not reach the developer's real home.
  defp unused_home do
    Path.join(System.tmp_dir!(), "fermix-write-log-#{System.unique_integer([:positive])}")
  end
end
