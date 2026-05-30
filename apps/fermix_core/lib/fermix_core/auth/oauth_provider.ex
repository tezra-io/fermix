defmodule FermixCore.Auth.OAuthProvider do
  @moduledoc """
  Provider configuration for Authorization Code + PKCE flows.
  """

  @type t :: %__MODULE__{
          id: atom(),
          authorize_url: String.t(),
          token_url: String.t(),
          userinfo_url: String.t() | nil,
          client_id: String.t(),
          client_secret: String.t() | nil,
          redirect_host: String.t(),
          redirect_port: :inet.port_number(),
          redirect_path: String.t(),
          scopes: [String.t()],
          extra_authorize_params: map()
        }

  @enforce_keys [
    :id,
    :authorize_url,
    :token_url,
    :client_id,
    :redirect_host,
    :redirect_port,
    :redirect_path,
    :scopes
  ]
  defstruct [
    :id,
    :authorize_url,
    :token_url,
    :userinfo_url,
    :client_id,
    :client_secret,
    :redirect_host,
    :redirect_port,
    :redirect_path,
    scopes: [],
    extra_authorize_params: %{}
  ]

  @spec google(keyword()) :: t()
  def google(opts) when is_list(opts) do
    %__MODULE__{
      id: :google,
      authorize_url: "https://accounts.google.com/o/oauth2/v2/auth",
      token_url: "https://oauth2.googleapis.com/token",
      userinfo_url: "https://openidconnect.googleapis.com/v1/userinfo",
      client_id: Keyword.fetch!(opts, :client_id),
      client_secret: Keyword.get(opts, :client_secret),
      redirect_host: Keyword.get(opts, :redirect_host, "127.0.0.1"),
      redirect_port: Keyword.get(opts, :redirect_port, 1455),
      redirect_path: Keyword.get(opts, :redirect_path, "/auth/callback"),
      scopes: Keyword.get(opts, :scopes, []),
      extra_authorize_params: %{"access_type" => "offline", "prompt" => "consent"}
    }
  end
end
