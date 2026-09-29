defmodule FermixChannels.Companion.Fanout do
  @moduledoc """
  Everyone watching a profile, and the one way a logical chat event reaches
  them: every connection on `companion.sock` (`Channels.Companion.broadcast/3`)
  and, while the mobile subtree runs, every connected phone
  (`Channels.Mobile.broadcast/3`). The two transports share one timeline, so
  what one client does the other must hear.

  Each watcher gets only the events its own wire carries
  (`FermixCore.Companion.Protocol.server_events/0`,
  `Mobile.Protocol.server_events/0`): a phone-only `link_preview` never reaches
  the Mac. A `row` is announced in the phone's shape (`Companion.Output.row/2`),
  and the Mac hears only the fields its own `row` has always carried. The
  sender is not left out, since every client deduplicates by `server_seq`.

  What is announced to everyone: every timeline row as a `row` (a user's
  message from either transport, a slash command's answer, a delivery) and
  `read_state`. A turn's stream and its ending (`text_done`, `turn_error`)
  belong to the transport that runs the turn (`:audience`); the other
  transport learns the reply as its `row`, because it never saw that turn
  start. An approval, with its resolution, belongs to the transport that
  raised it, the only one its token resolves from (`Companion.Approvals`).
  """

  alias FermixChannels.Channels.Companion
  alias FermixChannels.Channels.Mobile
  alias FermixChannels.Mobile.DeviceRegistry
  alias FermixChannels.Mobile.Protocol, as: MobileProtocol
  alias FermixCore.Companion.Protocol, as: CompanionProtocol

  @typedoc "One of the two companion transports: the Mac's socket or the phones."
  @type transport :: :companion | :mobile

  @type audience :: transport() | :all

  @companion_row_fields ~w(t profile_id server_seq role text ts client_msg_id)

  @doc """
  Announce one logical event to the profile's watchers. Options:
  `:audience` (`:all` by default), and the `:companion_registry` and
  `:device_registry` a caller's connections joined, when not the defaults.
  """
  @spec announce(String.t(), map(), keyword()) :: :ok
  def announce(profile_id, %{"t" => type} = event, opts \\ [])
      when is_binary(profile_id) and is_binary(type) and is_list(opts) do
    audience = Keyword.get(opts, :audience, :all)
    :ok = to_companion(audience, profile_id, event, opts)
    to_phones(audience, profile_id, event, opts)
  end

  defp to_companion(audience, profile_id, %{"t" => type} = event, opts)
       when audience in [:all, :companion] do
    if type in CompanionProtocol.server_events() do
      registry = Keyword.get(opts, :companion_registry, Companion.registry())
      Companion.broadcast(profile_id, companion_shape(event), registry)
    else
      :ok
    end
  end

  defp to_companion(:mobile, _profile_id, _event, _opts), do: :ok

  defp companion_shape(%{"t" => "row"} = event), do: Map.take(event, @companion_row_fields)
  defp companion_shape(event), do: event

  defp to_phones(audience, profile_id, %{"t" => type} = event, opts)
       when audience in [:all, :mobile] do
    if type in MobileProtocol.server_events() do
      Mobile.broadcast(profile_id, event, Keyword.get(opts, :device_registry, DeviceRegistry))
    else
      :ok
    end
  end

  defp to_phones(:companion, _profile_id, _event, _opts), do: :ok
end
