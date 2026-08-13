defmodule FermixCore.Log.RedactingFormatter do
  @moduledoc """
  A `:logger` formatter wrapper that redacts secret-shaped tokens from the
  final formatted output of any inner formatter.

  Because it runs on the formatted string, it covers every producer — plain
  `Logger` calls, `{format, args}` messages, and OTP crash reports (the path
  that leaked a full API key in 0.5.2's Port-leak incident). It is a backstop,
  not a substitute for redacting at the source.

  Attach by wrapping an existing formatter tuple:

      formatter: RedactingFormatter.wrap({:logger_formatter, %{template: ...}})

  or retrofit a live handler with `install/1`.
  """

  # Each pattern anchors on a distinctive vendor prefix (word-bounded, so
  # e.g. "risk-based" or "task-management" never match) and requires the
  # long random tail real credentials have.
  @patterns [
    {"private-key",
     ~r/-----BEGIN (?:(?:EC|RSA|DSA|ENCRYPTED) )?PRIVATE KEY-----.*?-----END (?:(?:EC|RSA|DSA|ENCRYPTED) )?PRIVATE KEY-----/s},
    {"openai", ~r/\bsk-[A-Za-z0-9_-]{16,}/},
    {"github", ~r/\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}/},
    {"github", ~r/\bgithub_pat_[A-Za-z0-9_]{20,}/},
    {"slack", ~r/\bxox[baprs]-[A-Za-z0-9-]{10,}/},
    {"aws", ~r/\bAKIA[0-9A-Z]{16}\b/},
    {"xai", ~r/\bxai-[A-Za-z0-9]{20,}/},
    {"google", ~r/\bAIza[0-9A-Za-z_-]{30,}/},
    {"telegram", ~r/\b\d{6,}:[A-Za-z0-9_-]{30,}/},
    {"bearer", ~r/\bBearer\s+[A-Za-z0-9._~+\/=-]{20,}/}
  ]

  @type formatter :: {module(), :logger.formatter_config() | term()}

  @doc """
  Wraps an inner `{module, config}` formatter tuple so its output is redacted.
  """
  @spec wrap(formatter()) :: formatter()
  def wrap({inner_module, inner_config}) when is_atom(inner_module) do
    {__MODULE__, %{inner: {inner_module, inner_config}}}
  end

  @doc """
  Replaces the formatter of a live handler with its redacting wrapper.
  Idempotent: an already-wrapped handler is left unchanged.
  """
  @spec install(:logger.handler_id()) :: :ok | {:error, term()}
  def install(handler_id) when is_atom(handler_id) do
    case :logger.get_handler_config(handler_id) do
      {:ok, %{formatter: {__MODULE__, _}}} ->
        :ok

      {:ok, %{formatter: inner}} ->
        :logger.update_handler_config(handler_id, :formatter, wrap(inner))

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  `:logger` formatter callback: formats via the inner formatter, then redacts.
  """
  @spec format(:logger.log_event(), map()) :: :unicode.chardata()
  def format(event, %{inner: {inner_module, inner_config}}) do
    event
    |> inner_module.format(inner_config)
    |> to_utf8_binary()
    |> redact()
  end

  # Formatter output is unicode chardata: codepoints above 127 can appear as
  # bare list integers (e.g. µ = 181 in LiveView's "Replied in 89µs").
  # IO.iodata_to_binary/1 would encode those as raw BYTES — invalid UTF-8
  # that makes the handler reject and drop the whole log line.
  defp to_utf8_binary(chardata) do
    case :unicode.characters_to_binary(chardata) do
      binary when is_binary(binary) ->
        binary

      other ->
        raise ArgumentError,
              "inner log formatter returned invalid chardata: #{inspect(other)}"
    end
  end

  @doc """
  Redacts secret-shaped tokens in a binary, replacing each with a
  `[REDACTED:<vendor>]` marker.
  """
  @spec redact(binary()) :: binary()
  def redact(line) when is_binary(line) do
    Enum.reduce(@patterns, line, fn {label, pattern}, acc ->
      Regex.replace(pattern, acc, "[REDACTED:#{label}]")
    end)
  end
end
