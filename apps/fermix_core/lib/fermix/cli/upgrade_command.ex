defmodule Fermix.CLI.UpgradeCommand do
  @moduledoc """
  `fermix upgrade [--check]` argv parser and reporter.

  `--check` reports current vs latest and the install method without
  touching disk. The plain command runs the full upgrade and exits
  non-zero on any failure (including managed installs, where we
  print the right `brew upgrade` / `apt upgrade` command instead of
  silently overwriting).
  """

  alias Fermix.CLI.Upgrade

  @switches [check: :boolean]

  @spec run([String.t()]) :: non_neg_integer()
  def run(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {opts, _, []} -> dispatch(opts)
      {_, _, invalid} -> abort("invalid options: #{inspect(invalid)}")
    end
  end

  defp dispatch(opts) do
    if Keyword.get(opts, :check, false), do: do_check(), else: do_run()
  end

  defp do_check do
    case Upgrade.check() do
      {:ok, %{available: false, current: current}} ->
        IO.puts("fermix upgrade: already on the latest version (#{current}).")
        0

      {:ok, %{available: true, current: current, latest: latest, install_method: method}} ->
        IO.puts("fermix upgrade: #{current} -> #{latest} available.")
        print_install_method(method)
        0

      {:error, reason} ->
        abort("check failed: #{inspect(reason)}")
    end
  end

  defp do_run do
    case Upgrade.run() do
      :ok ->
        IO.puts("fermix upgrade: complete.")
        0

      {:error, {:managed_install, name, hint}} ->
        IO.puts(:stderr, "fermix upgrade: managed by #{name}; run: #{hint}")
        2

      {:error, {:already_latest, version}} ->
        IO.puts("fermix upgrade: already on #{version}.")
        0

      {:error, reason} ->
        abort(inspect(reason))
    end
  end

  defp print_install_method({:managed, name, hint}) do
    IO.puts("Managed by #{name}; upgrade with: #{hint}")
  end

  defp print_install_method({:unmanaged, path}) do
    IO.puts("Unmanaged install at #{path}; run `fermix upgrade` to apply.")
  end

  defp print_install_method(_), do: :ok

  defp abort(message) do
    IO.puts(:stderr, "fermix upgrade: #{message}")
    1
  end
end
