defmodule Fermix.CLI.DeviceCommand do
  @moduledoc """
  `fermix device grants` (M75 §11): on a desktop whose home moved to a server,
  the folders the server may read on this computer, and removing one, over the
  running engine's `daemon.sock`.

      fermix device grants [--json]
      fermix device grants remove PATH [--json]

  `grants` lists them (`device.grants.list`): each folder the owner approved
  on a card on the server, and when. `grants remove` removes one
  (`device.grants.remove`), and the server's next read there is refused.
  PATH is expanded against `~` and this directory, so a folder is named as it
  is typed here. Removing is the owner's decision: the engine refuses it to a
  process it started.

  Each needs Fermix running (`engine_stopped` otherwise). `--json` prints the
  management result unchanged (`priv/cli/CONTRACT.md`); without it a few lines
  on stdout and a refusal one sentence on stderr. Exit status: `0` done, `1`
  refused, `2` usage error.
  """

  alias Fermix.CLI.Daemon.Client
  alias Fermix.CLI.MachineOutput
  alias FermixCore.Setup.ConfigStore

  @json [json: :boolean]
  @call_timeout_ms 10_000
  @usage """
  Usage:
    fermix device grants [--json]
    fermix device grants remove PATH [--json]
  """

  @doc """
  Runs `fermix device ARGS`. `deps`: `:home`, `:client` (a 3-arity management
  call, as `Client.request_v1/3`).
  """
  @spec run([String.t()], keyword()) :: non_neg_integer()
  def run(argv, deps \\ []) when is_list(argv) and is_list(deps) do
    case OptionParser.parse(argv, strict: @json) do
      {opts, ["grants"], []} ->
        call(json?(opts), deps, "device.grants.list", %{}, &list_lines/1)

      {opts, ["grants", "remove", path], []} when path != "" ->
        params = %{"path" => Path.expand(path)}
        call(json?(opts), deps, "device.grants.remove", params, &removed_lines/1)

      _invalid ->
        usage()
    end
  end

  defp call(json?, deps, method, params, lines) do
    home = Path.expand(Keyword.get_lazy(deps, :home, &ConfigStore.fermix_home/0))
    client = Keyword.get(deps, :client, &Client.request_v1/3)
    opts = [socket_path: Path.join(home, "daemon.sock"), timeout: @call_timeout_ms]

    case client.(method, params, opts) do
      {:ok, result} -> report(json?, result, lines)
      {:error, :not_running} -> refuse(json?, :engine_stopped, [])
      {:error, {:management_error, _code, message, details}} -> refused(json?, message, details)
      {:error, reason} -> refuse(json?, :grants_refused, output: Client.describe_error(reason))
    end
  end

  # The engine's own sentence, when it gave one, is what the owner reads.
  defp refused(json?, message, details) do
    said =
      case details do
        %{"sentence" => sentence} when is_binary(sentence) -> sentence
        _none -> message
      end

    refuse(json?, :grants_refused, output: said)
  end

  defp report(true, result, _lines) do
    IO.puts(MachineOutput.ok(result))
    0
  end

  defp report(false, result, lines) do
    Enum.each(lines.(result), &IO.puts/1)
    0
  end

  defp refuse(true, code, details) do
    IO.puts(MachineOutput.error(code, details))
    1
  end

  defp refuse(false, code, details) do
    IO.puts(:stderr, "fermix device: " <> MachineOutput.sentence(code, details))
    1
  end

  defp list_lines(%{"grants" => grants, "sentence" => sentence}),
    do: [sentence | Enum.map(grants, &"  #{&1["path"]} (since #{&1["granted_at"]})")]

  defp removed_lines(%{"removed" => removed, "sentence" => sentence}),
    do: ["Removed #{removed}.", sentence]

  defp json?(opts), do: Keyword.get(opts, :json, false)

  defp usage do
    IO.puts(:stderr, @usage)
    2
  end
end
