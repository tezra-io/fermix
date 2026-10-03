defmodule FermixCore.Auth.ChatGPT.Registration do
  @moduledoc """
  The `chatgpt` entry in `auth.json`: one registration per home (M57 D3).

  It carries the client OpenAI issued this home (`client_id`), the verified
  account (`subject`, and the email under `account`, which
  `Store.account_label/1` reads), the scopes the token response granted, the
  token set, `expires_at` and `earliest_refresh_at`. Its `status`:

    * `"pending"`: a client was issued but the sign-in did not finish. No
      tokens; the next sign-in reuses the client instead of registering again.
    * `"ready"`: signed in.
    * `"signed_out"`: tokens cleared; client, subject and email kept.
    * `"reauthorization_required"`: a refresh was refused for good. The token
      managers write it, as they do for every OAuth profile.

  A pending or signed-out entry holds no access token, so `Store.read/2`, which
  every reader that serves or reports a sign-in uses, refuses it: only this
  module reads a registration without a token (`Store.read_registration/2`).
  """

  alias FermixCore.Auth.Store

  require Logger

  @profile "chatgpt"
  @plan_scope "chatgpt.tokens.use.direct"
  @auth_mode "oauth_siwc"
  # The statuses a token manager writes on a grant that can no longer renew.
  # A ChatGPT refresh writes only the first; a reader honours both.
  @quarantined ["reauthorization_required", "client_rejected"]

  @type state :: :not_connected | :connected | :plan_off | :reconnect

  @doc "The auth profile the registration lives under."
  @spec profile() :: String.t()
  def profile, do: @profile

  @doc "The scope whose grant lets Fermix use the person's ChatGPT plan."
  @spec plan_scope() :: String.t()
  def plan_scope, do: @plan_scope

  @doc "The stored registration, or `nil` when this home has none."
  @spec read(Path.t()) :: {:ok, Store.entry() | nil} | {:error, term()}
  def read(path) when is_binary(path) do
    case Store.read_registration(@profile, path) do
      {:ok, entry} -> {:ok, entry}
      {:error, :no_auth_file} -> {:ok, nil}
      {:error, {:provider_missing, _profile}} -> {:ok, nil}
      {:error, _reason} = error -> error
    end
  end

  @doc "Where a registration stands, for a setup surface and a route."
  @spec state(Store.entry() | nil) :: state()
  def state(nil), do: :not_connected

  def state(%{} = entry) do
    cond do
      not signed_in?(entry) -> :not_connected
      entry.status in @quarantined -> :reconnect
      plan_usage?(entry) -> :connected
      true -> :plan_off
    end
  end

  @doc "Whether the entry holds a token set."
  @spec signed_in?(Store.entry()) :: boolean()
  def signed_in?(%{tokens: %{access_token: token}}) when is_binary(token) and token != "",
    do: true

  def signed_in?(%{}), do: false

  @doc "Whether the grant includes ChatGPT plan usage."
  @spec plan_usage?(Store.entry()) :: boolean()
  def plan_usage?(%{} = entry), do: @plan_scope in (Map.get(entry, :granted_scopes) || [])

  @doc """
  Whether the next sign-in asks for consent again (D6): only when a finished
  sign-in was granted everything but plan usage. A first registration, or one
  whose exchange never finished, shows consent anyway.
  """
  @spec consent_needed?(Store.entry() | nil) :: boolean()
  def consent_needed?(nil), do: false
  def consent_needed?(%{} = entry), do: is_binary(entry.subject) and not plan_usage?(entry)

  @doc "A client issued before its exchange: kept so a retry registers no second app."
  @spec pending(String.t()) :: Store.entry()
  def pending(client_id) when is_binary(client_id) do
    %{
      auth_mode: @auth_mode,
      provider: @profile,
      client_id: client_id,
      tokens: %{access_token: nil, refresh_token: nil},
      expires_at: nil,
      earliest_refresh_at: nil,
      last_refresh: nil,
      status: "pending"
    }
  end

  @doc "A verified sign-in."
  @spec signed_in(String.t(), map(), map(), [String.t()], DateTime.t() | nil) :: Store.entry()
  def signed_in(client_id, %{"sub" => subject} = claims, tokens, scopes, earliest)
      when is_binary(client_id) and is_binary(subject) and is_list(scopes) do
    %{
      auth_mode: @auth_mode,
      provider: @profile,
      client_id: client_id,
      subject: subject,
      account: account(claims["email"]),
      granted_scopes: scopes,
      tokens: %{access_token: tokens.access_token, refresh_token: tokens.refresh_token},
      expires_at: tokens.expires_at,
      earliest_refresh_at: earliest,
      last_refresh: DateTime.utc_now(),
      status: "ready"
    }
  end

  @doc "The entry once signed out: no tokens, the registration kept."
  @spec signed_out(Store.entry()) :: Store.entry()
  def signed_out(%{} = entry) do
    %{
      entry
      | tokens: %{access_token: nil, refresh_token: nil},
        expires_at: nil,
        status: "signed_out"
    }
    |> Map.put(:earliest_refresh_at, nil)
  end

  @doc """
  Reads a token response's `earliest_refresh_at`. Its format is undocumented:
  Unix seconds and ISO-8601 are both accepted, and which one arrived is logged.
  Anything else is an `:invalid_token_response`.
  """
  @spec earliest_refresh_at(term()) ::
          {:ok, DateTime.t() | nil} | {:error, :invalid_token_response}
  def earliest_refresh_at(nil), do: {:ok, nil}

  def earliest_refresh_at(seconds) when is_number(seconds) and seconds >= 0 do
    Logger.info("ChatGPT: earliest_refresh_at arrived as Unix seconds")

    case DateTime.from_unix(trunc(seconds)) do
      {:ok, at} -> {:ok, at}
      {:error, _reason} -> unreadable_earliest()
    end
  end

  def earliest_refresh_at(text) when is_binary(text) do
    Logger.info("ChatGPT: earliest_refresh_at arrived as ISO-8601")

    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> {:ok, at}
      {:error, _reason} -> unreadable_earliest()
    end
  end

  def earliest_refresh_at(_other), do: unreadable_earliest()

  defp unreadable_earliest do
    Logger.warning("ChatGPT: invalid_token_response (unreadable earliest_refresh_at)")
    {:error, :invalid_token_response}
  end

  defp account(email) when is_binary(email) and email != "", do: %{email: email}
  defp account(_email), do: nil
end
