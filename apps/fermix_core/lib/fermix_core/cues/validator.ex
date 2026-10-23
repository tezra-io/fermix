defmodule FermixCore.Cues.Validator do
  @moduledoc """
  Runs the owner's validator for one mandate call (M60 §10.2). Fermix runs it,
  never the model, and only cue runs reach it.

  The program runs through `CommandRunner.run/3`: the validator's absolute path,
  or `<interpreter> -I <validator>` when an interpreter is set (so no user
  site-packages or `PYTHONPATH` module loads); a replaced environment holding
  only `PATH=/usr/bin:/bin`, the daemon's `LANG` and the mandate's
  `validator_env` names, resolved as `[sandbox.env]` names are (a launchd or
  systemd daemon never sees shell exports, so a name's `[sandbox.env.<NAME>]`
  source is read, without the name having to be on the shell's allow list);
  five seconds; and the request as one line of JSON on standard input, which
  is then closed. Its standard error is discarded (`CommandRunner`'s `stderr:
  :discard`), so a warning there never becomes the answer.

  The last line the program prints on standard output decides: `{"allow":
  true}`, or `{"allow": false, "reason": "…"}`. Earlier lines are logged and
  never parsed. Any other last line, a non-zero exit, a timeout or a program
  that cannot start is a refusal with Fermix's sentence. The caller runs one
  call at a time, in the order the agent loop runs them.

  Seams (opts): `:command_runner` (`CommandRunner.run/3`'s shape),
  `:env_resolver` (`fn names -> {:ok, [{name, value}]} | {:error, reason}`).
  """

  require Logger

  alias FermixCore.CommandRunner
  alias FermixCore.Sandbox.Config, as: SandboxConfig
  alias FermixCore.Sandbox.Env

  @timeout_ms 5_000
  @path "/usr/bin:/bin"
  @max_output_bytes 65_536
  @max_reason_chars 300
  @max_logged_lines 20
  @max_logged_chars 300

  @type request :: %{required(String.t()) => term()}
  @type decision :: :allow | {:refuse, String.t()}

  @doc "Runs `mandate`'s validator on `request` (the design's JSON object)."
  @spec run(map(), request(), keyword()) :: decision()
  def run(%{name: name, validator: validator} = mandate, request, opts \\ [])
      when is_binary(name) and is_binary(validator) and is_map(request) and is_list(opts) do
    {executable, args} = command(mandate)

    with {:ok, env} <- environment(mandate, opts),
         {:ok, line} <- Jason.encode(request) do
      runner = Keyword.get(opts, :command_runner, &CommandRunner.run/3)

      executable
      |> runner.(args,
        input: line <> "\n",
        stderr: :discard,
        env: env,
        env_mode: :replace,
        timeout_ms: @timeout_ms,
        max_output_bytes: @max_output_bytes
      )
      |> decide(name)
    else
      {:error, reason} ->
        refuse(name, "the validator could not be started: #{reason_text(reason)}")
    end
  end

  @doc "How long a validator may run, in milliseconds."
  @spec timeout_ms() :: pos_integer()
  def timeout_ms, do: @timeout_ms

  defp command(%{interpreter: nil, validator: validator}), do: {validator, []}

  defp command(%{interpreter: interpreter, validator: validator}),
    do: {interpreter, ["-I", validator]}

  defp environment(mandate, opts) do
    resolver = Keyword.get(opts, :env_resolver, &resolve_names/1)

    with {:ok, named} <- resolver.(mandate.validator_env) do
      {:ok, [{"PATH", @path} | lang()] ++ named}
    end
  end

  defp lang do
    case System.get_env("LANG") do
      nil -> []
      value -> [{"LANG", value}]
    end
  end

  # The names' own `[sandbox.env.<NAME>]` sources, read as requirements: the
  # allow list is emptied, so nothing else is resolved and nothing else passes.
  defp resolve_names([]), do: {:ok, []}

  defp resolve_names(names) do
    config = SandboxConfig.current()
    config = %{config | env: %{config.env | allow: []}}

    with {:ok, %{env: env}} <- Env.build(config, names) do
      picked = Enum.filter(env, fn {name, _value} -> name in names end)
      missing = names -- Enum.map(picked, &elem(&1, 0))
      if missing == [], do: {:ok, picked}, else: {:error, {:missing_env, hd(missing)}}
    end
  end

  # --- the answer ----------------------------------------------------------------------

  defp decide({:ok, %{truncated?: true}}, name),
    do: refuse(name, "the validator printed more than Fermix reads")

  defp decide({:ok, %{exit: 0, stdout: out}}, name) do
    {earlier, last} = split_last(out)
    log_earlier(name, earlier)
    answer(last, name)
  end

  defp decide({:ok, %{exit: code}}, name),
    do: refuse(name, "the validator stopped with exit status #{code}")

  defp decide({:error, {:timeout, _ms}}, name),
    do: refuse(name, "the validator did not answer within #{div(@timeout_ms, 1_000)} seconds")

  defp decide({:error, reason}, name),
    do: refuse(name, "the validator could not run: #{reason_text(reason)}")

  defp split_last(out) do
    lines = String.split(out, ["\r\n", "\n"], trim: true)

    case Enum.split(lines, -1) do
      {earlier, [last]} -> {earlier, last}
      {[], []} -> {[], nil}
    end
  end

  defp answer(nil, name), do: refuse(name, "the validator printed no answer")

  defp answer(line, name) do
    case Jason.decode(line) do
      {:ok, %{"allow" => true}} ->
        :allow

      {:ok, %{"allow" => false, "reason" => reason}} when is_binary(reason) and reason != "" ->
        {:refuse, bounded(reason)}

      {:ok, %{"allow" => false}} ->
        {:refuse, "the validator refused it"}

      _other ->
        refuse(name, "the validator's answer was not understood")
    end
  end

  defp refuse(name, sentence) do
    Logger.warning("Mandate #{name} validator: #{sentence}")
    {:refuse, sentence}
  end

  defp log_earlier(_name, []), do: :ok

  defp log_earlier(name, lines) do
    lines
    |> Enum.take(-@max_logged_lines)
    |> Enum.each(&Logger.info("Mandate #{name} validator said: #{bounded_log(&1)}"))
  end

  defp bounded(text) do
    if String.length(text) > @max_reason_chars,
      do: String.slice(text, 0, @max_reason_chars) <> "…",
      else: text
  end

  defp bounded_log(text) do
    if String.length(text) > @max_logged_chars,
      do: String.slice(text, 0, @max_logged_chars) <> "…",
      else: text
  end

  defp reason_text({:missing_env, name}), do: "#{name} could not be read"
  defp reason_text({:executable_not_found, path}), do: "#{path} does not exist"
  defp reason_text(%Jason.EncodeError{message: message}), do: message
  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: Env.format_error(reason)
end
