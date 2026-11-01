defmodule FermixCore.Home.Snapshot.Recovery do
  @moduledoc """
  What a typed recovery passphrase means against the recovery key a primary
  keeps in `[fermix_core.snapshots] recipient` (Always On setup §4): one rule,
  shared by the move and by setting the passphrase outside one.

    * `verify_or_set/2`, the move's (`Management.HomeMove.move_start/3`, which
      a local Move now and a forwarded `home.move.start` both reach): with a
      key kept, the passphrase is derived under that key's own salt and must
      give its public half, else `:wrong_passphrase`; with none kept, a new key
      is derived and kept, as `set/2` keeps it. Either way it answers the key
      the move carries, so a move never makes a second key for an unchanged
      passphrase, and a mistyped one never becomes the key the new primary's
      snapshots are encrypted to. On a replace it runs on the server, whose
      key it is.
    * `set/2`, `home.snapshots.passphrase`'s: a new key under a new salt,
      replacing the one kept; snapshots written before it open only with the
      earlier passphrase.

  Only the public half is written (`Snapshot.Settings.put_recipient/1`). The
  passphrase lives only inside these calls: it is never stored, logged,
  answered or put in an error term.

  `opts`: `:config` (the snapshots section; the application environment's
  unless said) and `:save_recipient` (in place of
  `Snapshot.Settings.put_recipient/1`).
  """

  alias FermixCore.Home.Snapshot.Config
  alias FermixCore.Home.Snapshot.Recipient
  alias FermixCore.Home.Snapshot.Settings

  @max_passphrase_bytes 1_024

  @typedoc """
  Why a passphrase gave no key: under the shortest a passphrase may be, not
  text of at most #{@max_passphrase_bytes} bytes, not the one set, a kept key
  that cannot be read, or a key the settings write did not keep (its reason).
  """
  @type error ::
          :passphrase_too_short
          | :passphrase_not_text
          | :wrong_passphrase
          | :key_unreadable
          | {:not_saved, term()}

  @doc """
  The key kept for `passphrase`: the kept one when the passphrase derives it,
  else `:wrong_passphrase`; a new one, kept now, when none is kept.
  """
  @spec verify_or_set(term(), keyword()) :: {:ok, Recipient.t()} | {:error, error()}
  def verify_or_set(passphrase, opts \\ []) do
    # Asserted in the body, never in a guard: a refused guard prints every
    # argument, the passphrase among them.
    true = is_list(opts)

    with {:ok, passphrase} <- bounded(passphrase) do
      case Config.recipient(config(opts)) do
        {:ok, kept} -> verify(passphrase, kept)
        :absent -> keep_new(passphrase, opts)
        {:error, :invalid_recipient} -> {:error, :key_unreadable}
      end
    end
  end

  @doc "A new key for `passphrase` under a new salt, kept in place of any kept one."
  @spec set(term(), keyword()) :: {:ok, Recipient.t()} | {:error, error()}
  def set(passphrase, opts \\ []) do
    true = is_list(opts)

    with {:ok, passphrase} <- bounded(passphrase), do: keep_new(passphrase, opts)
  end

  @doc "The sentence the owner reads for a refusal of `verify_or_set/2` or `set/2`."
  @spec error_sentence(error()) :: String.t()
  def error_sentence(:passphrase_too_short),
    do: "The recovery passphrase must be at least #{Recipient.min_passphrase_bytes()} bytes long."

  def error_sentence(:passphrase_not_text),
    do: "The recovery passphrase is text of at most #{@max_passphrase_bytes} bytes."

  def error_sentence(:wrong_passphrase), do: "That is not the recovery passphrase you set."

  def error_sentence(:key_unreadable),
    do:
      "The recovery key Fermix keeps cannot be read. Set the recovery passphrase again, " <>
        "which writes a new one."

  def error_sentence({:not_saved, _reason}),
    do: "The recovery key could not be saved. See the daemon log."

  defp bounded(value) when is_binary(value) and byte_size(value) > @max_passphrase_bytes,
    do: {:error, :passphrase_not_text}

  defp bounded(value) when is_binary(value) do
    if byte_size(value) >= Recipient.min_passphrase_bytes(),
      do: {:ok, value},
      else: {:error, :passphrase_too_short}
  end

  defp bounded(_value), do: {:error, :passphrase_not_text}

  # The bound is checked first, so the derivation cannot refuse it.
  defp verify(passphrase, kept) do
    {:ok, pair} = Recipient.derive(passphrase, kept.salt)
    if Recipient.matches?(pair, kept), do: {:ok, kept}, else: {:error, :wrong_passphrase}
  end

  defp keep_new(passphrase, opts) do
    {:ok, pair} = Recipient.from_passphrase(passphrase)
    recipient = Recipient.public(pair)

    case save_recipient(opts).(recipient) do
      {:ok, _saved} -> {:ok, recipient}
      {:error, reason} -> {:error, {:not_saved, reason}}
    end
  end

  defp save_recipient(opts), do: Keyword.get(opts, :save_recipient, &Settings.put_recipient/1)

  defp config(opts),
    do:
      Keyword.get_lazy(opts, :config, fn -> Application.get_env(:fermix_core, :snapshots, []) end)
end
