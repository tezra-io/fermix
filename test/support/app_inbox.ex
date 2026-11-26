defmodule FermixTestSupport.AppInbox do
  @moduledoc """
  The Fermix app as the owner's inbox (M106 §8, D3), for a test's
  delivery-channels map (`[fermix_core.jobs] delivery_channels`): the Mac
  chat names its inbox, `main`, and the phones' channel has a phone whose
  pairing completed. Neither sends anything: a test that observes the send
  injects its own adapter on the send path (`ChannelSend`'s `:adapter`).
  """

  defmodule MacChat do
    @moduledoc false
    def send_message(_destination, _text, _opts), do: :ok
    def owner_inbox, do: {:ok, "main"}
  end

  defmodule PairedPhone do
    @moduledoc false
    def send_message(_destination, _text, _opts), do: :ok
    def owner_inbox, do: {:ok, "main"}
    def phone_paired?, do: true
  end

  @doc "A delivery-channels map with the app's two channels, a phone paired, and `extra`."
  @spec channels(map()) :: map()
  def channels(extra \\ %{}) when is_map(extra),
    do: Map.merge(%{"companion" => MacChat, "mobile" => PairedPhone}, extra)

  @doc "The inbox seams of a home with a Telegram DM and a paired phone: the app comes first."
  @spec opts(map()) :: keyword()
  def opts(extra_channels \\ %{}) when is_map(extra_channels),
    do: [
      jobs_config: [delivery_channels: channels(extra_channels)],
      configured_owners: %{"telegram" => "40017"}
    ]
end
