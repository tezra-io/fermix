defmodule FermixChannels.Commands do
  @moduledoc """
  Channel-side command parser and dispatcher.
  """

  alias FermixChannels.Commands.Registry
  alias FermixChannels.Message

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

  @spec dispatch(result(), (String.t() -> :ok | {:error, term()}), map()) ::
          :ok | :passthrough | {:error, term()}
  def dispatch({:passthrough, _message}, _reply_fn, _context), do: :passthrough

  def dispatch({:command, name, args, message}, reply_fn, context) do
    case Registry.lookup(name) do
      {:ok, handler} -> run_command(handler, message, args, reply_fn, context)
      :error -> :passthrough
    end
  end

  defp run_command(handler, message, args, reply_fn, context) do
    :telemetry.execute(
      [:fermix, :command, :received],
      %{count: 1},
      %{command: handler.name(), channel: message.channel}
    )

    case handler.authorize(message, message.metadata || %{}, context) do
      :ok ->
        handler.execute(Map.put(message, :content, Enum.join(args, " ")), reply_fn, context)

      {:error, :unauthorized} ->
        :telemetry.execute(
          [:fermix, :command, :unauthorized],
          %{count: 1},
          %{command: handler.name(), channel: message.channel}
        )

        reply_fn.("This command requires owner permissions.")
        {:error, :unauthorized}
    end
  end

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
