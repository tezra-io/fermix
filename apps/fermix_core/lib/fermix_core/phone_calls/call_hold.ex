defmodule FermixCore.PhoneCalls.CallHold do
  @moduledoc """
  What a phone call in progress holds (M94 §12), with one test of "in
  progress": a ledger row not yet ended (`call_in_progress/1`).

    * **Its credentials** (`check_credentials/2`). Before a credential is
      cleared or rotated, every active consumer is found, and the change is
      blocked rather than allowed to break one. Two registry secrets are
      held: the OpenAI Platform key (`:openai_api_key`, which the OpenAI
      provider and Talk to Fermix share) and the Telnyx connection's password
      (`:phone_calls_sip_password`). The call reads both at its dispatch, and
      its request to end reads the key. Every other secret, the SpaceXAI key
      among them, is never held. Enforced where every console's change of a
      registry secret is written, before anything is stored:
      `Setup.Wizard.put_secret/3` (`secret.set`), `Setup.Wizard.clear_secret/2`
      (`secret.clear`) and `Setup.Wizard.save_answers/3` (the setup page's
      forms).
    * **The owner's restart** (`check_restart/1`): `lifecycle.prepare_restart`,
      which `fermix restart` and the apps' restart to apply take, and the
      setup page's Restart. The engine's stop would end the call and read no
      outcome. A stop that is not the owner's restart (an update, a move, a
      disable, the service manager) is not asked here and drains as before.

  A call that has ended holds nothing, and neither does one only unresolved
  (ended here, its end at OpenAI unconfirmed): nothing of Fermix reads its
  credentials again, and holding them would stop the owner replacing a leaked
  password.

  The calls are the running engine's ledger (`opts[:repo]`, for a test). With
  durable memory off no call can run, so nothing is held. A process whose
  ledger does not run at all (a tree-less `fermix setup`) runs no call either,
  so it holds nothing: the daemon's own calls are not visible from there. Any
  other ledger error holds, because whether a call is in progress cannot be
  told.
  """

  alias FermixCore.Auth.Redaction
  alias FermixCore.Memory.Repo
  alias FermixCore.PhoneCalls.Ledger

  require Logger

  # How the owner stops a call, from every console: the apps and the setup
  # page have a Stop, and every chat can ask.
  @how_to_stop "Ask Fermix to stop the call, or let it end"
  @in_use_sentences %{
    openai_api_key:
      "A phone call is in progress and uses this key. #{@how_to_stop}, then change the key.",
    phone_calls_sip_password:
      "A phone call is in progress and uses this password. #{@how_to_stop}, then change " <>
        "the password."
  }
  @keys Map.keys(@in_use_sentences)
  @restart_sentence "A phone call is in progress, and restarting Fermix now would hang it up " <>
                      "without its outcome. #{@how_to_stop}, then restart."
  @unreadable_sentence "Fermix could not tell whether a phone call is in progress, so nothing " <>
                         "was changed. See the daemon log."

  @type refusal :: {:credential_held, atom(), String.t()} | {:restart_held, String.t()}

  @doc "The secrets a call in progress holds."
  @spec keys() :: [atom(), ...]
  def keys, do: @keys

  @doc """
  Whether a change of every secret in `keys` may be stored now: `:ok`, or the
  first held one's refusal with its sentence.
  """
  @spec check_credentials([atom()], keyword()) ::
          :ok | {:error, {:credential_held, atom(), String.t()}}
  def check_credentials(keys, opts \\ []) when is_list(keys) and is_list(opts) do
    case Enum.filter(keys, &(&1 in @keys)) do
      [] -> :ok
      [key | _rest] -> held(call_in_progress(opts), {:credential_held, key})
    end
  end

  @doc "Whether the owner's restart may run now: `:ok`, or the refusal with its sentence."
  @spec check_restart(keyword()) :: :ok | {:error, {:restart_held, String.t()}}
  def check_restart(opts \\ []) when is_list(opts),
    do: held(call_in_progress(opts), {:restart_held})

  @doc """
  The one test of "a phone call is in progress": a ledger row not yet ended.
  `{:error, reason}` when the ledger cannot be read.
  """
  @spec call_in_progress(keyword()) :: {:ok, boolean()} | {:error, term()}
  def call_in_progress(opts \\ []) when is_list(opts) do
    repo = Keyword.get(opts, :repo, Repo)

    if is_nil(GenServer.whereis(repo)),
      do: {:ok, false},
      else: unsettled(repo)
  end

  defp unsettled(repo) do
    case Ledger.unsettled(server: repo, on_timeout: :error) do
      {:ok, rows} -> {:ok, rows != []}
      {:error, :disabled} -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  end

  defp held({:ok, false}, _refusal), do: :ok
  defp held({:ok, true}, refusal), do: {:error, with_sentence(refusal, held_sentence(refusal))}

  defp held({:error, reason}, refusal) do
    Logger.error(
      "phone call hold: the call records could not be read, so #{what(refusal)} is held: " <>
        Redaction.format(reason)
    )

    {:error, with_sentence(refusal, @unreadable_sentence)}
  end

  defp held_sentence({:credential_held, key}), do: Map.fetch!(@in_use_sentences, key)
  defp held_sentence({:restart_held}), do: @restart_sentence

  defp with_sentence({:credential_held, key}, sentence), do: {:credential_held, key, sentence}
  defp with_sentence({:restart_held}, sentence), do: {:restart_held, sentence}

  defp what({:credential_held, key}), do: key
  defp what({:restart_held}), do: "the restart"

  @doc "Every sentence a refusal carries, for the copy gate."
  @spec sentences() :: [String.t(), ...]
  def sentences, do: Map.values(@in_use_sentences) ++ [@restart_sentence, @unreadable_sentence]
end
