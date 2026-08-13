defmodule FermixChannels.Mobile.Push.Dispatcher do
  @moduledoc false

  alias FermixChannels.Mobile.Push.Config
  alias Pigeon.APNS.Notification

  @callback dispatch([Notification.t()], Config.t()) ::
              {:ok, [Notification.t()]} | {:error, term()}
end
