defmodule FermixCore.Home.AlwaysOnRelease do
  @moduledoc """
  Whether this engine offers Always On at all. It is not in a release build
  yet: it stays off there until a home can move back to the computer it
  left, so a build compiled for `:prod` serves none of it unless its home
  turns it on for testing, in the home's settings file:

      [fermix_core.always_on]
      enabled = true

  A `:dev` or `:test` build serves all of it whatever the file says. The
  build's own environment decides first, once, at compile time
  (`Mix.env/0`), and within a `:prod` build that switch decides:
  `available?/2` is the one rule. No environment variable turns it on or
  off. The switch is for the owner's own tests of a real move; it is
  unsupported, and no surface offers it.

  One file, two readers of it. An engine asks `available?/0`, which reads
  the section from application environment: the boot puts it there from
  the home's `config.toml` (`ConfigStore.bootstrap_runtime_config/1`), as
  it does every section, and every settings save and reload from disk puts
  it there again. `hello` and every call read it as they arrive, and a
  client reads `hello` when it connects, so an edit by hand applies once
  Fermix restarts (a reload of the settings from disk applies it too, to
  the next connection). A process with no engine (`fermix always-on`,
  `fermix home status`) asks `available_in/1`, which reads the same section
  from that home's own `config.toml` (`ConfigStore.always_on_config/1`),
  with no tree. A section either reader cannot read is refused by name: it
  stops the engine's boot, as every section does, and the verbs answer with
  the file it is in.

  The switch is the home's, not the computer's, so it travels with it: no
  device-class section (`Candidate.Return.device_tables/0`) holds it, a
  move to a server carries it in the settings file activation writes last,
  and a move back brings the server's copy home. A candidate home is
  written with it on (`Home.Candidate`), since a candidate exists only for
  an Always On move and its server reads `fermix home status` while it
  waits; the move replaces that file with the home's own.

  Where it is off, the management wire's `hello` lists none of Always On's
  methods (`methods/0`) and the router refuses each by name (`refusal/1`),
  the setup page lists no Always On tab and takes no Always On event, and
  `fermix always-on` and `fermix home status` refuse with `sentence/0`
  before they read anything else.
  Everything else of the home is as it was: snapshots and the recovery
  passphrase, the link of a desktop to its server, and a server's own
  `fermix home enroll`.

  This module, its section and its callers are the whole gate: turning
  Always On on in a release build is deleting them.
  """

  alias FermixCore.Setup.ConfigStore

  @compiled_env Mix.env()
  @methods ~w(home.status home.act)
  @sentence "Always On is not in this release of Fermix yet."
  @section "[fermix_core.always_on]"

  @doc """
  Whether this engine offers Always On: `available?/2` of the env it was
  compiled in and the section in application environment.
  """
  @spec available?() :: boolean()
  def available?,
    do: available?(@compiled_env, Application.get_env(:fermix_core, :always_on, []))

  @doc """
  Whether a build compiled for `env` offers Always On, given its home's
  `[fermix_core.always_on]` section (`normalize/1`'s shape): any build but
  a `:prod` one, and a `:prod` one whose home turns it on.
  """
  @spec available?(atom(), keyword()) :: boolean()
  def available?(env, config) when is_atom(env) and is_list(config),
    do: env != :prod or Keyword.get(config, :enabled, false) == true

  @doc """
  Whether this build offers Always On in `home`, read from that home's own
  settings file with no engine running: `available_in/2` of the env it was
  compiled in.
  """
  @spec available_in(Path.t()) :: {:ok, boolean()} | {:error, {:config, Path.t(), term()}}
  def available_in(home) when is_binary(home) and home != "",
    do: available_in(home, @compiled_env)

  @doc """
  `available?/2` for a build compiled for `env`, with the section read from
  `home`'s `config.toml`: a home with no file reads as one with no section,
  and a file or section that cannot be read is `{:config, path, reason}`.
  """
  @spec available_in(Path.t(), atom()) ::
          {:ok, boolean()} | {:error, {:config, Path.t(), term()}}
  def available_in(home, env) when is_binary(home) and home != "" and is_atom(env) do
    with {:ok, config} <- ConfigStore.always_on_config(home),
         do: {:ok, available?(env, config)}
  end

  @doc """
  What a verb says of a section `available_in/1` could not read: its file,
  then why, in the loader's own words.
  """
  @spec unreadable_sentence({:config, Path.t(), term()}) :: String.t()
  def unreadable_sentence({:config, path, reason}) when is_binary(path) and is_binary(reason),
    do: "#{path}: #{reason}"

  def unreadable_sentence({:config, path, reason}) when is_binary(path),
    do: "#{path}: #{:file.format_error(reason)}"

  @doc """
  The section in the shape application environment holds: `[]` or
  `[enabled: boolean]`. Accepts the parsed file (string keys) and its own
  output; raises `ArgumentError` naming the key on anything else, which
  stops a load as every section's refusal does.
  """
  @spec normalize(keyword() | map() | nil) :: keyword()
  def normalize(nil), do: []
  def normalize(config) when is_map(config) or is_list(config), do: Enum.map(config, &entry!/1)

  def normalize(other),
    do: raise(ArgumentError, "config.toml #{@section} is not a table: #{inspect(other)}")

  @doc """
  The inverse of `normalize/1`, in the spellings `config.toml` holds: a
  boolean is already one.
  """
  @spec to_keyword(keyword() | map() | nil) :: keyword()
  def to_keyword(config) when is_list(config) or is_map(config) or is_nil(config),
    do: normalize(config)

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

  defp entry!({key, value}) when key in ["enabled", :enabled] and is_boolean(value),
    do: {:enabled, value}

  defp entry!({key, value}) when key in ["enabled", :enabled] do
    raise ArgumentError,
          "config.toml #{@section} enabled takes true or false, and #{inspect(value)} is " <>
            "not. Fix it and save again."
  end

  defp entry!({key, _value}) when is_binary(key) or is_atom(key) do
    raise ArgumentError,
          "config.toml #{@section} has unknown key(s): #{key}. Allowed keys: enabled. " <>
            "Remove or fix the key; the daemon will not boot until this is fixed."
  end

  defp entry!(other),
    do: raise(ArgumentError, "config.toml #{@section} is not a table: #{inspect(other)}")
end
