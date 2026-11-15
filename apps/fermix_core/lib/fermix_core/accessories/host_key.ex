defmodule FermixCore.Accessories.HostKey do
  @moduledoc """
  This home's host key for the accessory link (M91 D14): the P-256 key the
  daemon signs every attach with and an accessory stores at enrollment. It
  lives under `<home>/accessories/` (`FermixCore.Accessories.Store`), travels
  with the home (D7), and becomes the Phase B TLS server identity.
  """

  alias FermixCore.Accessories.P256

  @enforce_keys [:private, :public, :id]
  defstruct @enforce_keys

  @type t :: %__MODULE__{private: P256.private_key(), public: P256.public_key(), id: String.t()}

  @doc "The host key of a private scalar, refusing one that is not a P-256 scalar."
  @spec from_private(binary()) :: {:ok, t()} | {:error, :invalid_host_key}
  def from_private(private) when is_binary(private) do
    case P256.public_key(private) do
      {:ok, public} -> {:ok, %__MODULE__{private: private, public: public, id: P256.id(public)}}
      {:error, :invalid_private_key} -> {:error, :invalid_host_key}
    end
  end

  defimpl Inspect do
    # The private scalar never reaches a log or a crash report.
    def inspect(key, _opts), do: "#FermixCore.Accessories.HostKey<#{key.id}>"
  end
end
