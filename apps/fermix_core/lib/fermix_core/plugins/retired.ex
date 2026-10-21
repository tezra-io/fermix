defmodule FermixCore.Plugins.Retired do
  @moduledoc """
  Plugin names this build no longer offers, and the one list that says so.

  Retiring a plugin used to be a catalog-time decision only. `RETIRED_PLUGINS`
  in `scripts/release/sync_plugin_catalog.py` stops the next catalog sync from
  pinning a name, so a FRESH install never sees it again — and nothing reached
  an install that already had it. There the plugin stayed in
  `[fermix_core.plugins] enabled`, kept its own section and its stored-key
  mapping, and its rail kept trying: a retired remote-MCP plugin whose upstream
  has moved on logs a discovery failure on every boot, forever, and that error
  reads as "this plugin is broken" when the truth is "this plugin is gone".

  So the name has to be known at runtime too, at the two places an install
  keeps a plugin. `FermixCore.Setup.ConfigStore` drops a retired plugin out of
  `enabled`, out of its `[fermix_core.plugins.<name>]` section and out of its
  `[fermix_core.plugin_secrets]` entry as the config is read, naming it at
  warning. `FermixCore.Plugins.Registry` leaves it out of the plugin store as
  the store is read, so its manifest is never loaded and a remote one's
  signature is never checked again: a verifier that stops accepting an old
  certificate once took the whole registry down with it, and boot with the
  registry. Dropping it at those two boundaries is what makes the rest hold:
  every reader downstream — the MCP source that starts the rail, the registry's
  skill dirs, status, the management surface, `fermix plugins`, doctor —
  resolves from config and a registry it never entered, so none of them needs a
  filter of its own, and the next save renders the file without it. (A
  `dev_local` checkout is the plugin author's own directory and is read as it
  is: a retired name there loads, and stays off because config drops it.)

  Nothing stored is touched: not the credential, and not the installed files
  (`fermix plugins installed` still lists them, and `fermix plugins uninstall`
  still removes them). Deleting either is the operator's decision and an
  irreversible one, so the warning names the plugin instead and leaves revoking
  it at the source to them.

  This list and the release script's `RETIRED_PLUGINS` are the same set, pinned
  by a test: the script decides what a new install is offered, this decides
  what an old one keeps running, and a name in one but not the other is how an
  install ends up in exactly the state this module exists to end.
  """

  @names ~w(eden)

  @doc "Every plugin name this build has retired."
  @spec names() :: [String.t()]
  def names, do: @names

  @doc "Whether this build has retired `name`."
  @spec retired?(String.t()) :: boolean()
  def retired?(name) when is_binary(name), do: name in @names
end
