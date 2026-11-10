defmodule FermixCore.Computers.Computer do
  @moduledoc """
  One computer of the home, as the primary knows it (M97 §3.2): its id and
  the name the owner calls it (unique in the home), its system, the engine
  version it last said, whether its session is up and since when, when the
  home last heard it, the path its session runs, what it offers, and
  whether it keeps the home's backup copies.

  Built by `FermixCore.Computers.list/1` from its device row, the live facts
  (`Computers.Registry`) and its record (`Computers.Store`).
  """

  alias FermixCore.Computers.Offers

  @enforce_keys [:device_id, :name]
  defstruct [
    :device_id,
    :name,
    platform: nil,
    engine_version: nil,
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
          connected: boolean(),
          since: DateTime.t() | nil,
          last_seen: DateTime.t() | nil,
          path: :direct | :relay | nil,
          offers: [Offers.offer()],
          backups: boolean()
        }

  @doc "The computer as `home.status` lists it in `computers`."
  @spec view(t()) :: map()
  def view(%__MODULE__{} = computer) do
    %{
      "device_id" => computer.device_id,
      "name" => computer.name,
      "platform" => computer.platform && Atom.to_string(computer.platform),
      "engine_version" => computer.engine_version,
      "connected" => computer.connected,
      "since" => iso(computer.since),
      "last_seen" => iso(computer.last_seen),
      "path" => computer.path && Atom.to_string(computer.path),
      "offers" => Enum.map(computer.offers, &Offers.view/1),
      "backups" => computer.backups
    }
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
