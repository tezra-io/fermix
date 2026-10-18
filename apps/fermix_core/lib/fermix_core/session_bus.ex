defmodule FermixCore.SessionBus do
  @moduledoc """
  What the account's D-Bus session bus answers when it is not there to ask,
  read from `busctl`'s own words. One owner for every reader that asks the bus
  through `busctl --user`: the keyring probe (`Setup.SecretService.Probe`) and
  desktop notifications (`Native.Notifications.DBus`).
  """

  # What busctl says, verbatim, when there is no session bus to ask: no
  # address at all (a shell reached with `su`, some SSH logins, a `--system`
  # unit), or an address with nothing listening behind it.
  @no_bus_marks [
    "Failed to set bus address",
    "Failed to connect to bus",
    "No such file or directory",
    "Connection refused",
    "not defined",
    "No medium found"
  ]

  @doc "Whether `busctl` output says no session bus could be reached."
  @spec unreachable?(String.t()) :: boolean()
  def unreachable?(output) when is_binary(output), do: String.contains?(output, @no_bus_marks)
end
