defmodule FermixCore.Browser.Scope do
  @moduledoc false

  alias FermixCore.Browser.Error

  @spec owner_key(map()) :: {:ok, String.t()} | {:error, Error.t()}
  def owner_key(%{conversation_key: key}) do
    digest =
      key
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)

    {:ok, digest}
  end

  def owner_key(_context) do
    {:error,
     Error.new(
       "missing_conversation_key",
       "browser requires conversation_key in the tool context"
     )}
  end
end
