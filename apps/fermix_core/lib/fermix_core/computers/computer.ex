defmodule FermixCore.Computers.Computer do
  @moduledoc """
  One computer of the home, as the primary knows it (M97 §3.2): its id and
  the name the owner calls it (unique in the home), its system, the engine
  version it last said and where that stands against this server
  (`Computers.Versions`, §3.4; nil before it said one), whether its session
  is up and since when, when the home last heard it, the path its session
  runs, what it offers, and whether it keeps the home's backup copies.

  Built by `FermixCore.Computers.list/1` from its device row, the live facts
  (`Computers.Registry`) and its record (`Computers.Store`).
  """

  alias FermixCore.Computers.Offers
  alias FermixCore.Computers.Versions

  @enforce_keys [:device_id, :name]
  defstruct [
    :device_id,
    :name,
    platform: nil,
    engine_version: nil,
    standing: nil,
    connected: false,
    since: nil,
    last_seen: nil,
    path: nil,
    offers: [],
    backups: true
  ]

  @type t :: %__MODULE__{
          device_id: String.t(),
          name: String.t(),
          platform: :macos | :linux | nil,
          engine_version: String.t() | nil,
          standing: Versions.standing() | nil,
          connected: boolean(),
          since: DateTime.t() | nil,
          last_seen: DateTime.t() | nil,
          path: :direct | :relay | nil,
          offers: [Offers.offer()],
          backups: boolean()
        }

  @doc """
  The computer as `home.status` lists it in `computers`, each offer with the
  words it goes by (`Offers.label/1`), and `this_computer` true on the row
  of `asking`, the device id of the linked computer whose request this
  answers (nil for any other caller).
  """
  @spec view(t(), String.t() | nil) :: map()
  def view(%__MODULE__{} = computer, asking \\ nil) when is_binary(asking) or is_nil(asking) do
    %{
      "device_id" => computer.device_id,
      "name" => computer.name,
      "platform" => computer.platform && Atom.to_string(computer.platform),
      "engine_version" => computer.engine_version,
      "standing" => computer.standing && Atom.to_string(computer.standing),
      "connected" => computer.connected,
      "since" => iso(computer.since),
      "last_seen" => iso(computer.last_seen),
      "path" => computer.path && Atom.to_string(computer.path),
      "offers" => Enum.map(computer.offers, &offer_view/1),
      "backups" => computer.backups,
      "this_computer" => computer.device_id == asking
    }
  end

  defp offer_view(offer), do: Map.put(Offers.view(offer), "label", Offers.label(offer.id))

  @doc """
  The computer whose request a management answer is for, from the router's
  `actor`: a linked computer's forward over its own session
  (`{:desktop, device_id}`, which the daemon names from that session) is its
  device id; every other caller (the server's own app, its setup page, a
  verb) is nil.
  """
  @spec asking(term()) :: String.t() | nil
  def asking({:desktop, device_id}) when is_binary(device_id), do: device_id
  def asking(_actor), do: nil

  defp iso(nil), do: nil
  defp iso(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
