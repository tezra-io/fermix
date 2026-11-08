defmodule FermixCore.Accessories.Record do
  @moduledoc """
  One enrolled accessory, as the pairing store keeps it
  (`FermixCore.Accessories.Store`): its ID (the hex SHA-256 of its public key,
  the `accessory:<accessory_id>` voice endpoint's ID), its public key, its
  kind, the name the owner sees, the USB serial string seen at enrollment (a
  hint for which port to open, never an identity), and when it enrolled.
  """

  @enforce_keys [:accessory_id, :accessory_pk, :kind, :name, :enrolled_at]
  defstruct @enforce_keys ++ [port_hint: nil]

  @type t :: %__MODULE__{
          accessory_id: String.t(),
          accessory_pk: <<_::520>>,
          kind: String.t(),
          name: String.t(),
          port_hint: String.t() | nil,
          enrolled_at: DateTime.t()
        }
end
