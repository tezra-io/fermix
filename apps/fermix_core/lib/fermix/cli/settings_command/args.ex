defmodule Fermix.CLI.SettingsCommand.Args do
  @moduledoc """
  The argv grammar of `fermix settings`, with no side effects.

  It parses the subcommand, the `KEY=VALUE` pairs of `set`, and the literal of
  each value by the kind of its row. Every other check (ranges, options,
  lengths, which keys a section has) is the daemon's, so a literal that does not
  parse is sent as typed and the operator reads the daemon's own refusal.

  A secret is never taken as an argument. `secret set ID VALUE`, `secret set
  ID=VALUE`, a value that starts with `--`, and a `set` pair whose key is a
  published secret id are refused here, before anything reaches
  a daemon; a `set` pair whose row kind is `secret` is refused once the rows are
  read (`secret_keys/2`). The secret-id families are this build's own constants
  from `Management.Secrets`, not a second validator.

  A list value is split on commas. Every published list row holds host names,
  app names or environment variable names, none of which contains a comma; a
  future list row whose entries can contain one needs a repeated-key or
  `--stdin` convention instead.
  """

  alias FermixCore.Management.Secrets

  @switches [json: :boolean, stdin: :boolean, info: :boolean]

  @type flags :: %{json: boolean(), stdin: boolean(), info: boolean()}
  @type pair :: {String.t(), String.t()}
  @type command ::
          {:list, flags()}
          | {:show, String.t(), flags()}
          | {:set, String.t(), [pair()], flags()}
          | {:secret_set, String.t(), flags()}
          | {:secret_clear, String.t(), flags()}
          | {:primary, String.t() | nil, flags()}
          | {:reload, flags()}
          | {:usage, String.t()}
          | {:secret_in_argv, :set | :secret_set, String.t()}

  @doc """
  Parses argv into one command. A secret in argv wins over every other
  verdict, so the operator is always told to rotate a value they typed.
  """
  @spec parse([String.t()]) :: command()
  def parse(argv) when is_list(argv) do
    {opts, positionals, invalid} = OptionParser.parse(argv, strict: @switches)

    case secret_in_argv(positionals, invalid) do
      nil -> positionals |> command(flags(opts), invalid) |> restrict_flags()
      refusal -> refusal
    end
  end

  @doc "Splits `KEY=VALUE` tokens on the first `=`, keeping the typed order."
  @spec pairs([String.t()]) :: {:ok, [pair()]} | {:usage, String.t()}
  def pairs(tokens) when is_list(tokens) do
    tokens
    |> Enum.reduce_while({:ok, []}, &add_pair/2)
    |> case do
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      {:usage, _reason} = usage -> usage
    end
  end

  @doc "The JSON value for a typed literal, read by its row's kind."
  @spec coerce(String.t() | nil, String.t()) :: term()
  def coerce("toggle", "true"), do: true
  def coerce("toggle", "false"), do: false
  def coerce("number", raw) when is_binary(raw), do: number(raw)
  def coerce("list", ""), do: []
  def coerce("list", raw) when is_binary(raw), do: String.split(raw, ",")
  def coerce(kind, raw) when (is_binary(kind) or is_nil(kind)) and is_binary(raw), do: raw

  @doc "The keys among `pairs` that are secrets, by row kind or by published id."
  @spec secret_keys([pair()], [map()]) :: [String.t()]
  def secret_keys(pairs, rows) when is_list(pairs) and is_list(rows) do
    for {key, _raw} <- pairs, secret_id?(key) or row_kind(rows, key) == "secret", do: key
  end

  @doc "The `values` map for `settings.apply`; a key with no row is sent raw."
  @spec values([pair()], [map()]) :: %{String.t() => term()}
  def values(pairs, rows) when is_list(pairs) and is_list(rows) do
    Map.new(pairs, fn {key, raw} -> {key, coerce(row_kind(rows, key), raw)} end)
  end

  # A value typed after the id, glued to it as `ID=VALUE` (the form `set`
  # teaches), or starting with `--` (parsed as an unknown switch) is a secret on
  # the command line. No published secret id contains `=`.
  defp secret_in_argv(["secret", "set", id | rest], invalid),
    do: secret_token(id, rest != [] or invalid != [])

  defp secret_in_argv(["secret", "clear", id | _rest], invalid),
    do: secret_token(id, invalid != [])

  defp secret_in_argv(["set", _section | tokens], _invalid) do
    case Enum.find(tokens, &secret_id?(token_key(&1))) do
      nil -> nil
      token -> {:secret_in_argv, :set, token_key(token)}
    end
  end

  defp secret_in_argv(_positionals, _invalid), do: nil

  defp secret_token(id, extra?) do
    if extra? or String.contains?(id, "="),
      do: {:secret_in_argv, :secret_set, token_key(id)},
      else: nil
  end

  defp token_key(token), do: token |> String.split("=", parts: 2) |> hd()

  defp secret_id?(key) do
    key in Secrets.ids() or
      String.starts_with?(key, [
        Secrets.env_prefix(),
        Secrets.plugin_prefix(),
        Secrets.oauth_client_prefix()
      ])
  end

  # An unknown switch is never echoed: a secret typed on the command line may
  # start with `--`, and then its name is the secret.
  defp command(_positionals, _flags, [_unknown | _rest]),
    do: {:usage, "unknown option (the options are --json, --stdin and --info)"}

  defp command([], flags, []), do: {:list, flags}
  defp command(["list"], flags, []), do: {:list, flags}
  defp command(["show", section], flags, []) when section != "", do: {:show, section, flags}

  defp command(["set", section | [_ | _] = tokens], flags, []) when section != "" do
    case pairs(tokens) do
      {:ok, pairs} -> {:set, section, pairs, flags}
      {:usage, _reason} = usage -> usage
    end
  end

  defp command(["secret", "set", id], flags, []) when id != "", do: {:secret_set, id, flags}
  defp command(["secret", "clear", id], flags, []) when id != "", do: {:secret_clear, id, flags}
  defp command(["primary"], flags, []), do: {:primary, nil, flags}

  defp command(["primary", provider], flags, []) when provider != "",
    do: {:primary, provider, flags}

  defp command(["reload"], flags, []), do: {:reload, flags}
  defp command(_positionals, _flags, []), do: {:usage, "unknown or incomplete subcommand"}

  defp restrict_flags({:usage, _reason} = usage), do: usage

  defp restrict_flags(command) do
    flags = elem(command, tuple_size(command) - 1)
    allowed = allowed_flags(command)

    case Enum.find([:stdin, :info], &(Map.fetch!(flags, &1) and &1 not in allowed)) do
      nil -> command
      :stdin -> {:usage, "--stdin goes only with `secret set`"}
      :info -> {:usage, "--info goes only with `show`"}
    end
  end

  defp allowed_flags({:show, _section, _flags}), do: [:info]
  defp allowed_flags({:secret_set, _id, _flags}), do: [:stdin]
  defp allowed_flags(_command), do: []

  defp flags(opts) do
    %{
      json: Keyword.get(opts, :json, false),
      stdin: Keyword.get(opts, :stdin, false),
      info: Keyword.get(opts, :info, false)
    }
  end

  # The reason never echoes the token: a token with no `=` may be a secret
  # typed as a separate argument.
  defp add_pair(token, {:ok, acc}) do
    case String.split(token, "=", parts: 2) do
      [key, raw] when key != "" -> unique_pair(key, raw, acc)
      _malformed -> {:halt, {:usage, "every change is KEY=VALUE"}}
    end
  end

  # A repeated key would otherwise be dropped silently by `Map.new/2`.
  defp unique_pair(key, raw, acc) do
    if List.keymember?(acc, key, 0),
      do: {:halt, {:usage, "#{key} is given more than once"}},
      else: {:cont, {:ok, [{key, raw} | acc]}}
  end

  defp row_kind(rows, key) do
    Enum.find_value(rows, fn row -> if row["key"] == key, do: row["kind"] end)
  end

  defp number(raw) do
    case Integer.parse(raw) do
      {integer, ""} -> integer
      _not_integer -> float(raw)
    end
  end

  defp float(raw) do
    case Float.parse(raw) do
      {float, ""} -> float
      _not_float -> raw
    end
  end
end
