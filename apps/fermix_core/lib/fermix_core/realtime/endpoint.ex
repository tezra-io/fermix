defmodule FermixCore.Realtime.Endpoint do
  @moduledoc """
  Who an owner-voice call is for: the endpoint whose microphone and speaker
  carry it (M91 §04, D24).

    * `:desktop` is the Mac app's call over `realtime.sock`, string form
      `"desktop"`.
    * `{:accessory, accessory_id}` is a paired Fermix accessory's call, string
      form `"accessory:<accessory_id>"`. An accessory is a physical device paired
      with a home; "device" already names a computer in an Always On home.
    * `{:phone, device_id}` is a paired phone's call over its mobile session
      (M87), string form `"phone:<device_id>"`, the id the phone's pairing
      minted.
    * `{:computer, device_id}` is a linked computer's call on its server (M97
      §9.2, D18): the computer's app speaks its own `realtime.sock`, which
      its engine bridges over the link to the server's call channel, the
      phone's. String form `"computer:<device_id>"`, its device row's id; a
      person reads it as "on <the computer's name>".

  The voice policy that differs by endpoint lives here and nowhere else, so a
  new kind is one more clause per function: screen sharing is offered to the
  desktop alone and a camera to the phone alone, the safety identifier an
  OpenAI Realtime call sends is derived from the endpoint (the task engines
  send none), and a phone takes a call only on a task engine, while a
  computer's call runs on whatever engine the server's voice setting names
  (D19). Pure: no process, no I/O.
  """

  alias FermixCore.Realtime.DeviceIdentity

  @type t ::
          :desktop | {:accessory, String.t()} | {:phone, String.t()} | {:computer, String.t()}

  # Bounded and colon-free, so an id can never smuggle a second endpoint into
  # the string form. A paired phone's device id, a lowercase UUID, fits it.
  @endpoint_id ~r/\A[A-Za-z0-9_-]{1,64}\z/
  # The engines a phone's call may run on: the task engines, which join the
  # chat and hand every task to the Fermix agent (M87 D2).
  @phone_engines ["openai_live", "xai_realtime"]
  # A phone's Grok playback window: inside the phone call's 1 s credit with
  # one vendor chunk (`grok_playback_opts/1`). A computer's call rides the
  # same call channel and credit.
  @call_channel_grok_window_ms 300
  # The endpoints that name a device by its id, and their string forms.
  @id_kinds %{"accessory" => :accessory, "phone" => :phone, "computer" => :computer}

  @doc "Reads an endpoint's string form, refusing anything that is not one."
  @spec parse(String.t()) :: {:ok, t()} | {:error, {:invalid_endpoint, String.t()}}
  def parse("desktop"), do: {:ok, :desktop}

  def parse(given) when is_binary(given) do
    with [prefix, id] <- String.split(given, ":", parts: 2),
         {:ok, kind} <- Map.fetch(@id_kinds, prefix),
         true <- endpoint_id?(id) do
      {:ok, {kind, id}}
    else
      _invalid -> {:error, {:invalid_endpoint, given}}
    end
  end

  @doc "The endpoint's string form: what a call lease and the wire name."
  @spec format(t()) :: String.t()
  def format(:desktop), do: "desktop"

  def format({:accessory, accessory_id} = endpoint) when is_binary(accessory_id),
    do: "accessory:" <> checked_id!(accessory_id, endpoint)

  def format({:phone, device_id} = endpoint) when is_binary(device_id),
    do: "phone:" <> checked_id!(device_id, endpoint)

  def format({:computer, device_id} = endpoint) when is_binary(device_id),
    do: "computer:" <> checked_id!(device_id, endpoint)

  @doc """
  Whether a call for this endpoint is offered `screen_share`. The shared screen
  is the Mac's, so only a call made at the Mac may watch it; the owner's
  `screen_share` setting still decides for the desktop. A computer's call
  runs on its server, whose screen is no one's (M97 D21).
  """
  @spec screen_share?(t()) :: boolean()
  def screen_share?(:desktop), do: true
  def screen_share?({:accessory, _accessory_id}), do: false
  def screen_share?({:phone, _device_id}), do: false
  def screen_share?({:computer, _device_id}), do: false

  @doc """
  Whether a call for this endpoint may share a camera (M87 Phase 2): a phone's,
  whose frames ride its own mobile session. The Mac's socket and an accessory
  have no way to carry a frame, so the Realtime wire's `camera` is refused from
  them whatever their hello says.
  """
  @spec camera?(t()) :: boolean()
  def camera?({:phone, _device_id}), do: true
  def camera?(:desktop), do: false
  def camera?({:accessory, _accessory_id}), do: false
  def camera?({:computer, _device_id}), do: false

  @doc """
  Whether a call for this endpoint may run on `engine`, refused before any
  session starts. A phone's call runs only on a task engine: the Realtime
  engine joins no chat, leaves no gist, and offers a screen-share tool that
  would watch a Mac the caller is away from (M87 D2).
  """
  @spec admit_engine(t(), String.t()) :: :ok | {:error, :engine_not_for_phones}
  def admit_engine({:phone, _device_id}, engine) when is_binary(engine) do
    if engine in @phone_engines, do: :ok, else: {:error, :engine_not_for_phones}
  end

  def admit_engine(endpoint, engine) when is_binary(engine) do
    _valid = format(endpoint)
    :ok
  end

  @doc """
  How a Grok call paces its audio to this endpoint: the options its
  `GrokPlayback` starts with. A phone's audio rides its mobile session, where
  the call holds at most 1 s unplayed on the phone and drops audio that
  waited 300 ms to be written (`FermixChannels.Mobile.CallAudio`); a reply
  Grok streams faster than it plays would pile up behind that credit and age
  out. So a phone's window is 300 ms, which with one vendor chunk of up to
  200 ms stays inside the credit, and the rest waits in `GrokPlayback`, paced
  by the phone's reports. A computer's call rides the same call channel, so
  it takes the same window. The desktop and an accessory keep the default.
  """
  @spec grok_playback_opts(t()) :: keyword()
  def grok_playback_opts({kind, _device_id} = endpoint) when kind in [:phone, :computer] do
    _valid = format(endpoint)
    [window_ms: @call_channel_grok_window_ms]
  end

  def grok_playback_opts(endpoint) do
    _valid = format(endpoint)
    []
  end

  @doc """
  The OpenAI safety identifier for a call, which only an OpenAI Realtime
  session sends; the task engines ignore it. The desktop keeps the one every
  Realtime call has carried, the owner and this Mac's realtime device id; an
  accessory hashes the owner with its own endpoint string, so its calls are
  told apart from the Mac's and stay the same whichever Mac it is plugged
  into. A phone and a computer follow the accessory's rule, so their calls
  are their own and stay the same wherever the primary runs.
  """
  @spec safety_identifier(t(), String.t(), String.t()) :: String.t()
  def safety_identifier(:desktop, owner_id, mac_device_id)
      when is_binary(owner_id) and is_binary(mac_device_id),
      do: DeviceIdentity.safety_identifier(owner_id, mac_device_id)

  def safety_identifier({kind, _id} = endpoint, owner_id, mac_device_id)
      when kind in [:accessory, :phone, :computer] and is_binary(owner_id) and
             is_binary(mac_device_id),
      do: DeviceIdentity.safety_identifier(owner_id, format(endpoint))

  defp endpoint_id?(id), do: Regex.match?(@endpoint_id, id)

  defp checked_id!(id, endpoint) do
    if endpoint_id?(id),
      do: id,
      else: raise(ArgumentError, "invalid voice endpoint: #{inspect(endpoint)}")
  end
end
