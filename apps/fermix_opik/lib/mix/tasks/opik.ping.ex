defmodule Mix.Tasks.Opik.Ping do
  @shortdoc "Post one synthetic trace to verify Opik connectivity"
  @moduledoc """
  Sends a single synthetic trace (one `llm` span) to Opik and reports the result.

  Use it to confirm the base URL / auth are right before enabling the live
  exporter — handy because a local Opik's port varies by how it was started.

      mix opik.ping
      mix opik.ping --base-url http://localhost:5173/api --project fermix

  Options mirror `mix opik.replay` (`--base-url`, `--project`).
  """
  use Mix.Task

  alias FermixOpik.Client
  alias FermixOpik.Mapper

  @switches [base_url: :string, project: :string]

  @impl true
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)
    {:ok, _apps} = Application.ensure_all_started(:req)

    project = opts[:project] || System.get_env("FERMIX_OPIK_PROJECT") || "fermix"

    config = %{
      base_url:
        opts[:base_url] || System.get_env("FERMIX_OPIK_BASE_URL") || "http://localhost:5173/api",
      api_key: System.get_env("FERMIX_OPIK_API_KEY"),
      workspace: System.get_env("FERMIX_OPIK_WORKSPACE")
    }

    Mix.shell().info("Pinging Opik at #{config.base_url} (project #{project})…")

    case Client.send_trace(config, synthetic(project)) do
      :ok ->
        Mix.shell().info("OK — wrote trace \"fermix-opik-ping\". Check the #{project} project.")

      {:error, reason} ->
        Mix.raise("Opik ping failed: #{inspect(reason)} — check it's running and the base URL.")
    end
  end

  defp synthetic(project) do
    now = DateTime.utc_now()
    trace_id = Mapper.new_id(now)

    span =
      Mapper.llm_span(
        %{provider: :openai, model: "gpt-4o", status: :ok, tokens: %{prompt: 8, completion: 4}},
        %{duration_ms: 250},
        trace_id: trace_id,
        parent_span_id: nil,
        project_name: project,
        ended: now
      )

    trace =
      Mapper.drop_nil(%{
        id: trace_id,
        project_name: project,
        name: "fermix-opik-ping",
        start_time: Mapper.iso(Mapper.start_of(now, 250)),
        end_time: Mapper.iso(now),
        input: %{text: "ping"},
        output: %{text: "pong"},
        tags: ["ping"]
      })

    %{trace: trace, spans: [span]}
  end
end
