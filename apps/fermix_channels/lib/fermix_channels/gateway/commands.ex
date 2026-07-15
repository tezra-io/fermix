defmodule FermixChannels.Gateway.Commands do
  @moduledoc """
  Channel-side command parser and dispatcher.
  """

  alias FermixChannels.Gateway.Commands.Registry
  alias FermixChannels.Gateway.Message
  alias FermixCore.Reply
  alias FermixCore.Telemetry

  @type result ::
          {:command, String.t(), [String.t()], Message.t()} | {:passthrough, Message.t()}

  @spec parse(Message.t(), keyword()) :: result()
  def parse(%Message{content: content} = message, opts \\ []) do
    bot_name = Keyword.get(opts, :bot_name)

    case parse_leading_command(content, bot_name) do
      {name, args} -> {:command, name, args, message}
      :no_command -> {:passthrough, message}
    end
  end

  @spec dispatch(result(), Reply.reply_fn(), map()) ::
          :ok | :passthrough | {:enqueue, Message.t()} | {:error, term()}
  def dispatch(command_result, reply_fn, context) do
    {result, duration_us} =
      Telemetry.timed_us(fn -> do_dispatch(command_result, reply_fn, context) end)

    emit_dispatch_telemetry(command_result, result, duration_us)
    result
  end

  defp do_dispatch({:passthrough, _message}, _reply_fn, _context), do: :passthrough

  defp do_dispatch({:command, name, args, message}, reply_fn, context) do
    case Registry.lookup(name) do
      {:ok, handler} ->
        run_command(name, handler, message, args, reply_fn, context)

      # Deliberate policy: an unrecognized slash command is NOT a hard error —
      # it passes through to the agent as ordinary text (so `/notacommand` and
      # bare slashes in prose still reach the model). Make commands a hard
      # boundary here only if that product decision changes.
      :error ->
        :passthrough
    end
  end

  defp run_command(name, handler, message, args, reply_fn, context) do
    :telemetry.execute(
      [:fermix, :command, :received],
      %{count: 1},
      %{command: handler.name(), channel: message.channel}
    )

    # Set the invoked command name before authorization so a handler with
    # multiple aliases (e.g. sandbox: /sandbox vs /grant //confirm) can gate
    # each subcommand on its own role requirement.
    message = put_command_name(message, name)

    case handler.authorize(message, message.metadata || %{}, context) do
      :ok ->
        message
        |> Map.put(:content, Enum.join(args, " "))
        |> handler.execute(reply_fn, context)

      {:error, :unauthorized} ->
        :telemetry.execute(
          [:fermix, :command, :unauthorized],
          %{count: 1},
          %{command: handler.name(), channel: message.channel}
        )

        reply_fn.({:text, "This command requires owner permissions."})
        {:error, :unauthorized}
    end
  end

  defp put_command_name(message, name) do
    metadata = Map.put(message.metadata || %{}, :command_name, name)
    Map.put(message, :metadata, metadata)
  end

  defp emit_dispatch_telemetry(command_result, result, duration_us) do
    :telemetry.execute(
      [:fermix, :command, :dispatch],
      %{duration_us: duration_us},
      %{
        command: parsed_command(command_result),
        channel: parsed_channel(command_result),
        status: dispatch_status(result)
      }
    )
  end

  defp parsed_command({:command, name, _args, _message}), do: name
  defp parsed_command({:passthrough, _message}), do: nil

  defp parsed_channel({:command, _name, _args, %Message{channel: channel}}), do: channel
  defp parsed_channel({:passthrough, %Message{channel: channel}}), do: channel

  defp dispatch_status(:ok), do: :ok
  defp dispatch_status(:passthrough), do: :passthrough
  defp dispatch_status({:enqueue, _message}), do: :enqueued
  defp dispatch_status({:error, :unauthorized}), do: :unauthorized
  defp dispatch_status({:error, _reason}), do: :error

  defp parse_leading_command(content, bot_name) do
    content = content |> to_string() |> String.trim_leading()

    case String.split(content, ~r/\s+/, parts: 2, trim: true) do
      ["/" <> raw_cmd | rest] ->
        cmd = raw_cmd |> strip_botname(bot_name) |> String.downcase()
        args = if rest == [], do: [], else: String.split(hd(rest), ~r/\s+/, trim: true)

        if String.match?(cmd, ~r/^[a-z][a-z0-9_]*$/), do: {cmd, args}, else: :no_command

      _other ->
        :no_command
    end
  end

  defp strip_botname(cmd, nil), do: cmd

  defp strip_botname(cmd, bot_name) do
    suffix = "@" <> String.downcase(bot_name)
    downcased = String.downcase(cmd)

    if String.ends_with?(downcased, suffix) do
      String.slice(cmd, 0, String.length(cmd) - String.length(suffix))
    else
      cmd
    end
  end
end
