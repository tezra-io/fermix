defmodule FermixCore.Harness.Vendors do
  @moduledoc """
  Network-free detection of the coding-harness vendor CLIs (design §7.3, §8.3).

  For each vendor this resolves the binary (absolute, via `PATH`), probes its
  version with a bounded subprocess, and reads a network-free auth state from the
  operator's own CLI config — never a network call, never a keychain read:

    * **codex** — `~/.codex/auth.json` (or `Config.codex_home`) must carry a
      non-empty refresh token (`Auth.CodexImport.codex_available?/1`).
    * **claude** — `~/.claude` (or `Config.claude_config_dir`): a
      `.credentials.json` file means authenticated; the dir alone means
      `:unverified` (macOS stores credentials in the keychain, which is not read
      here — the honest "installed; auth unverified" state); neither means
      `:absent`.

  The result is a boot snapshot consumed by the seeder (which vendors register)
  and doctor (current binary/auth/version). Tests inject `:find_executable`,
  `:supervised`, and the config-dir overrides to stay hermetic.
  """

  alias FermixCore.Auth.CodexImport
  alias FermixCore.CommandRunner
  alias FermixCore.Harness.Config

  @vendors ~w(codex claude)
  @version_timeout_ms 5_000

  @type auth_state :: :authenticated | :unverified | :absent

  @type detection :: %{
          vendor: String.t(),
          binary: String.t() | nil,
          available?: boolean(),
          version: String.t() | nil,
          auth: auth_state()
        }

  @doc "The supported vendor tags."
  @spec vendors() :: [String.t()]
  def vendors, do: @vendors

  @doc "Detects every vendor, keyed by tag."
  @spec detect_all(keyword()) :: %{optional(String.t()) => detection()}
  def detect_all(opts \\ []) when is_list(opts) do
    Map.new(@vendors, fn vendor -> {vendor, detect(vendor, opts)} end)
  end

  @doc "Whether the vendor CLI binary is present on `PATH`."
  @spec available?(String.t(), keyword()) :: boolean()
  def available?(vendor, opts \\ []) when is_binary(vendor) and is_list(opts) do
    find_executable(opts).(cli(vendor)) not in [nil, false]
  end

  @doc """
  Whether `vendor`'s run tool should be *advertised* this turn, given the
  configured `default_vendor` selection and boot vendor detection.

  Advertise `vendor` iff it is the only installed option (the other vendor's CLI
  is not detected), OR it is the configured `default_vendor`, OR no default is
  set (an unselected default leaves both advertised, preserving flexibility). So
  the setup selection actually routes visibility: with both CLIs installed and
  `default_vendor = "codex"`, only `codex_run` is advertised.

  This is visibility only — an un-advertised vendor's tool stays dispatchable by
  name (the execute-time authorization gate is unchanged), and the harness prompt
  section names both tools so the model can still reach the other on request.

  Detection reads the same seam the seeder used at boot (`available?/1`, a `PATH`
  lookup — never a `--version` subprocess), so advertisement rides the boot
  snapshot rather than re-probing. Any failure resolving detection fails OPEN
  (both advertised) so `advertise?/1` can never crash.
  """
  @spec advertise_vendor?(String.t()) :: boolean()
  def advertise_vendor?(vendor) when vendor in @vendors do
    gate_by_default(vendor, Config.default_vendor())
  rescue
    _error -> true
  end

  defp gate_by_default(_vendor, nil), do: true
  defp gate_by_default(vendor, default) when default == vendor, do: true
  defp gate_by_default(vendor, _default), do: not other_available?(vendor)

  defp other_available?("codex"), do: detected_available?("claude")
  defp other_available?("claude"), do: detected_available?("codex")

  # Detection prefers the `:harness_vendor_detector` seam (the same static stub
  # `config/test.exs` installs so `mix test` never spawns a CLI probe); production
  # leaves it unset and falls back to the boot-cheap `available?/1` PATH lookup.
  defp detected_available?(vendor) do
    case Application.get_env(:fermix_core, :harness_vendor_detector) do
      fun when is_function(fun, 0) -> snapshot_available?(fun.(), vendor)
      _unset -> available?(vendor)
    end
  end

  defp snapshot_available?(detections, vendor) do
    case Map.get(detections, vendor) do
      %{available?: available?} -> available?
      _absent -> false
    end
  end

  @doc """
  Resolves the vendor CLI to an absolute path at call time — no version probe,
  no auth read (unlike `detect/2`), so it is safe on a hot path.

  A miss is `{:error, :cli_unavailable}`. Tests inject `:find_executable`.
  """
  @spec binary(String.t(), keyword()) :: {:ok, String.t()} | {:error, :cli_unavailable}
  def binary(vendor, opts \\ []) when vendor in @vendors and is_list(opts) do
    case find_executable(opts).(cli(vendor)) do
      path when is_binary(path) and path != "" -> {:ok, path}
      _absent -> {:error, :cli_unavailable}
    end
  end

  @doc "Detects one vendor: binary, availability, version, and network-free auth state."
  @spec detect(String.t(), keyword()) :: detection()
  def detect(vendor, opts \\ []) when vendor in @vendors and is_list(opts) do
    binary =
      case find_executable(opts).(cli(vendor)) do
        path when is_binary(path) and path != "" -> path
        _absent -> nil
      end

    %{
      vendor: vendor,
      binary: binary,
      available?: not is_nil(binary),
      version: version(binary, opts),
      auth: auth_state(vendor, opts)
    }
  end

  defp cli("codex"), do: "codex"
  defp cli("claude"), do: "claude"

  defp version(nil, _opts), do: nil

  defp version(binary, opts) do
    supervised = Keyword.get(opts, :supervised, true)
    timeout = Keyword.get(opts, :version_timeout_ms, @version_timeout_ms)

    case CommandRunner.run(binary, ["--version"], timeout_ms: timeout, supervised: supervised) do
      {:ok, %{exit: 0, stdout: out}} -> first_line(out)
      _probe_failed -> nil
    end
  end

  defp first_line(out) do
    case out |> String.split("\n", trim: true) |> List.first() do
      line when is_binary(line) -> String.trim(line)
      _empty -> nil
    end
  end

  defp auth_state("codex", opts) do
    auth_path = Path.join(codex_home(opts), "auth.json")

    if CodexImport.codex_available?(auth_path), do: :authenticated, else: :absent
  end

  defp auth_state("claude", opts) do
    dir = claude_config_dir(opts)

    cond do
      File.regular?(Path.join(dir, ".credentials.json")) -> :authenticated
      File.dir?(dir) -> :unverified
      true -> :absent
    end
  end

  defp codex_home(opts) do
    Keyword.get(opts, :codex_home) || Config.codex_home() || Path.join(home(), ".codex")
  end

  defp claude_config_dir(opts) do
    Keyword.get(opts, :claude_config_dir) || Config.claude_config_dir() ||
      Path.join(home(), ".claude")
  end

  defp home, do: System.user_home!()

  defp find_executable(opts), do: Keyword.get(opts, :find_executable, &System.find_executable/1)
end
