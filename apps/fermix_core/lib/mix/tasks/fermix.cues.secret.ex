defmodule Mix.Tasks.Fermix.Cues.Secret do
  @shortdoc "Stores one cue source secret (token, key or secret) for the current FERMIX_HOME"

  @moduledoc """
  Stores the value of one secret field of a cue source (M60 §6.2), before the
  app has a Cues section:

      mix fermix.cues.secret <source_ref> <token|key|secret>

  The source must already be in `[fermix_core.cues.sources.<ref>]` with the
  field set to `"@keyring"` or `"@file"`; the value is written to that store
  under `cue_source:<ref>:<field>`, for the profile the home's config names.
  The value is read from stdin, never from argv: on a terminal with echo off,
  from a pipe as its first line.

  It reads the current `FERMIX_HOME`'s config without resolving any other
  secret and starts no daemon tree, so it touches nothing but that one item. A
  running daemon reads the new value within a minute.
  """

  use Mix.Task

  alias Fermix.CLI.SecretInput
  alias FermixCore.Cues.Config, as: CuesConfig
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.SecretWriter

  @fields %{"token" => :token, "key" => :key, "secret" => :secret}
  @usage "usage: mix fermix.cues.secret <source_ref> <token|key|secret>"

  @impl Mix.Task
  def run(args) do
    # Compiled code only: `app.config` would run `runtime.exs`, which resolves
    # every secret the home holds, and nothing here needs them.
    Mix.Task.run("compile")
    execute(args)
  end

  @doc false
  @spec execute([String.t()], keyword()) :: :ok
  def execute(args, input_opts \\ []) when is_list(args) and is_list(input_opts) do
    {ref, field} = parse_args!(args)
    {store, profile} = destination!(ref, field)
    value = read_value!(ref, field, input_opts)

    case SecretWriter.put({:cue_source, ref, field}, value,
           store: store,
           profile: profile,
           supervised: false
         ) do
      :ok ->
        Mix.shell().info("Stored cue_source:#{ref}:#{field} in the #{store} store.")

      {:error, reason} ->
        Mix.raise("cue_source:#{ref}:#{field} was not stored: #{inspect(reason)}")
    end
  end

  defp parse_args!([ref, field_name]) do
    field = Map.get(@fields, field_name) || Mix.raise(@usage)

    if CuesConfig.valid_name?(ref) do
      {ref, field}
    else
      Mix.raise("#{inspect(ref)} is not a source name. #{@usage}")
    end
  end

  defp parse_args!(_args), do: Mix.raise(@usage)

  # The store is the one the source's own sentinel names, so the daemon reads
  # the value where it is written.
  defp destination!(ref, field) do
    snapshot =
      case ConfigStore.load_runtime_config(resolve_secrets: false, supervised: false) do
        {:ok, snapshot} ->
          snapshot

        {:error, reason} ->
          Mix.raise("config.toml could not be read: #{ConfigStore.load_error_sentence(reason)}")
      end

    cues = Keyword.get(snapshot.fermix_core, :cues, [])
    profile = Keyword.get(snapshot.fermix_core, :profile)

    case CuesConfig.source(ref, cues) do
      {:ok, %{secrets: %{^field => store}}} ->
        {store, profile}

      {:ok, _source} ->
        Mix.raise(
          "Source #{ref} has no #{field} field. Add #{field} = \"@keyring\" to " <>
            "[fermix_core.cues.sources.#{ref}] in #{ConfigStore.path()} first."
        )

      :error ->
        Mix.raise("There is no source #{ref} in #{ConfigStore.path()}.")
    end
  end

  defp read_value!(ref, field, input_opts) do
    case SecretInput.read_answer("cue_source:#{ref}:#{field}", input_opts) do
      {:ok, ""} -> Mix.raise("No value was entered; nothing was stored.")
      {:ok, value} -> value
      {:error, reason} -> Mix.raise("The value could not be read: #{inspect(reason)}")
    end
  end
end
