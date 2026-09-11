defmodule FermixCore.Auth.ClientRejection do
  @moduledoc """
  One diagnosis with one owner: the OAuth provider refused the client (id and
  secret) this home saved for it.

  The refusal reads like a request Fermix built wrong. X answers a present but
  rejected Basic credential with 401 `unauthorized_client`, "Missing valid
  authorization header", when the real cause is a secret regenerated in X's
  console, or saved to a different home. Signing in again under the same client
  is refused the same way, and restarting changes nothing: only the operator's
  saved copy of the client can fix it. So the refusal is classified here, once,
  and every surface that meets it (the sign-in exchange, a refresh, the setup
  page, the macOS app, the CLI and a tool call) words it from this module.

  Which vendor codes mean "the client was refused" is provider data, declared as
  `client_rejection_errors` on each `OAuthProvider`. The built-in providers
  declare none, so nothing here changes how they fail. Classification keys on
  the decoded body's `error` string whatever the HTTP status, because GitHub and
  Slack answer the refusal with a 200.

  The typed reason is `{:oauth_client_rejected, detail}`. `detail` carries the
  vendor's own words (its code and a redacted, bounded description) for the
  daemon log and the trace; the sentences a person reads are `sentence/1` and
  `grant_sentence/1`.
  """

  alias FermixCore.Auth.OAuthProvider
  alias FermixCore.Auth.OAuthProviders
  alias FermixCore.Auth.Redaction

  # A vendor description is diagnostic text, not a document: long enough for a
  # sentence, short enough that a log line or a trace field stays one line.
  @description_limit 200

  @type detail :: %{
          provider: String.t(),
          provider_name: String.t(),
          status: non_neg_integer(),
          error: String.t(),
          description: String.t() | nil
        }

  @type reason :: {:oauth_client_rejected, detail()}

  @doc """
  The refusal `provider` answered at its token endpoint, or `nil` when the
  response is anything else (a body that is not a decoded map, or an `error`
  the provider does not declare as a refused client).
  """
  @spec classify(OAuthProvider.t(), non_neg_integer(), term()) :: reason() | nil
  def classify(%OAuthProvider{} = provider, status, body)
      when is_integer(status) and status >= 0 do
    case body do
      %{"error" => error} when is_binary(error) -> declared(provider, status, error, body)
      _not_a_refusal -> nil
    end
  end

  @doc """
  What a person reads when a sign-in or a refresh was refused: who refused it
  and the one fix. Surface-neutral, because the CLI prints it too.
  """
  @spec sentence(detail()) :: String.t()
  def sentence(%{provider_name: name}) when is_binary(name) do
    "#{name} refused the sign-in client saved in Fermix. Copy the client ID and secret " <>
      "from the #{name} developer console into the #{name} sign-in client in Fermix setup, " <>
      "then sign in again."
  end

  @doc """
  The status sentence for a stored grant quarantined because `provider` refused
  its client: the sign-in could not renew. `provider` is the plugin provider id
  ("x", "google").
  """
  @spec grant_sentence(String.t()) :: String.t()
  def grant_sentence(provider) when is_binary(provider) do
    "#{OAuthProviders.display_name(provider)} refused the saved sign-in client, " <>
      "so the sign-in could not renew."
  end

  @doc """
  The vendor's own words, for the daemon log: the status, the code and, when the
  vendor gave one, its description.
  """
  @spec vendor_words(detail()) :: String.t()
  def vendor_words(%{provider_name: name, status: status, error: error} = detail) do
    answered = "#{name} answered HTTP #{status} #{error}"

    case detail.description do
      nil -> answered
      description -> "#{answered}: #{description}"
    end
  end

  defp declared(provider, status, error, body) do
    if error in provider.client_rejection_errors,
      do: {:oauth_client_rejected, detail(provider, status, error, body)},
      else: nil
  end

  # A provider that declares refusals is a plugin provider, and a plugin
  # provider always carries its name: a nameless one fails here, loud, rather
  # than later inside a sentence.
  defp detail(%OAuthProvider{id: id, display_name: name}, status, error, body)
       when is_atom(id) and is_binary(name) do
    %{
      provider: Atom.to_string(id),
      provider_name: name,
      status: status,
      error: error,
      description: description(Map.get(body, "error_description"))
    }
  end

  defp description(text) when is_binary(text) do
    text |> Redaction.redact() |> String.slice(0, @description_limit)
  end

  defp description(_absent_or_not_text), do: nil
end
