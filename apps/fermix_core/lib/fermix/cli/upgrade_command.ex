defmodule Fermix.CLI.UpgradeCommand do
  @moduledoc """
  `fermix upgrade [--check]` argv parser and reporter.

  `--check` reports current vs latest and the install method without
  touching disk. The plain command runs the full upgrade and exits
  non-zero on any failure (including managed installs, where we
  print the right `brew upgrade` / `apt upgrade` command instead of
  silently overwriting).
  """

  alias Fermix.CLI.AppRoute
  alias Fermix.CLI.HomeOwner
  alias Fermix.CLI.Upgrade

  @switches [check: :boolean]

  @spec run([String.t()], module(), keyword()) :: non_neg_integer()
  def run(argv, upgrade \\ Upgrade, opts \\ []) when is_list(argv) and is_list(opts) do
    case OptionParser.parse(argv, strict: @switches) do
      {parsed, _, []} -> dispatch(parsed, upgrade, opts)
      {_, _, invalid} -> abort("invalid options: #{inspect(invalid)}")
    end
  end

  # `Upgrade` already answers `{:error, {:app_managed, :update}}` on the app's
  # own binary, which keys on the binary. A formula binary answers that
  # predicate false, so the home-owner check routes it here instead, before the
  # upgrade machinery decides anything about a binary the app owns.
  defp dispatch(parsed, upgrade, opts) do
    home_owner = Keyword.get(opts, :home_owner, HomeOwner)

    cond do
      home_owner.app_managed?(Keyword.take(opts, [:hello, :marker?, :socket_path])) ->
        open_update_settings(opts)

      Keyword.get(parsed, :check, false) ->
        do_check(upgrade, opts)

      true ->
        do_run(upgrade, opts)
    end
  end

  defp do_check(upgrade, opts) do
    case upgrade.check() do
      {:ok, %{available: false, current: current}} ->
        IO.puts("fermix upgrade: already on the latest version (#{current}).")
        0

      {:ok, %{available: true, current: current, latest: latest, install_method: method}} ->
        IO.puts("fermix upgrade: #{current} -> #{latest} available.")
        print_install_method(method)
        0

      {:error, {:app_managed, :update}} ->
        open_update_settings(opts)

      {:error, reason} ->
        abort("check failed: #{inspect(reason)}")
    end
  end

  defp do_run(upgrade, opts) do
    case upgrade.run() do
      :ok ->
        IO.puts("fermix upgrade: complete.")
        0

      {:error, {:app_managed, :update}} ->
        open_update_settings(opts)

      {:error, {:managed_install, name, hint}} ->
        IO.puts(
          :stderr,
          "fermix upgrade: managed by #{name}; run: #{hint}, then " <>
            "`fermix restart`; the daemon keeps running the old version until restarted"
        )

        2

      {:error, {:already_latest, version}} ->
        IO.puts("fermix upgrade: already on #{version}.")
        0

      {:error, reason} ->
        abort(inspect(reason))
    end
  end

  defp open_update_settings(opts) do
    AppRoute.open_and_report(:update, "fermix upgrade", Keyword.get(opts, :route_opts, []))
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
