defmodule FermixCore.Setup.LiveModel do
  @moduledoc """
  Gives a provider whose models are listed live a model it can run with.

  OpenAI Codex ships no catalog (M57 §6.2): the models a signed-in account may
  call come from the account's own listing, and its route refuses an empty
  `default_model` rather than guess a slug. After a sign-in, `ensure/2` reads
  that listing and, when the configured `default_model` is empty or is not one
  the account lists, persists the FIRST listed slug through the normal config
  save path (`Wizard.save_answers/2`, the one every settings write takes). A
  configured model the account lists is left exactly as it is.

  A listing that fails or comes back empty is refused with a sentence; nothing
  is guessed and nothing is written.
  """

  alias FermixCore.Auth.Redaction
  alias FermixCore.Providers.Descriptor
  alias FermixCore.Providers.ModelListing
  alias FermixCore.Setup.Wizard
  alias FermixCore.Setup.WizardState

  require Logger

  @type listing :: (atom(), keyword() -> {:ok, [ModelListing.live_model()]} | {:error, term()})
  @type result :: %{model: String.t(), changed?: boolean()}

  @doc """
  Makes sure `provider`'s configured `default_model` is one its live listing
  offers.

  Options:

    * `:listing` — `(provider, listing_opts) -> {:ok, models} | {:error, reason}`;
      defaults to `ModelListing.live_models/2`.
    * `:listing_opts` — passed to the listing (defaults to `[]`).
    * `:wizard` — the `WizardState` to read the configured block from and save
      through; defaults to `Wizard.report().wizard`, the state every settings
      write starts from.
  """
  @spec ensure(atom(), keyword()) :: {:ok, result()} | {:error, String.t()}
  def ensure(provider, opts \\ []) when is_atom(provider) and is_list(opts) do
    descriptor = Descriptor.fetch!(provider)
    listing = Keyword.get(opts, :listing, &ModelListing.live_models/2)

    with {:ok, slugs} <- listed_slugs(descriptor, listing, Keyword.get(opts, :listing_opts, [])) do
      state = Keyword.get_lazy(opts, :wizard, fn -> Wizard.report().wizard end)
      settle(descriptor, state, slugs)
    end
  end

  defp listed_slugs(descriptor, listing, listing_opts) when is_function(listing, 2) do
    case listing.(descriptor.id, listing_opts) do
      {:ok, [_first | _rest] = models} ->
        {:ok, Enum.map(models, & &1.id)}

      {:ok, []} ->
        {:error, "#{descriptor.label} is connected, but it listed no models for this account."}

      {:error, reason} ->
        {:error,
         "#{descriptor.label} is connected, but its models could not be listed: " <>
           reason_text(reason)}
    end
  end

  defp settle(descriptor, %WizardState{} = state, [first | _rest] = slugs) do
    configured = configured_model(state, descriptor.id)

    if configured in slugs do
      {:ok, %{model: configured, changed?: false}}
    else
      persist(descriptor, state, first)
    end
  end

  defp persist(descriptor, state, slug) do
    case Wizard.save_answers(state, edit_provider: descriptor.id, default_model: slug) do
      {:ok, _report} ->
        {:ok, %{model: slug, changed?: true}}

      {:error, reason} ->
        {:error,
         "#{descriptor.label} is connected, but its model was not saved: " <>
           save_sentence(descriptor, reason)}
    end
  end

  defp save_sentence(_descriptor, {:external_change, _sections}),
    do: "the settings file changed outside Fermix. Reload the settings and sign in again."

  defp save_sentence(_descriptor, {:config_unreadable, sentence}) when is_binary(sentence),
    do: sentence

  # Any other refusal is an internal term that can name files on the operator's
  # disk, so it goes to the daemon log and the sentence stays fixed.
  defp save_sentence(descriptor, reason) do
    Logger.error(
      "live model: #{descriptor.id} default_model could not be saved: " <>
        Redaction.format(reason)
    )

    "see the daemon log."
  end

  defp configured_model(%WizardState{config_snapshot: snapshot}, provider) do
    snapshot
    |> Map.get(:fermix_core, [])
    |> Keyword.get(:providers, [])
    |> Keyword.get(provider, [])
    |> Keyword.get(:default_model)
    |> case do
      model when is_binary(model) -> String.trim(model)
      _absent -> ""
    end
  end

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: inspect(reason)
end
