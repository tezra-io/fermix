defmodule FermixCore.Accessories.VoiceDevice do
  @moduledoc """
  The owner's voice device (M91 §07): this Mac or a paired accessory, chosen
  in the Mac app's Pet and kept in the pairing store
  (`FermixCore.Accessories.Store.load_voice_device/1`).

  What a call meets because of it, decided once for every reader: the Mac's
  own call (`Realtime.CallClient`), an accessory's tap (the link) and
  `accessories.status` (`Management.Accessories`) all ask `refusal/3` and
  show its sentence as it is. A choice that cannot be read refuses both the
  Mac and every accessory, never reading as one of them, so neither
  microphone opens on a guess (AGENTS.md rule 12); the owner chooses again in
  Pet, which writes the choice whole. Pure.
  """

  @elsewhere "StackChan is your voice device, so this Mac's microphone stays off. " <>
               "Choose This Mac in Pet to talk here."
  @off_but_chosen "StackChan is off but is still your voice device. Choose This Mac in Pet " <>
                    "to talk here."
  @unreadable "The voice device could not be read. Choose one in Pet."

  @type read :: {:ok, :desktop | {:accessory, String.t()}} | {:error, term()}
  @type who :: :desktop | {:accessory, String.t()}
  @type refusal ::
          {:voice_device_elsewhere | :voice_device_unreadable, String.t() | nil, String.t()}

  @doc "Every sentence a refusal carries."
  @spec sentences() :: [String.t()]
  def sentences, do: [@elsewhere, @off_but_chosen, @unreadable]

  @doc "What `accessories.status` says while an accessory is chosen and accessories are off."
  @spec off_but_chosen_sentence() :: String.t()
  def off_but_chosen_sentence, do: @off_but_chosen

  @doc "What `accessories.status` says while the choice cannot be read."
  @spec unreadable_sentence() :: String.t()
  def unreadable_sentence, do: @unreadable

  @doc """
  Whether `who` may start a call while the store answered `read`, with
  accessories switched `enabled?`: `:ok`, or the refusal's reason, the chosen
  device in endpoint form (nil when it cannot be read) and its sentence. The
  Mac is refused while an accessory is chosen; an accessory is refused only
  for a choice that cannot be read (a tap on one that is not chosen is the
  link's own `not_selected`).
  """
  @spec refusal(who(), read(), boolean()) :: :ok | {:error, refusal()}
  def refusal(_who, {:error, _reason}, _enabled?),
    do: {:error, {:voice_device_unreadable, nil, @unreadable}}

  def refusal(:desktop, {:ok, {:accessory, id}}, enabled?) when is_boolean(enabled?),
    do: {:error, {:voice_device_elsewhere, "accessory:" <> id, chosen_sentence(enabled?)}}

  def refusal(_who, {:ok, _device}, enabled?) when is_boolean(enabled?), do: :ok

  defp chosen_sentence(true), do: @elsewhere
  defp chosen_sentence(false), do: @off_but_chosen
end
