defmodule Fermix.CLI.MemoryCommandRoleTest do
  # M75 D13: a device-role engine writes no long-term memory and calls no
  # provider, so `fermix memory review --now` and `restore` refuse by name.
  #
  # Sync: the refusal prints on `:standard_error`, one globally registered device.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Fermix.CLI.MemoryCommand

  @device %{role: :device, primary: "aws i-0f3b1c"}
  @sentence "This engine runs in the device role; the primary is aws i-0f3b1c."

  for argv <- [["review", "--now"], ["restore", "41"]] do
    @argv argv

    test "fermix memory #{Enum.join(argv, " ")} is refused on a device" do
      err =
        capture_io(:stderr, fn ->
          send(self(), {:status, MemoryCommand.run(@argv, engine_role: @device)})
        end)

      assert_received {:status, 1}
      assert err == "fermix memory: #{@sentence}\n"
    end
  end
end
