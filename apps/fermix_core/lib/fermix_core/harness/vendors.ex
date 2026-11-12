defmodule FermixCore.Harness.Vendors do
  @moduledoc """
  Network-free detection of the coding-harness vendor CLIs (design §7.3, §8.3).

  For each vendor this resolves the binary (absolute, via `PATH`), probes its
  version with a bounded subprocess, and reads a network-free auth state from the
  operator's own CLI config — never a network call, never a keychain read:

    * **codex** — `~/.codex/auth.json` (or `Config.codex_home`) must carry a
      sign-in in a form Codex writes: a non-empty ChatGPT refresh token
      (`codex_chatgpt_signed_in?/1`), or a non-empty API key (`codex login
      --with-api-key`). The value is only tested for being there.
    * **claude** — `~/.claude` (or `Config.claude_config_dir`): a
      `.credentials.json` file means authenticated; the dir alone means
      `:unverified` (macOS stores credentials in the keychain, which is not read
      here — the honest "sign-in not verified" state); neither means
      `:absent`.

  The result is a boot snapshot consumed by the seeder (which vendors register)
  and doctor (current binary/auth/version). Tests inject `:find_executable`,
  `:supervised`, and the config-dir overrides to stay hermetic.
  """

  alias FermixCore.CommandRunner
  alias FermixCore.Harness.Config
  alias FermixCore.Harness.Identity

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

  defp other_available?("codex"), do: detected?("claude")
  defp other_available?("claude"), do: detected?("codex")

  @doc """
  Whether `vendor`'s CLI is found, the way the run tools' advertisement and the
  coding store (`Harness.MachineStore`) ask: the `:harness_vendor_detector` seam
  where it is set (the static stub `config/test.exs` installs so `mix test`
  never spawns a CLI probe), else the boot-cheap `available?/1` PATH lookup.
  """
  @spec detected?(String.t()) :: boolean()
  def detected?(vendor) when vendor in @vendors do
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

  @doc """
  Whether a Codex CLI sign-in file carries a non-empty ChatGPT refresh token:
  a ChatGPT sign-in, which onboarding can adopt as a provider (an API-key
  sign-in cannot be). Never refreshes, never reads past the file.
  """
  @spec codex_chatgpt_signed_in?(Path.t()) :: boolean()
  def codex_chatgpt_signed_in?(auth_path) when is_binary(auth_path),
    do: codex_sign_in(auth_path) == :chatgpt

  # The form of the sign-in a Codex `auth.json` holds, each value only tested
  # for being there: ChatGPT tokens, an API key, or none.
  defp codex_sign_in(auth_path) do
    with {:ok, raw} <- File.read(auth_path),
         {:ok, %{} = auth} <- Jason.decode(raw) do
      codex_sign_in_form(auth)
    else
      _absent_or_unreadable -> :none
    end
  end

  defp codex_sign_in_form(%{"tokens" => %{"refresh_token" => token}})
       when is_binary(token) and token != "",
       do: :chatgpt

  defp codex_sign_in_form(%{"OPENAI_API_KEY" => key}) when is_binary(key) and key != "",
    do: :api_key

  defp codex_sign_in_form(_auth), do: :none

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

  @doc """
  The vendor's network-free sign-in state, read from its own config dir: file
  reads only, never a subprocess, a network call or the keychain, so it is safe
  where `detect/2`'s version probe is not (a watcher follow-up's readiness).
  Tests inject `:codex_home` and `:claude_config_dir`.
  """
  @spec auth_state(String.t(), keyword()) :: auth_state()
  def auth_state("codex", opts) when is_list(opts) do
    case codex_sign_in(Path.join(codex_home(opts), "auth.json")) do
      :none -> :absent
      _chatgpt_or_api_key -> :authenticated
    end
  end

  def auth_state("claude", opts) when is_list(opts) do
    dir = claude_config_dir(opts)

    cond do
      File.regular?(Path.join(dir, ".credentials.json")) -> :authenticated
      File.dir?(dir) -> :unverified
      true -> :absent
    end
  end

  @doc """
  The file `vendor` keeps its sign-in in, where it is there: Codex's
  `auth.json`, Claude Code's `.credentials.json` (absent on a Mac, whose sign-in
  is in the Keychain, which Fermix never reads), else nil. The path is read the
  way `auth_state/2` reads it, and only its stat is ever compared
  (`Harness.SignIn`), never its contents. Tests inject `:codex_home` and
  `:claude_config_dir`.
  """
  @spec sign_in_file(String.t(), keyword()) :: Path.t() | nil
  def sign_in_file(vendor, opts) when vendor in @vendors and is_list(opts) do
    file =
      case vendor do
        "codex" -> Path.join(codex_home(opts), "auth.json")
        "claude" -> Path.join(claude_config_dir(opts), ".credentials.json")
      end

    if File.regular?(file), do: file
  end

  @doc """
  The models the signed-in Codex account offers, read from the list Codex itself
  caches in its config dir (`models_cache.json`, which Codex refreshes): a file
  read only. Each model is its `id` (what `-m` takes), the `name` Codex shows, and
  whether Codex lists it in its picker (`listed?`; a hidden one still runs). No
  file is `:no_codex_model_list`, since Codex writes it once it has listed the
  account's models; a file that cannot be read or decoded is its own refusal.
  Tests inject `:codex_home`.
  """
  @spec codex_models(keyword()) ::
          {:ok, [%{id: String.t(), name: String.t(), listed?: boolean()}]}
          | {:error, :no_codex_model_list | {:codex_model_list_unreadable, term()}}
  def codex_models(opts) when is_list(opts) do
    path = Path.join(codex_home(opts), "models_cache.json")

    with {:ok, body} <- read_model_list(path),
         {:ok, entries} <- decode_model_list(body) do
      collect_models(entries, [])
    end
  end

  defp read_model_list(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, :enoent} -> {:error, :no_codex_model_list}
      {:error, reason} -> {:error, {:codex_model_list_unreadable, reason}}
    end
  end

  defp decode_model_list(body) do
    case Jason.decode(body) do
      {:ok, %{"models" => entries}} when is_list(entries) -> {:ok, entries}
      {:ok, _other} -> {:error, {:codex_model_list_unreadable, :no_models_key}}
      {:error, error} -> {:error, {:codex_model_list_unreadable, Exception.message(error)}}
    end
  end

  # An entry with no id is a list Fermix does not understand, never one to skip.
  defp collect_models([], acc), do: {:ok, Enum.reverse(acc)}

  defp collect_models([%{"slug" => id} = entry | rest], acc) when is_binary(id) and id != "" do
    model = %{
      id: id,
      name: model_name(entry, id),
      listed?: Map.get(entry, "visibility") != "hide"
    }

    collect_models(rest, [model | acc])
  end

  defp collect_models([_entry | _rest], _acc),
    do: {:error, {:codex_model_list_unreadable, :entry_without_id}}

  defp model_name(%{"display_name" => name}, _id) when is_binary(name) and name != "", do: name
  defp model_name(_entry, id), do: id

  # Through `Harness.Identity` so detection probes the store a run will actually
  # use: an operator who exports `CODEX_HOME`/`CLAUDE_CONFIG_DIR` keeps credentials
  # somewhere Fermix's own config never names, and reporting on the default while
  # running against theirs is how readiness comes out green on a host that refuses.
  defp codex_home(opts) do
    Keyword.get(opts, :codex_home) || Identity.vendor_config_dir("codex") ||
      Path.join(home(), ".codex")
  end

  defp claude_config_dir(opts) do
    Keyword.get(opts, :claude_config_dir) || Identity.vendor_config_dir("claude") ||
      Path.join(home(), ".claude")
  end

  defp home, do: System.user_home!()

  defp find_executable(opts), do: Keyword.get(opts, :find_executable, &System.find_executable/1)
end
