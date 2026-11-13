defmodule Fermix.CLI.ComputerCommand do
  @moduledoc """
  `fermix computer join` (M97 §3.1): this computer joins a Fermix that
  already runs, with the code Add a computer opened there.

  The code is read from stdin, never from argv, where every process on this
  computer can read it while the verb runs: on a terminal it is asked for
  with echo off, and from a pipe or a file it is the first line
  (`Fermix.CLI.SecretInput.read_answer/2`). The verb takes no argument, and
  a code given as one is a usage error naming this form.

  A join is part of Always On, so where this build offers none in the home
  (`Home.AlwaysOnRelease.available_in/1`, read from the home's own settings
  file) it refuses in that one sentence before anything else is read.

  It runs with no engine tree, against a stopped Fermix: the engine that
  owns this home would otherwise keep running as its own home. The code is
  asked for only once both of those hold. It joins through
  `FermixCore.Home.Join.start/3`: refused by name when this computer has a
  home of its own, when the code is not a computer's or expired, and when
  the secret store cannot keep this computer's key (each secret store call
  runs inline, with no command host to own it). Nothing is left behind by a
  refusal. Once it is done, the next start of Fermix here dials the server,
  shows six digits and waits until the owner adds this computer there by
  typing them.

  Exit status: `0` done, `1` refused (one sentence on stderr), `2` usage
  error.
  """

  alias Fermix.CLI.SecretInput
  alias FermixCore.Home.AlwaysOnRelease
  alias FermixCore.Home.DaemonProbe
  alias FermixCore.Home.Join
  alias FermixCore.Setup.ConfigStore

  @usage """
  Usage:
    fermix computer join    Asks for the code Add a computer opened, or reads it piped in
  """
  @code_label "Code from Add a computer"
  @running_sentence "Fermix is running here. Join from the Fermix app, or stop Fermix and run " <>
                      "this again."
  @argument_sentence "the code is not taken on the command line, where other programs here " <>
                       "can read it. Run fermix computer join and paste the code when it asks, " <>
                       "or pipe it in."
  @no_code_sentence "No code was read. Paste the code from Add a computer when this asks for " <>
                      "it, or pipe it in."

  @doc "Runs `fermix computer` with the real home and daemon probe."
  @spec run([String.t()]) :: non_neg_integer()
  def run(argv) when is_list(argv), do: run(argv, [])

  @doc """
  Runs `fermix computer` with injected dependencies: `:home`, `:hello` (the
  daemon probe, `DaemonProbe.stopped/2`'s seam), `:now` (a `DateTime`),
  `:key_opts` (handed to `ComputerKey`, beside `supervised: false`),
  `:always_on` (a boolean standing for the answer of
  `Home.AlwaysOnRelease.available_in/1` for the home), and `:terminal` and
  `:device` (handed to `SecretInput`, which reads the code).
  """
  @spec run([String.t()], keyword()) :: non_neg_integer()
  def run(argv, deps) when is_list(argv) and is_list(deps) do
    case argv do
      ["join"] -> join(deps)
      ["join" | _code] -> usage(@argument_sentence)
      _other -> usage()
    end
  end

  defp join(deps) do
    home = Keyword.get_lazy(deps, :home, &ConfigStore.fermix_home/0)

    with :ok <- offered(home, deps),
         :ok <- stopped(home, deps),
         {:ok, code} <- read_code(deps),
         :ok <- Join.start(home, code, join_opts(deps)) do
      {:ok, state} = Join.read(home)
      joined(state["server"]["name"])
    else
      {:error, :always_on_unavailable} ->
        refused(AlwaysOnRelease.sentence())

      {:error, {:code_unread, :no_input}} ->
        refused(@no_code_sentence)

      # The reason never holds what was read: `SecretInput` keeps the value
      # out of every error it answers.
      {:error, {:code_unread, reason}} ->
        refused("The code could not be read (#{inspect(reason)}).")

      {:error, {:config, _path, _reason} = unread} ->
        refused(AlwaysOnRelease.unreadable_sentence(unread))

      {:error, :daemon_running} ->
        refused(@running_sentence)

      {:error, {:daemon_probe_failed, _reason}} ->
        refused(@running_sentence)

      {:error, reason} ->
        refused(Join.error_sentence(reason))
    end
  end

  # Whether this build offers Always On in the home, of which a join is part.
  defp offered(home, deps) do
    case Keyword.get_lazy(deps, :always_on, fn -> AlwaysOnRelease.available_in(home) end) do
      available? when available? in [true, {:ok, true}] -> :ok
      unavailable when unavailable in [false, {:ok, false}] -> {:error, :always_on_unavailable}
      {:error, {:config, _path, _reason}} = error -> error
    end
  end

  defp stopped(home, deps), do: DaemonProbe.stopped(home, Keyword.take(deps, [:hello]))

  # Masked on a terminal, the first line of a pipe or a file.
  defp read_code(deps) do
    case SecretInput.read_answer(@code_label, Keyword.take(deps, [:terminal, :device])) do
      {:ok, code} -> {:ok, code}
      {:error, reason} -> {:error, {:code_unread, reason}}
    end
  end

  # No engine runs to restart: the next start of Fermix carries the join on.
  defp join_opts(deps) do
    key_opts = [supervised: false] ++ Keyword.get(deps, :key_opts, [])
    now = Keyword.get_lazy(deps, :now, &DateTime.utc_now/0)
    [key_opts: key_opts, now: now, restart: fn -> :ok end]
  end

  defp joined(server) do
    IO.puts(
      "This computer joins your Fermix on #{server} when Fermix starts here. It then shows " <>
        "six digits: type them on #{server} to add it."
    )

    0
  end

  defp refused(sentence) do
    IO.puts(:stderr, "fermix computer join: " <> sentence)
    1
  end

  defp usage do
    IO.puts(:stderr, @usage)
    2
  end

  defp usage(sentence) do
    IO.puts(:stderr, "fermix computer join: " <> sentence)
    usage()
  end
end
