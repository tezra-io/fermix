defmodule FermixCore.Auth.JwtClaims do
  @moduledoc """
  Minimal JWT payload reading for token-expiry bookkeeping.

  No signature verification — the token is opaque to Fermix; only the
  `exp` claim matters, and only for refresh scheduling (design doc §6.4:
  xAI token responses omit `expires_in` and the access token is a JWT).
  A token that fails to parse simply yields no expiry.
  """

  @spec expires_at(String.t() | nil) :: DateTime.t() | nil
  def expires_at(token) when is_binary(token) do
    with [_header, payload, _signature] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{"exp" => exp}} when is_integer(exp) and exp > 0 <- Jason.decode(json),
         # Tuple form: an out-of-range exp (year 10000+) degrades to nil
         # instead of raising out of the refresh GenServer.
         {:ok, expires_at} <- DateTime.from_unix(exp) do
      expires_at
    else
      _other -> nil
    end
  end

  def expires_at(_token), do: nil
end
