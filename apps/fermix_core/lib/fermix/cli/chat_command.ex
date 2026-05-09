defmodule Fermix.CLI.ChatCommand do
  @moduledoc """
  `fermix ask` / `fermix chat` one-shot local prompt command.
  """

  alias Fermix.CLI.Daemon.Client

  @spec run([String.t()]) :: non_neg_integer()
  def run(argv) when is_list(argv) do
    case parse(argv) do
      {:ok, opts, words} ->
        run_with_opts(opts, words)

      {:error, :usage} ->
        usage()
    end
  end

  defp run_with_opts(opts, words) do
    with {:ok, content} <- content_from(words, opts),
         {:ok, reply} <- request_agent(content, opts) do
      render_reply(reply, opts)
    else
      {:error, :usage} -> usage()
      {:error, :not_running} -> not_running(opts)
      {:error, reason} -> render_error(reason, opts, %{})
    end
  end

  defp parse(argv) do
    {opts, words, invalid} =
      OptionParser.parse(argv,
        strict: [session: :string, timeout: :integer, json: :boolean, stdin: :boolean],
        aliases: [s: :session, t: :timeout]
      )

    case invalid do
      [] -> validate_opts(opts, words)
      _invalid -> {:error, :usage}
    end
  end

  defp validate_opts(opts, words) do
    if valid_timeout?(Keyword.get(opts, :timeout)) do
      {:ok, opts, words}
    else
      {:error, :usage}
    end
  end

  defp valid_timeout?(nil), do: true
  defp valid_timeout?(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0, do: true
  defp valid_timeout?(_timeout_ms), do: false

  defp content_from(words, opts) do
    content =
      cond do
        words != [] -> Enum.join(words, " ")
        Keyword.get(opts, :stdin, false) -> read_stdin()
        true -> ""
      end
      |> to_string()
      |> String.trim()

    if content == "", do: {:error, :usage}, else: {:ok, content}
  end

  defp read_stdin do
    case IO.read(:stdio, :eof) do
      {:error, _reason} -> ""
      data -> data
    end
  end

  defp request_agent(content, opts) do
    timeout_ms = Keyword.get_lazy(opts, :timeout, &default_timeout_ms/0)

    params =
      %{"content" => content, "timeout_ms" => timeout_ms}
      |> maybe_put("session_id", Keyword.get(opts, :session))

    Client.agent_message(params, timeout: max(timeout_ms, 0) + 1_000)
  end

  defp render_reply(%{"status" => "ok"} = reply, opts) do
    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(success_envelope(reply)))
    else
      IO.puts(reply["response"])
    end

    0
  end

  defp render_reply(%{"status" => "error"} = reply, opts) do
    render_error(Map.get(reply, "error", "unknown_error"), opts, reply)
  end

  defp render_error(reason, opts, extra) do
    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(error_envelope(reason, extra)))
    else
      IO.puts(:stderr, "fermix: #{reason}")
    end

    1
  end

  defp not_running(opts) do
    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(%{"status" => "error", "error" => "not_running"}))
    else
      IO.puts(:stderr, "fermix: not running")
    end

    3
  end

  defp usage do
    IO.puts(:stderr, """
    usage: fermix ask [--session ID] [--timeout MS] [--json] MESSAGE...
           fermix ask --stdin [--session ID] [--timeout MS] [--json]
           fermix chat [--session ID] [--timeout MS] [--json] MESSAGE...
           fermix chat --stdin [--session ID] [--timeout MS] [--json]
    """)

    2
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp success_envelope(reply) do
    %{
      "status" => "ok",
      "response" => Map.get(reply, "response"),
      "session_id" => Map.get(reply, "session_id")
    }
  end

  defp error_envelope(reason, extra) do
    %{"status" => "error", "error" => to_string(reason)}
    |> maybe_put("session_id", Map.get(extra, "session_id"))
  end

  defp default_timeout_ms do
    cli_channel_bridge().default_timeout_ms()
  end

  defp cli_channel_bridge do
    Application.get_env(
      :fermix_core,
      :cli_channel_bridge,
      Module.concat(["FermixChannels", "CLI"])
    )
  end
end
