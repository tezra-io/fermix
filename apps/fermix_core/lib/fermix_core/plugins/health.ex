defmodule FermixCore.Plugins.Health do
  @moduledoc """
  Plugin health checks. Live provider probes run only when requested.
  """

  alias FermixCore.Auth.Redaction
  alias FermixCore.Auth.TokenManager
  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Plugins.Config
  alias FermixCore.Plugins.Registry
  alias FermixCore.Plugins.Status

  @calendar_probe "https://www.googleapis.com/calendar/v3/users/me/calendarList"
  @gmail_probe "https://gmail.googleapis.com/gmail/v1/users/me/profile"

  @spec check(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def check(name, opts \\ []) when is_binary(name) and is_list(opts) do
    full? = Keyword.get(opts, :full?, false)

    with {:ok, plugin} <- Registry.find(name),
         status <- Status.status(plugin, Keyword.take(opts, [:probe])),
         :ok <- require_ready(status) do
      if full?, do: live_probe(plugin, opts), else: {:ok, %{status: status, live_probe?: false}}
    end
  end

  @spec check_tool(String.t(), keyword()) :: {:ok, Tool.tool_result()}
  def check_tool(name, opts \\ []) do
    case check(name, Keyword.put(opts, :full?, true)) do
      {:ok, result} -> {:ok, Tool.success(Jason.encode!(result))}
      {:error, reason} -> {:ok, Tool.error(format_error(reason))}
    end
  end

  defp require_ready(:ready), do: :ok
  defp require_ready(status), do: {:error, {:not_ready, status}}

  defp live_probe(%{name: "google_calendar"} = plugin, opts),
    do: google_probe(plugin, @calendar_probe, opts)

  defp live_probe(%{name: "gmail"} = plugin, opts), do: google_probe(plugin, @gmail_probe, opts)

  defp live_probe(plugin, _opts),
    do: {:ok, %{plugin: plugin.name, status: :ready, live_probe?: false}}

  defp google_probe(plugin, url, opts) do
    req_options = Keyword.get(opts, :req_options, [])

    with {:ok, token} <- TokenManager.get_token(Config.auth_profile(plugin)),
         {:ok, %{status: status, body: body}} <- request(url, token, req_options),
         :ok <- probe_status(status, body) do
      {:ok, %{plugin: plugin.name, status: :ready, live_probe?: true}}
    end
  end

  defp request(url, token, req_options) do
    Req.new(method: :get, url: url, headers: [{"authorization", "Bearer #{token}"}])
    |> Req.merge(req_options)
    |> Req.request()
  end

  defp probe_status(status, _body) when status in 200..299, do: :ok
  defp probe_status(status, body), do: {:error, {:provider_error, status, body}}

  defp format_error({:not_ready, status}), do: "plugin is not ready: #{status}"
  defp format_error(reason), do: Redaction.format(reason)
end
