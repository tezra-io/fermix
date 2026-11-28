defmodule FermixCore.Companion.ProtocolApprovalsTest do
  @moduledoc """
  What `priv/companion/PROTOCOL.md` says of an approval card (M106 §8, §11.1,
  stage S6): a card Fermix asks in the app with no turn goes to this socket
  and the phones, and a heal's (`job_change`) is kept in the home's record
  and sent again after every `server_hello`, a restart too. No field and no
  version moved for it: the document says what is true now, in the words the
  phone's document uses (`FermixChannels.Mobile.ProtocolContractTest`).
  """

  use ExUnit.Case, async: true

  @protocol_path Application.app_dir(:fermix_core, "priv/companion/PROTOCOL.md")

  setup_all do
    protocol = File.read!(@protocol_path)
    [_before, approvals] = String.split(protocol, "## Approvals", parts: 2)
    [approvals | _rest] = String.split(approvals, "\n## ", parts: 2)

    %{
      approvals: String.replace(approvals, ~r/\s+/, " "),
      squashed: String.replace(protocol, ~r/\s+/, " ")
    }
  end

  test "an approval asked in the app goes to both transports and is answered from either", ctx do
    assert ctx.approvals =~ "Its `kind` is `sandbox`, `soul` or `job_change`"
    assert ctx.approvals =~ "goes to this socket and the phones alike, is answered from either"
    refute ctx.approvals =~ "A card belongs to the transport whose turn raised it"

    assert ctx.squashed =~
             "| `approval` | `approval_id`, `kind`, `text`, `token`, `ttl_s`, " <>
               "`approve_command`, `deny_command`; `detail?` | An owner-approval card raised " <>
               "by a turn on this socket, or asked in the Fermix app with no turn."

    assert ctx.squashed =~ "an approval Fermix asks in the app with no turn reaches both"
  end

  test "a heal's card is kept in the home's record and sent again, a restart too", ctx do
    assert ctx.approvals =~
             "is kept in the home's record, not in memory, and lives up to seven days"

    assert ctx.approvals =~
             "sent again after every `server_hello` while it waits, after a restart too"

    assert ctx.approvals =~ "Every other card lives in the daemon's memory, as its token does"
    refute ctx.approvals =~ "Waiting cards live in the daemon's memory"
    assert ctx.squashed =~ "unlike a turn's approval), so it survives a restart"
  end
end
