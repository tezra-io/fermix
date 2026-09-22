defmodule FermixCore.Setup.SecretService.Probe do
  @moduledoc """
  Whether the Secret Service (the Linux keyring API) can be used from this
  process right now, without touching a secret (M38 §7.2).

  Three read-only questions over `busctl --user`, each bounded, in order:

    1. Does anything own `org.freedesktop.secrets` on the session bus? Asked of
       the bus itself, so a keyring daemon that is merely activatable is not
       started by the asking.
    2. Which collection is the default? (`ReadAlias default`; `/` means none.)
    3. Is that collection locked? (its `Locked` property.)

  `secret-tool` would answer the same questions by trying, and trying on a
  locked collection raises the desktop's unlock dialog, which a background
  daemon must never do. `available` still lets the real read or write fail
  and report itself; `unknown` means the probe could not establish the state
  and carries what it saw, so an operation goes ahead rather than a working
  keyring on an unusual host being refused by a probe.
  """

  alias FermixCore.CommandRunner

  @service "org.freedesktop.secrets"
  @service_path "/org/freedesktop/secrets"
  @bus_timeout_s "1"
  @call_timeout_ms 1_500
  @evidence_bytes 200
  @collection_path ~r"^/[A-Za-z0-9_/]*$"

  # What busctl says, verbatim, when there is no session bus to ask: no
  # address at all (a shell reached with `su`, some SSH logins), or an address
  # with nothing listening behind it.
  @no_bus_marks [
    "Failed to set bus address",
    "Failed to connect to bus",
    "No such file or directory",
    "Connection refused",
    "not defined",
    "No medium found"
  ]

  @typep runner :: (String.t(), [String.t()] -> {:ok, String.t()} | {:error, term()})

  @doc """
  The verdict for this process. `opts[:runner]` and `opts[:find_executable]`
  are test seams; `opts[:supervised]` reaches `CommandRunner` unchanged.
  """
  @spec run(keyword()) :: FermixCore.Setup.SecretWriter.verdict()
  def run(opts \\ []) when is_list(opts) do
    find = Keyword.get(opts, :find_executable, &System.find_executable/1)

    case find.("busctl") do
      nil -> verdict(:unknown, "busctl is not installed, so the keyring's state was not checked")
      busctl -> ask(busctl, runner(opts))
    end
  end

  defp ask(busctl, runner) do
    with {:ok, true} <- name_has_owner(busctl, runner),
         {:ok, collection} <- default_collection(busctl, runner) do
      locked(busctl, runner, collection)
    else
      {:ok, false} ->
        verdict(
          :service_absent,
          "no keyring service (Secret Service) is running on this session bus"
        )

      {:verdict, verdict} ->
        verdict
    end
  end

  defp name_has_owner(busctl, runner) do
    args =
      call_args([
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "NameHasOwner",
        "s",
        @service
      ])

    case runner.(busctl, args) do
      {:ok, output} -> parse_bool(output, "NameHasOwner")
      {:error, reason} -> {:verdict, bus_failure(reason)}
    end
  end

  defp default_collection(busctl, runner) do
    args =
      call_args([
        @service,
        @service_path,
        "org.freedesktop.Secret.Service",
        "ReadAlias",
        "s",
        "default"
      ])

    case runner.(busctl, args) do
      {:ok, output} -> parse_collection(output)
      {:error, reason} -> {:verdict, unknown("ReadAlias", reason)}
    end
  end

  defp locked(busctl, runner, collection) do
    args = [
      "--user",
      "--timeout=#{@bus_timeout_s}",
      "get-property",
      @service,
      collection,
      "org.freedesktop.Secret.Collection",
      "Locked"
    ]

    case runner.(busctl, args) do
      {:ok, output} ->
        case parse_bool(output, "Locked") do
          {:ok, true} ->
            verdict(
              :locked,
              "the login keyring is locked. Unlock it in Passwords and Keys, or log in with " <>
                "your password once; fingerprint and automatic login leave it locked"
            )

          {:ok, false} ->
            verdict(:available, "the keyring is unlocked and answers")

          {:verdict, verdict} ->
            verdict
        end

      {:error, reason} ->
        unknown("Locked", reason)
    end
  end

  defp call_args(rest), do: ["--user", "--timeout=#{@bus_timeout_s}", "call" | rest]

  # busctl prints a typed value: `b true`, `o "/org/freedesktop/secrets/collection/login"`.
  defp parse_bool(output, what) do
    case String.trim(output) do
      "b true" -> {:ok, true}
      "b false" -> {:ok, false}
      other -> {:verdict, unknown(what, {:unexpected_output, other})}
    end
  end

  defp parse_collection(output) do
    case Regex.run(~r/^o "([^"]*)"$/, String.trim(output)) do
      [_, "/"] ->
        {:verdict,
         verdict(
           :collection_unavailable,
           "the keyring has no default collection; create one in Passwords and Keys"
         )}

      [_, path] ->
        if Regex.match?(@collection_path, path),
          do: {:ok, path},
          else: {:verdict, unknown("ReadAlias", {:unexpected_output, path})}

      nil ->
        {:verdict, unknown("ReadAlias", {:unexpected_output, output})}
    end
  end

  # A bus that cannot be reached is its own state; everything else the first
  # call can fail with is unknown, with the evidence.
  defp bus_failure({:helper_failed, _code, output} = reason) do
    if String.contains?(output, @no_bus_marks) do
      verdict(
        :no_session_bus,
        "no session bus is reachable from this process, so the keyring cannot be reached; " <>
          "log in to this machine's desktop session, or run Fermix from a login session"
      )
    else
      unknown("NameHasOwner", reason)
    end
  end

  defp bus_failure(reason), do: unknown("NameHasOwner", reason)

  defp unknown(what, reason) do
    verdict(
      :unknown,
      "the keyring's state could not be checked (#{what})",
      evidence(reason)
    )
  end

  defp evidence({:helper_failed, code, output}), do: "exit #{code}: #{clip(output)}"
  defp evidence({:unexpected_output, output}), do: "unexpected output: #{clip(output)}"
  defp evidence(:timeout), do: "timed out after #{@call_timeout_ms}ms"
  defp evidence(other), do: clip(inspect(other))

  defp clip(text) do
    text
    |> to_string()
    |> String.trim()
    |> String.split("\n")
    |> List.first("")
    |> String.slice(0, @evidence_bytes)
  end

  defp verdict(state, sentence, evidence \\ nil) do
    base = %{store: :keyring, state: state, sentence: sentence}
    if evidence, do: Map.put(base, :evidence, evidence), else: base
  end

  # One bounded subprocess per question. The runner shape is what the test
  # seam provides; in production it is `CommandRunner.run/3` with the caller's
  # `supervised:` posture, and never anything that could prompt.
  @spec runner(keyword()) :: runner()
  defp runner(opts) do
    case Keyword.get(opts, :runner) do
      nil -> &run_bounded(&1, &2, Keyword.take(opts, [:supervised]))
      runner when is_function(runner, 2) -> runner
    end
  end

  defp run_bounded(busctl, args, supervised) do
    case CommandRunner.run(busctl, args, [timeout_ms: @call_timeout_ms] ++ supervised) do
      {:ok, %{exit: 0, stdout: output}} -> {:ok, output}
      {:ok, %{exit: code, stdout: output}} -> {:error, {:helper_failed, code, output}}
      {:error, {:timeout, _ms}} -> {:error, :timeout}
      {:error, reason} -> {:error, reason}
    end
  end
end
