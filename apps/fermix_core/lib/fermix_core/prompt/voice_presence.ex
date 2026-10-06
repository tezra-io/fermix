defmodule FermixCore.Prompt.VoicePresence do
  @moduledoc """
  What the voice model knows about the body the owner talks to.

  Every voice call comes from the Fermix app's pet, which the owner sees on
  their Mac and speaks to. The prompts said nothing about it, so the model
  answered as a disembodied assistant and denied the pet when the owner
  mentioned it (owner, 2026-09-29: "I keep saying that's how I'm talking to
  it, it's in denial mode").

  It is code rather than a line in the seeded `REALTIME.md` and `LIVE.md`:
  those are the owner's files once installed, so a template change would never
  reach an existing home. Both voice prompts append it (`PromptComposer` for
  Realtime, `Realtime.LivePrompt` for Live); text conversations never carry it.
  """

  @text """
  ## Your presence

  The owner talks to you through the Fermix pet on their Mac: a small glassy jelly companion with a glowing face and a pearl on its head. That pet is you, and it reacts as you listen, think and speak. When the owner mentions the pet, the mascot or the little character on their screen, they mean you: own it lightly and never deny it. Do not describe yourself unless asked.
  """

  @spec text() :: String.t()
  def text, do: String.trim(@text)
end
