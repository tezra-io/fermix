defmodule Fermix.CLI.ComputerCommand do
  @moduledoc """
  `fermix computer join` (M97 §3.1, M102 J2): this computer joins a Fermix
  that already runs, with the code Add a computer opened there.

  The code is read from stdin, never from argv, where every process on this
  computer can read it while the verb runs: on a terminal it is asked for
  with echo off, and from a pipe or a file it is the first line
  (`Fermix.CLI.SecretInput.read_answer/2`). The verb takes no argument, and
  a code given as one is a usage error naming this form.

  It joins as the apps do, through the running Fermix (D4): it says `hello`
  to this home's control socket, asks for the code only once Fermix answered,
  and sends it as `computer.join.start`, the one join path
  (`FermixCore.Management.ComputerLink`, `FermixCore.Home.Join.start/3`).
  With Fermix stopped it refuses, reading no code: a computer its server
  removed while Fermix was stopped learns it only once its Fermix runs and
  dials the server. Every refusal of the join is the engine's own sentence:
  a home of its own, a code that is not a computer's or expired, a link its
  relay has not taken to the server yet, a secret store that cannot keep
  this computer's key. Once the join started, Fermix restarts here, dials
  the server and shows six digits, which the owner types in Always On on a
  computer already in the home.

  Exit status: `0` the join started, `1` refused (one sentence on stderr),
  `2` usage error.
  """

  alias Fermix.CLI.Daemon.Client
  alias Fermix.CLI.SecretInput
  alias FermixCore.Setup.ConfigStore

  @usage """
  Usage:
    fermix computer join    Asks for the code Add a computer opened, or reads it piped in
  """
  @code_label "Code from Add a computer"
  # `hello` answers at once; the join writes a key and restarts nothing
  # before it answers, so a slow secret store has this long.
  @hello_ms 10_000
  @join_ms 60_000
  @joining_sentence "This computer is joining your Fermix. Once Fermix restarts here, " <>
                      "fermix home status shows six digits: type them in Always On on a " <>
                      "computer already in your Fermix."
  @stopped_sentence "Fermix is not running here. Start it, then run this again."
  @argument_sentence "the code is not taken on the command line, where other programs here " <>
                       "can read it. Run fermix computer join and paste the code when it asks, " <>
                       "or pipe it in."
  @no_code_sentence "No code was read. Paste the code from Add a computer when this asks for " <>
                      "it, or pipe it in."

  @doc "Runs `fermix computer` with the real home and control socket."
  @spec run([String.t()]) :: non_neg_integer()
  def run(argv) when is_list(argv), do: run(argv, [])

  @doc """
  Runs `fermix computer` with injected dependencies: `:home`, `:client` (a
  3-arity management call, as `Client.request_v1/3`), and `:terminal` and
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
    client = Keyword.get(deps, :client, &Client.request_v1/3)
    socket = Path.join(home, "daemon.sock")

    with :ok <- running(client, socket),
         {:ok, code} <- read_code(deps),
         {:ok, _joining} <- start(client, socket, code) do
      IO.puts(@joining_sentence)
      0
    else
      {:error, {:code_unread, :no_input}} ->
        refused(@no_code_sentence)

      # The reason never holds what was read: `SecretInput` keeps the value
      # out of every error it answers.
      {:error, {:code_unread, reason}} ->
        refused("The code could not be read (#{inspect(reason)}).")

      {:error, :not_running} ->
        refused(@stopped_sentence)

      {:error, reason} ->
        refused(said(reason))
    end
  end

  # Before any code is read: with no Fermix to join through, there is nothing
  # to read it for.
  defp running(client, socket) do
    case client.("hello", %{}, socket_path: socket, timeout: @hello_ms) do
      {:ok, _hello} -> :ok
      {:error, _reason} = error -> error
    end
  end

  # Masked on a terminal, the first line of a pipe or a file.
  defp read_code(deps) do
    case SecretInput.read_answer(@code_label, Keyword.take(deps, [:terminal, :device])) do
      {:ok, code} -> {:ok, code}
      {:error, reason} -> {:error, {:code_unread, reason}}
    end
  end

  defp start(client, socket, code),
    do: client.("computer.join.start", %{"code" => code}, socket_path: socket, timeout: @join_ms)

  # The engine's own sentence for a refusal; a transport failure in the
  # client's words.
  defp said({:management_error, _code, _message, %{"sentence" => sentence}})
       when is_binary(sentence),
       do: sentence

  defp said({:management_error, _code, message, _details}) when is_binary(message), do: message
  defp said(reason), do: Client.describe_error(reason) <> "."

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
