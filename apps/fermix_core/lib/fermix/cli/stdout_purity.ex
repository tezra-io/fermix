defmodule Fermix.CLI.StdoutPurity do
  @moduledoc """
  Moves the VM's default logger handler off stdout, for the verbs whose stdout
  is a wire.

  Two surfaces need this and must not each have their own copy of it. `fermix
  acp` speaks JSON-RPC on stdout, where one stray byte desynchronizes the
  client's framing. Every `--json` verb prints one schema-versioned envelope on
  stdout and nothing else (M38 §4.6), and a caller decodes that line without
  stripping anything first — so a logged warning lands *inside* what it decodes.

  The move has to happen before anything can log, which is earlier than any
  verb: `config/runtime.exs` is the boot config-provider chain, and the config
  hydration there logs (an unresolvable `@keyring` sentinel warns, a plaintext
  secret warns) while the only handler alive is the one the kernel installed on
  `:standard_io`. That is why this is called from the boot chain and not from a
  command module.

  `:logger_std_h` refuses an in-place `type` change (its `changing_config/3`
  answers `:illegal_config_change`), so the move is remove-then-add: same
  module, same formatter, stderr.

  The boot chain's move does not reach the verb in a release: the `logger`
  application starts after the config provider, removes the default handler
  and installs its own on stdout. So `Fermix.CLI.main/1`, which every verb
  passes through once `logger` runs, makes the move again before it
  dispatches. Both ask `wire_stdout?/1`, the one predicate for which argv
  needs it.
  """

  # The verbs whose stdout is a wire whatever their flags: `acp` speaks
  # JSON-RPC there, and the `browser-bridge` pump's stdout is the
  # native-messaging wire, where one stray boot warning is read as a length
  # header that is not one.
  @wire_verbs ~w(acp browser-bridge)

  @type failure :: {:unmovable_handler, module()} | {:add_handler_failed, term()}

  @doc """
  Whether `argv`'s stdout is a wire: its verb (the first argument, as
  `Fermix.CLI.main/1` reads it) is one, or it asks for `--json` anywhere.
  Asking for machine output is the declaration that stdout is a wire, so the
  flag is the predicate rather than a second list of verbs to keep in step
  with the dispatcher.
  """
  @spec wire_stdout?([String.t()]) :: boolean()
  def wire_stdout?(argv) when is_list(argv) do
    case argv do
      [verb | _rest] when verb in @wire_verbs -> true
      _other -> "--json" in argv
    end
  end

  @doc "Routes the default logger handler to stderr, or says why it could not."
  @spec route_logs_to_stderr() :: :ok | {:error, failure()}
  def route_logs_to_stderr do
    case :logger.get_handler_config(:default) do
      # A handler that writes to stdout is the one and only purity problem.
      {:ok, %{module: :logger_std_h, config: %{type: :standard_io}} = config} ->
        redirect_default_handler(config)

      # Already stderr, or a file handler: the guarantee holds, leave it alone.
      {:ok, %{module: :logger_std_h}} ->
        :ok

      # No default handler at all (`mix test`, a release that removed it):
      # nothing writes to stdout, which is the whole guarantee.
      {:error, {:not_found, :default}} ->
        :ok

      {:ok, %{module: module}} ->
        {:error, {:unmovable_handler, module}}
    end
  end

  @doc """
  The operator sentence for a failed move.

  One wording for both surfaces: the fault is the same and the consequence —
  bytes on stdout that the reader did not ask for — is the same, so the call
  site adds what it is about to do and nothing else.
  """
  @spec message(failure()) :: String.t()
  def message({:unmovable_handler, module}) do
    "the default logger handler is #{inspect(module)}, which Fermix cannot move off " <>
      "stdout, and a wire on stdout must carry nothing else"
  end

  def message({:add_handler_failed, reason}) do
    "could not move Fermix logging off stdout (#{inspect(reason)})"
  end

  defp redirect_default_handler(config) do
    {module, rest} = Map.pop!(config, :module)
    handler_config = rest |> Map.get(:config, %{}) |> Map.put(:type, :standard_error)
    _ = :logger.remove_handler(:default)

    case :logger.add_handler(:default, module, Map.put(rest, :config, handler_config)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:add_handler_failed, reason}}
    end
  end
end
