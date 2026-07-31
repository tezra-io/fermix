defmodule FermixCore.Harness.Env do
  @moduledoc """
  Builds the `env -i` argv that spawns a vendor CLI with a wiped, explicitly
  reconstructed environment.

  The daemon inherits secrets; the child must not. Ports `:env` entries only
  *overlay* the inherited environment, so the isolation is done the way
  `sandbox/command_tool.ex` already does it — the spawned executable is `env`
  itself and the vendor binary runs under a fresh environment:

      /usr/bin/env -i HOME=<home> PATH=<path> TERM=xterm-256color USER=<user> <abs-binary> <argv…>

  `HOME`, `PATH`, `TERM`, `USER` are reserved and supplied by the caller through
  the `:home`/`:path`/`:user` options (never from the `allowed_env` map). This
  module takes an already-resolved `allowed_env` map and enforces reservation +
  shape only — resolving permitted names through `Sandbox.Env` is the P1 adapter's
  job. No secret logic lives here.

  `USER` is process identity, not a secret: it names *who the child runs as*, the
  same way `HOME` names where its state lives. It is required because a vendor CLI
  can key its credential lookup on the account name — Claude Code on macOS reads
  its OAuth token from the Keychain item whose account is `$USER`, and with `USER`
  wiped it looks up the literal account `"unknown"`, finds nothing, and exits with
  "Not logged in · Please run /login". Passing it costs nothing (a uid already
  fixes the real privilege, and `HOME=/Users/<name>` already reveals the name) and
  omitting it silently un-authenticates every keychain-backed vendor.
  """

  @env_binary "/usr/bin/env"
  @reserved ~w(HOME PATH TERM USER)
  @term "xterm-256color"
  @env_name_regex ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/

  @type reason ::
          :relative_binary
          | {:reserved_env, String.t()}
          | {:invalid_env_name, String.t()}
          | {:missing_opt, :home | :path | :user}
          | {:env_binary_missing, String.t()}

  @type built :: %{executable: String.t(), args: [String.t()]}

  @type opt :: {:home, String.t()} | {:path, String.t()} | {:user, String.t()}

  @doc """
  Builds the `env -i` invocation for `vendor_binary` with `argv`.

  `vendor_binary` must be an absolute path (PATH is wiped before `env` resolves
  its target). `allowed_env` is a resolved `%{name => value}` map of extra
  assignments and must not contain a reserved name. `:home`, `:path` and `:user`
  are required; `TERM` is fixed. Extra assignments are sorted for a deterministic
  argv.
  """
  @spec build(String.t(), [String.t()], %{optional(String.t()) => String.t()}, [opt()]) ::
          {:ok, built()} | {:error, reason()}
  def build(vendor_binary, argv, allowed_env, opts \\ [])
      when is_binary(vendor_binary) and is_list(argv) and is_map(allowed_env) and is_list(opts) do
    with :ok <- ensure_absolute(vendor_binary),
         :ok <- ensure_valid_names(allowed_env),
         :ok <- ensure_no_reserved(allowed_env),
         {:ok, home} <- fetch_opt(opts, :home),
         {:ok, path} <- fetch_opt(opts, :path),
         {:ok, user} <- fetch_opt(opts, :user),
         :ok <- ensure_env_binary() do
      {:ok,
       %{
         executable: @env_binary,
         args: assemble(home, path, user, vendor_binary, argv, allowed_env)
       }}
    end
  end

  defp assemble(home, path, user, vendor_binary, argv, allowed_env) do
    extra =
      allowed_env
      |> Enum.map(fn {name, value} -> "#{name}=#{value}" end)
      |> Enum.sort()

    ["-i", "HOME=" <> home, "PATH=" <> path, "TERM=" <> @term, "USER=" <> user | extra] ++
      [vendor_binary | argv]
  end

  defp ensure_absolute("/" <> _rest), do: :ok
  defp ensure_absolute(_relative), do: {:error, :relative_binary}

  # A name carrying `=` (or otherwise not a legal env-var identifier) would slip
  # past the exact-string reserved check yet still bind a reserved variable —
  # e.g. `"PATH=/evil"` assembles to `PATH=/evil=x`, which `env` reads as
  # PATH=`/evil=x`, overriding the reserved PATH. Reject every non-identifier
  # name at the boundary.
  defp ensure_valid_names(allowed_env) do
    case Enum.find(Map.keys(allowed_env), fn name -> not valid_name?(name) end) do
      nil -> :ok
      name -> {:error, {:invalid_env_name, name}}
    end
  end

  defp valid_name?(name) when is_binary(name), do: Regex.match?(@env_name_regex, name)
  defp valid_name?(_name), do: false

  defp ensure_no_reserved(allowed_env) do
    case Enum.find(@reserved, fn name -> Map.has_key?(allowed_env, name) end) do
      nil -> :ok
      name -> {:error, {:reserved_env, name}}
    end
  end

  defp fetch_opt(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _absent_or_invalid -> {:error, {:missing_opt, key}}
    end
  end

  defp ensure_env_binary do
    if File.exists?(@env_binary) do
      :ok
    else
      {:error, {:env_binary_missing, @env_binary}}
    end
  end
end
