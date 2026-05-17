defmodule Fermix.CLI.SandboxCommand do
  @moduledoc """
  `fermix sandbox` status and explanation commands.
  """

  alias FermixCore.Sandbox.Config
  alias FermixCore.Sandbox.ConfigMutation
  alias FermixCore.Sandbox.Env
  alias FermixCore.Sandbox.Mode
  alias FermixCore.Sandbox.PathPolicy

  @spec run([String.t()]) :: non_neg_integer()
  def run(["status"]), do: status()
  def run(["explain"]), do: explain()
  def run(["env"]), do: env_status()
  def run(["env", "allow", name]), do: env_allow(name)
  def run(["env", "set", name, "--" | argv]), do: env_set(name, argv)
  def run(["env", "get", name]), do: env_get(name, masked?: true)
  def run(["env", "get", name, "--unsafe-print"]), do: env_get(name, masked?: false)
  def run(["env", command, name]) when command in ["deny", "unset"], do: env_deny(name)
  def run(["commands", "profile", profile]), do: command_profile(profile)
  def run(["commands", "enable", preset]), do: command_preset(:enable, preset)
  def run(["commands", "disable", preset]), do: command_preset(:disable, preset)
  def run(["command", "list"]), do: command_list()
  def run(["mode", mode]), do: mutate({:set_mode, mode}, "mode: #{mode}")
  def run(["grant", "path", path]), do: grant_path(path)
  def run(["grant", "command", name, "--" | argv]), do: grant_command(name, argv)
  def run(["revoke", "path", path]), do: revoke_path(path)
  def run(["revoke", "command", name]), do: revoke_command(name)
  def run(_argv), do: usage()

  defp status do
    config = Config.current()

    IO.puts("""
    mode: #{config.mode}
    workspace: #{config.workspace_root}
    allowed roots: #{length(config.allowed_roots)}
    blocked roots: #{length(config.blocked_roots)}
    env passthrough: #{length(config.env.allow)}
    command profile: #{config.commands.profile}
    command presets: #{length(config.commands.presets)}
    recent denied/hardline: unavailable
    """)

    0
  end

  defp explain do
    config = Config.current()

    IO.puts("""
    mode: #{config.mode}
    workspace: #{config.workspace_root}

    effective roots:
    #{format_list(Mode.effective_roots(config))}

    allowed roots:
    #{format_list(config.allowed_roots)}

    blocked roots:
    #{format_list(config.blocked_roots)}

    protected paths:
    #{format_list(PathPolicy.protected_paths(config))}

    env names:
    #{format_list(config.env.allow)}

    command posture:
    profile: #{config.commands.profile}
    presets: #{format_inline(config.commands.presets)}

    recent denied/hardline: unavailable
    """)

    0
  end

  defp usage do
    IO.puts(
      :stderr,
      "usage: fermix sandbox status|explain|mode MODE|grant path PATH|grant command NAME -- CMD [ARGS...]|revoke path PATH|env [allow|deny|set|get|unset NAME]|commands profile PROFILE|commands enable PRESET|command list"
    )

    2
  end

  defp env_status do
    config = Config.current()
    IO.puts("env mode: #{config.env.mode}\nallowed env: #{format_inline(config.env.allow)}")
    0
  end

  defp env_allow(name) do
    mutate({:add_env_passthrough, name, [source: :env, name: name]}, "env allowed: #{name}")
  end

  defp env_deny(name) do
    mutate({:remove_env_passthrough, name}, "env removed: #{name}")
  end

  defp env_set(_name, []), do: usage()

  defp env_set(name, [command | args]) do
    source = [source: :command, command: command, args: args]
    mutate({:add_env_passthrough, name, source}, "env source set: #{name}")
  end

  defp env_get(name, opts) do
    config = Config.current()

    case Env.build_command(config, [name]) do
      {:ok, env} ->
        value = env |> List.keyfind(name, 0) |> elem(1)
        printed = if Keyword.fetch!(opts, :masked?), do: "***", else: value
        IO.puts("#{name}=#{printed}")
        0

      {:error, reason} ->
        IO.puts(:stderr, "fermix sandbox: #{format_error(reason)}")
        1
    end
  end

  defp command_profile(profile) do
    mutate({:set_command_profile, profile}, "command profile: #{profile}")
  end

  defp command_preset(:enable, preset) do
    mutate({:enable_preset, preset}, "command preset enabled: #{preset}")
  end

  defp command_preset(:disable, preset) do
    mutate({:disable_preset, preset}, "command preset disabled: #{preset}")
  end

  defp command_list do
    config = Config.current()

    IO.puts("""
    command profile: #{config.commands.profile}
    command presets: #{format_inline(config.commands.presets)}
    command capabilities: #{format_inline(enabled_commands(config))}
    """)

    0
  end

  defp grant_path(path) do
    record = %{
      action: "grant_path",
      path: Path.expand(path),
      created_at_ms: System.system_time(:millisecond)
    }

    mutate({:add_allowed_root, path}, "granted: #{path}", grant_record: record)
  end

  defp revoke_path(path) do
    record = %{
      action: "revoke_path",
      path: Path.expand(path),
      created_at_ms: System.system_time(:millisecond)
    }

    mutate({:remove_allowed_root, path}, "revoked: #{path}", grant_record: record)
  end

  defp grant_command(_name, []), do: usage()

  defp grant_command(name, [command | args]) do
    spec = %{enabled: true, command: command, args: args, pass_env: []}
    mutate({:enable_command, name, spec}, "command granted: #{name}")
  end

  defp revoke_command(name) do
    mutate({:disable_command, name}, "command revoked: #{name}")
  end

  defp mutate(mutation, success_message, opts \\ []) do
    case ConfigMutation.apply(Config.current(), mutation, opts) do
      {:ok, _config} ->
        IO.puts(success_message)
        0

      {:error, reason} ->
        IO.puts(:stderr, "fermix sandbox: #{format_error(reason)}")
        1
    end
  end

  defp format_list([]), do: "  (none)"
  defp format_list(values), do: Enum.map_join(values, "\n", &"  - #{&1}")
  defp format_inline([]), do: "(none)"
  defp format_inline(values), do: Enum.join(values, ", ")

  defp enabled_commands(config) do
    config.commands.explicit
    |> Enum.filter(fn {_name, spec} -> spec.enabled end)
    |> Enum.map(fn {name, _spec} -> name end)
  end

  defp format_error({:unsafe_root, path}) do
    "unsafe_root: #{path} cannot be granted. Run: fermix sandbox explain"
  end

  defp format_error({:env_not_allowed, _name} = reason), do: Env.format_error(reason)
  defp format_error({:env_denied, _name} = reason), do: Env.format_error(reason)
  defp format_error({:missing_env, _name} = reason), do: Env.format_error(reason)
  defp format_error({:env_command_failed, _command, _code, _output} = reason), do: Env.format_error(reason)
  defp format_error({:env_command_timeout, _command, _timeout} = reason), do: Env.format_error(reason)
  defp format_error(:env_command_output_too_large), do: Env.format_error(:env_command_output_too_large)
  defp format_error(:empty_env_command_output), do: Env.format_error(:empty_env_command_output)
  defp format_error(:env_command_output_not_single_value), do: Env.format_error(:env_command_output_not_single_value)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
