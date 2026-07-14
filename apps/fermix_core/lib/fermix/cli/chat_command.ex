defmodule Fermix.CLI.ChatCommand do
  @moduledoc """
  `fermix ask` / `fermix chat` one-shot local prompt command.
  """

  alias Fermix.CLI.Daemon.Client

  @image_mime %{
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif" => "image/gif",
    ".webp" => "image/webp"
  }
  @max_attach_bytes 20 * 1_024 * 1_024

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
    with {:ok, images} <- images_from(opts),
         {:ok, content} <- content_from(words, opts, images),
         {:ok, reply} <- request_agent(content, images, opts) do
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
        strict: [
          session: :string,
          timeout: :integer,
          json: :boolean,
          stdin: :boolean,
          attach: :keep
        ],
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

  defp content_from(words, opts, images) do
    content =
      cond do
        words != [] -> Enum.join(words, " ")
        Keyword.get(opts, :stdin, false) -> read_stdin()
        true -> ""
      end
      |> to_string()
      |> String.trim()

    cond do
      content != "" -> {:ok, content}
      # An image-only turn (no text) is valid when an attachment is present.
      images != [] -> {:ok, ""}
      true -> {:error, :usage}
    end
  end

  # Read each `--attach PATH` into a JSON-safe image payload (mime + base64).
  # Fail loud on an unreadable path, an over-cap file, or a non-image extension.
  defp images_from(opts) do
    opts
    |> Keyword.get_values(:attach)
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
      case read_image(path) do
        {:ok, image} -> {:cont, {:ok, [image | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, images} -> {:ok, Enum.reverse(images)}
      other -> other
    end
  end

  defp read_image(path) do
    with {:ok, mime} <- image_mime(path),
         {:ok, %{size: size}} when size <= @max_attach_bytes <- File.stat(path),
         {:ok, bytes} <- File.read(path) do
      {:ok, %{"mime_type" => mime, "data_base64" => Base.encode64(bytes)}}
    else
      {:ok, %{size: size}} ->
        {:error, "attachment #{path} is #{size} bytes; exceeds the #{@max_attach_bytes}-byte cap"}

      {:error, :unsupported_attachment} ->
        {:error, "unsupported attachment type: #{path} (expected .png/.jpg/.jpeg/.gif/.webp)"}

      {:error, reason} ->
        {:error, "cannot read attachment #{path}: #{inspect(reason)}"}
    end
  end

  defp image_mime(path) do
    case Map.fetch(@image_mime, path |> Path.extname() |> String.downcase()) do
      {:ok, mime} -> {:ok, mime}
      :error -> {:error, :unsupported_attachment}
    end
  end

  defp read_stdin do
    case IO.read(:stdio, :eof) do
      {:error, _reason} -> ""
      data -> data
    end
  end

  defp request_agent(content, images, opts) do
    timeout_ms = Keyword.get_lazy(opts, :timeout, &default_timeout_ms/0)

    params =
      %{"content" => content, "timeout_ms" => timeout_ms, "cwd" => File.cwd!()}
      |> maybe_put("session_id", Keyword.get(opts, :session))
      |> maybe_put_images(images)

    Client.agent_message(params, timeout: max(timeout_ms, 0) + 1_000)
  end

  defp maybe_put_images(params, []), do: params
  defp maybe_put_images(params, images), do: Map.put(params, "images", images)

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
      IO.puts(:stderr, "fermix: #{reason_to_string(reason)}")
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
    usage: fermix ask [--session ID] [--timeout MS] [--json] [--attach PATH]... MESSAGE...
           fermix ask --stdin [--session ID] [--timeout MS] [--json] [--attach PATH]...
           fermix chat [--session ID] [--timeout MS] [--json] [--attach PATH]... MESSAGE...
           fermix chat --stdin [--session ID] [--timeout MS] [--json] [--attach PATH]...

    --attach PATH   attach a local image (.png/.jpg/.jpeg/.gif/.webp); repeatable
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
    %{"status" => "error", "error" => reason_to_string(reason)}
    |> maybe_put("session_id", Map.get(extra, "session_id"))
  end

  defp reason_to_string({:request_too_large, size, limit}) do
    "request too large: the encoded request is #{mib(size)} MiB and exceeds " <>
      "daemon frame cap of #{mib(limit)} MiB. Send fewer or smaller images."
  end

  defp reason_to_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_to_string(reason) when is_binary(reason), do: reason
  defp reason_to_string(reason), do: inspect(reason)

  defp mib(bytes), do: Float.round(bytes / 1_048_576, 1)

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
