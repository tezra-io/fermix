defmodule FermixCore.Setup.ServiceActivation do
  @moduledoc """
  Idempotent service activation for setup launch.
  """

  alias Fermix.CLI.Service

  @type scope :: :user | :system

  @spec ensure_running(scope(), keyword()) ::
          {:ok, map()} | {:skipped, :not_standalone | :opted_out} | {:error, term()}
  def ensure_running(scope, opts \\ []) when scope in [:user, :system] and is_list(opts) do
    cond do
      Keyword.get(opts, :no_service, false) ->
        {:skipped, :opted_out}

      not standalone?(opts) ->
        {:skipped, :not_standalone}

      not installed?(scope, opts) ->
        install_and_start(scope, opts)

      # A unit exists but no longer matches what this binary would write (e.g.
      # an upgrade changed the template or the daemon PATH): rewrite + reload so
      # the fix reaches an existing install without a manual `service install`.
      drifted?(scope, opts) ->
        reconcile(scope, opts)

      true ->
        restart(scope, opts)
    end
  end

  defp standalone?(opts) do
    opts
    |> Keyword.get(:standalone?, &Burrito.Util.running_standalone?/0)
    |> then(fn fun -> fun.() end)
  end

  defp installed?(scope, opts) do
    service(opts).installed?.(scope, service_opts(opts))
  end

  defp drifted?(scope, opts) do
    service(opts).drifted?.(scope, service_opts(opts))
  end

  defp restart(scope, opts) do
    case service(opts).restart.(scope, service_opts(opts)) do
      :ok -> {:ok, %{scope: scope, action: :restarted}}
      {:error, reason} -> start_after_restart_error(scope, opts, reason)
    end
  end

  defp start_after_restart_error(scope, opts, restart_reason) do
    case service(opts).start.(scope, service_opts(opts)) do
      :ok -> {:ok, %{scope: scope, action: :started}}
      {:error, reason} -> {:error, {:restart_failed, restart_reason, :start_failed, reason}}
    end
  end

  defp install_and_start(scope, opts), do: install_then_start(scope, opts, :installed_started)

  # Drifted unit: same install+start, tagged distinctly so the action is
  # observable (a reconcile rewrote a stale unit, not a fresh first install).
  defp reconcile(scope, opts), do: install_then_start(scope, opts, :reconciled)

  defp install_then_start(scope, opts, action) do
    with :ok <- install(scope, opts),
         :ok <- start(scope, opts) do
      {:ok, %{scope: scope, action: action}}
    end
  end

  defp install(scope, opts) do
    case service(opts).install.(scope, service_opts(opts)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:install_failed, reason}}
    end
  end

  defp start(scope, opts) do
    case service(opts).start.(scope, service_opts(opts)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:start_failed, reason}}
    end
  end

  defp service(opts) do
    Keyword.get(opts, :service, %{
      installed?: &Service.installed?/2,
      drifted?: &Service.drifted?/2,
      install: &Service.install/2,
      start: &Service.start/2,
      restart: &Service.restart/2
    })
  end

  defp service_opts(opts), do: Keyword.get(opts, :service_opts, [])
end
