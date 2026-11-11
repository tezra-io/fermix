defmodule FermixCore.Computers.Offer do
  @moduledoc """
  One thing a computer may offer its server (M97 §3.2): what it is, in the
  owner's words, which systems can have it, and whether this computer offers
  it now, from its switches (`Computers.Switches`) and the facts of the
  machine (`Computers.Facts`).

  Each offer is one module, so the session that builds its capability flips
  its state in one place. `Computers.Offers.compute/3` asks each module of a
  list, in order; the computer's offers reporter
  (`FermixChannels.Desktop.Offers`) holds that list, the core offers here and
  the ones whose device end lives beside the link.

  A state is `{:on, detail}` (a short word or nil, such as the sandbox mode
  of the shell), `{:on, detail, helper}` for an offer that also says what its
  helper offers (`computer_use`'s actions and input methods, M97 §6.4),
  `{:off, sentence}` (switched off on this computer, or never switched on) or
  `{:unavailable, sentence}` (it cannot work here, in the engine's words).
  Every sentence obeys `Management.Copy`'s rules.
  """

  alias FermixCore.Computers.Facts
  alias FermixCore.Computers.Switches

  @typedoc "An offer's state on this computer."
  @type state ::
          {:on, String.t() | nil}
          | {:on, String.t() | nil, %{actions: [String.t()], input_methods: [String.t()]}}
          | {:off | :unavailable, String.t()}

  @doc "The offer's id, one of `Switches.offers/0`."
  @callback id() :: Switches.offer()

  @doc ~s(What the offer is, in the owner's words: "commands", "the browser", "your screen".)
  @callback label() :: String.t()

  @doc "The systems that can have it."
  @callback systems() :: [:macos | :linux]

  @doc "Whether this computer offers it now."
  @callback state(Switches.t(), Facts.t()) :: state()
end
