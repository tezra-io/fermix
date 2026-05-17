defmodule FermixCore.Sandbox.HardlineTest do
  use ExUnit.Case, async: true

  alias FermixCore.Sandbox.Hardline

  test "allows normal local commands" do
    assert :allow = Hardline.classify("pwd")
    assert :allow = Hardline.classify("mix test")
    assert :allow = Hardline.classify("git status --short")
  end

  test "blocks catastrophic fixture strings without executing them" do
    commands = [
      "rm -rf /",
      "\\rm -rf /",
      "/bin/rm -rf /",
      "command rm -rf /",
      "'rm' -rf /",
      "rm -rf ~",
      "rm -rf $HOME",
      "mkfs.ext4 /dev/disk2",
      "dd if=/tmp/a of=/dev/disk2",
      ":(){ :|:& };:",
      "kill -1",
      "kill -9 -1",
      "pkill -9 -u $USER",
      "shutdown now",
      "systemctl poweroff",
      "init 0",
      "sudo -S rm -rf /"
    ]

    for command <- commands do
      assert {:hardline, reason} = Hardline.classify(command)
      assert is_binary(reason)
      assert reason != ""
    end
  end
end
