defmodule FermixCore.Home.AlwaysOnRelease do
  @moduledoc """
  Whether this build of Fermix offers Always On at all. It is not in a
  release build yet: it stays off there until a home can move back to the
  computer it left, so a build compiled for `:prod` serves none of it, and a
  `:dev` or `:test` build serves all of it. The build's own environment
  decides, once, at compile time (`Mix.env/0`); no setting and no
  environment variable turns it on or off.

  Where it is off, the management wire's `hello` lists none of Always On's
  methods (`methods/0`) and the router refuses each by name (`refusal/1`),
  the setup page lists no Always On tab and takes no Always On event, and
  `fermix always-on` and `fermix home status` refuse with `sentence/0`
  before they read anything.
  Everything else of the home is as it was: snapshots and the recovery
  passphrase, the link of a desktop to its server, and a server's own
  `fermix home enroll`.

  This module and its callers are the whole gate: turning Always On on in a
  release build is deleting them.
  """

  @compiled_env Mix.env()
  @methods ~w(home.status home.act home.provision.options)
  @sentence "Always On is not in this release of Fermix yet."

  @doc "Whether this build offers Always On: `available?/1` of the env it was compiled in."
  @spec available?() :: boolean()
  def available?, do: available?(@compiled_env)

  @doc "Whether a build compiled for `env` offers Always On: not a `:prod` one."
  @spec available?(atom()) :: boolean()
  def available?(env) when is_atom(env), do: env != :prod

  @doc "The management methods that are Always On's, in the protocol's order."
  @spec methods() :: [String.t()]
  def methods, do: @methods

  @doc "The one sentence every surface refuses Always On with where it is off."
  @spec sentence() :: String.t()
  def sentence, do: @sentence

  @doc "The router's refusal of one of Always On's `methods/0` where it is off."
  @spec refusal(String.t()) :: {:error, :unavailable, map()}
  def refusal(method) when method in @methods,
    do:
      {:error, :unavailable,
       %{"capability" => "always_on", "method" => method, "sentence" => @sentence}}
end
