defmodule FermixCore.Realtime.Endpoint do
  @moduledoc """
  Who an owner-voice call is for: the endpoint whose microphone and speaker
  carry it (M91 §04, D24).

    * `:desktop` is the Mac app's call over `realtime.sock`, string form
      `"desktop"`.
    * `{:accessory, accessory_id}` is a paired Fermix accessory's call, string
      form `"accessory:<accessory_id>"`. An accessory is a physical device paired
      with a home; "device" already names a computer in an Always On home.

  The voice policy that differs by endpoint lives here and nowhere else, so a
  new kind is one more clause per function: screen sharing is offered to the
  desktop alone, and the safety identifier an OpenAI Realtime call sends is
  derived from the endpoint (the task engines send none). Pure: no process, no
  I/O.
  """

  alias FermixCore.Realtime.DeviceIdentity

  @type t :: :desktop | {:accessory, String.t()}

  # Bounded and colon-free, so an id can never smuggle a second endpoint into
  # the string form.
  @accessory_id ~r/\A[A-Za-z0-9_-]{1,64}\z/

  @doc "Reads an endpoint's string form, refusing anything that is not one."
  @spec parse(String.t()) :: {:ok, t()} | {:error, {:invalid_endpoint, String.t()}}
  def parse("desktop"), do: {:ok, :desktop}

  def parse("accessory:" <> accessory_id = given) do
    if accessory_id?(accessory_id),
      do: {:ok, {:accessory, accessory_id}},
      else: {:error, {:invalid_endpoint, given}}
  end

  def parse(given) when is_binary(given), do: {:error, {:invalid_endpoint, given}}

  @doc "The endpoint's string form: what a call lease and the wire name."
  @spec format(t()) :: String.t()
  def format(:desktop), do: "desktop"

  def format({:accessory, accessory_id} = endpoint) when is_binary(accessory_id) do
    if accessory_id?(accessory_id),
      do: "accessory:" <> accessory_id,
      else: raise(ArgumentError, "invalid voice endpoint: #{inspect(endpoint)}")
  end

  @doc """
  Whether a call for this endpoint is offered `screen_share`. The shared screen
  is the Mac's, so only a call made at the Mac may watch it; the owner's
  `screen_share` setting still decides for the desktop.
  """
  @spec screen_share?(t()) :: boolean()
  def screen_share?(:desktop), do: true
  def screen_share?({:accessory, _accessory_id}), do: false

  @doc """
  The OpenAI safety identifier for a call, which only an OpenAI Realtime
  session sends; the task engines ignore it. The desktop keeps the one every
  Realtime call has carried, the owner and this Mac's realtime device id; an
  accessory hashes the owner with its own endpoint string, so its calls are
  told apart from the Mac's and stay the same whichever Mac it is plugged
  into.
  """
  @spec safety_identifier(t(), String.t(), String.t()) :: String.t()
  def safety_identifier(:desktop, owner_id, mac_device_id)
      when is_binary(owner_id) and is_binary(mac_device_id),
      do: DeviceIdentity.safety_identifier(owner_id, mac_device_id)

  def safety_identifier({:accessory, _accessory_id} = endpoint, owner_id, mac_device_id)
      when is_binary(owner_id) and is_binary(mac_device_id),
      do: DeviceIdentity.safety_identifier(owner_id, format(endpoint))

  defp accessory_id?(accessory_id), do: Regex.match?(@accessory_id, accessory_id)
end
