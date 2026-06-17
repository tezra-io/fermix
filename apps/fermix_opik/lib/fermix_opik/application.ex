defmodule FermixOpik.Application do
  @moduledoc """
  Starts the exporter only when enabled.

  Disabled (the default): an empty supervisor — zero overhead, nothing attached.
  Enabled: a `Sender` and `Aggregator`, then `Reporter.attach/1` subscribes to
  Fermix's telemetry. Started automatically because `fermix_opik` is an OTP app;
  add it as a dependency of the Fermix release to switch it on.
  """

  use Application

  require Logger

  alias FermixOpik.Aggregator
  alias FermixOpik.Reporter
  alias FermixOpik.Sender

  @impl true
  def start(_type, _args) do
    children = children(FermixOpik.enabled?())
    opts = [strategy: :one_for_one, name: FermixOpik.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      if FermixOpik.enabled?(), do: attach()
      {:ok, pid}
    end
  end

  defp children(false), do: []

  defp children(true) do
    config = FermixOpik.client_config()

    [
      {Sender, config: config},
      {Aggregator,
       project: FermixOpik.project_name(),
       ttl_ms: Application.get_env(:fermix_opik, :trace_ttl_ms, 120_000),
       max_queue: Application.get_env(:fermix_opik, :max_queue, 500)}
    ]
  end

  defp attach do
    case Reporter.attach() do
      :ok ->
        Logger.info("FermixOpik exporting traces to #{FermixOpik.client_config().base_url}")

      {:error, :already_exists} ->
        :ok
    end
  end

  @impl true
  def stop(_state) do
    Reporter.detach()
    :ok
  end
end
