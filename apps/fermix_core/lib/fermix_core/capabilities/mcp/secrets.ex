defmodule FermixCore.Capabilities.MCP.Secrets do
  @moduledoc """
  The values an operator MCP server declares by name (M74 §4, E6): environment
  variables (`env_secrets`), request headers (`header_secrets`) and the secret
  of a pre-registered sign-in client (`oauth_client_id`). They live in the
  secret store under the active profile, never in `config.toml`, and this
  module is the one place that knows how one is addressed, written, read,
  deleted and reported present.

  An id is `mcp:<server>/env/<NAME>`, `mcp:<server>/header/<Header-Name>` or
  `mcp:<server>/client_secret`. It is the `secret.set` spelling and the name
  the store files the value under, behind the profile prefix every Fermix item
  carries (`SecretWriter.scoped_prefix/1`), the way `env:<NAME>` is
  `external_env:<NAME>`. The family is open: an id means something only for a
  server that declares it, so nothing here enumerates the store, and a server's
  values are deleted by the names it declares.

  Two sets, each with one owner: what a server declares (`declared/1`), every
  value it may hold and that is deleted with it, and what it needs to start
  (`needed/1`), which is all of them but the client secret: a server with an
  `oauth_client_id` and no stored secret is a pre-registered public client.

  Present means readable now: a missing item and a store that refuses the read
  are both not present, because either way the server cannot be given the
  value. `fetch/2` is the read the stdio transport makes in its own `init`, so a
  value is never in a child spec.

  The grammar holds only names a new server may take. A server a file named
  before that rule (`GitHub`) keeps loading, but no id addresses it, so it holds
  no value: nothing is read for it and nothing is left to delete.
  """

  alias FermixCore.Capabilities.MCP.Config, as: McpConfig
  alias FermixCore.Setup.SecretWriter

  @prefix "mcp:"
  @env_pattern ~r/\A[A-Za-z_][A-Za-z0-9_]{0,127}\z/
  @header_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z/
  @max_value_bytes 8_192
  @line_breaks ["\n", "\r", <<0>>]

  @type ref :: {:env, String.t()} | {:header, String.t()} | :client_secret
  @type value_error :: :empty_value | :value_too_large | :value_not_single_line
  @type presence :: %{
          env: [{String.t(), boolean()}],
          headers: [{String.t(), boolean()}],
          client_secret: boolean()
        }

  @doc "The id prefix of the family."
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  @doc "The largest value, in bytes, that may be stored."
  @spec max_value_bytes() :: pos_integer()
  def max_value_bytes, do: @max_value_bytes

  @doc "Whether `name` may be declared in `env_secrets`."
  @spec env_name?(String.t()) :: boolean()
  def env_name?(name) when is_binary(name), do: Regex.match?(@env_pattern, name)

  @doc "Whether `name` may be declared in `header_secrets`."
  @spec header_name?(String.t()) :: boolean()
  def header_name?(name) when is_binary(name), do: Regex.match?(@header_pattern, name)

  @doc "The id of one declared value."
  @spec id(String.t(), ref()) :: String.t()
  def id(server, {:env, name}) when is_binary(server), do: "#{@prefix}#{server}/env/#{name}"
  def id(server, {:header, name}) when is_binary(server), do: "#{@prefix}#{server}/header/#{name}"
  def id(server, :client_secret) when is_binary(server), do: "#{@prefix}#{server}/client_secret"

  @doc "The server and the value an id names, or `:error` for one outside the grammar."
  @spec parse_id(String.t()) :: {:ok, String.t(), ref()} | :error
  def parse_id(@prefix <> rest) do
    case String.split(rest, "/") do
      [server, "env", name] -> checked(server, {:env, name}, env_name?(name))
      [server, "header", name] -> checked(server, {:header, name}, header_name?(name))
      [server, "client_secret"] -> checked(server, :client_secret, true)
      _other -> :error
    end
  end

  def parse_id(id) when is_binary(id), do: :error

  @doc """
  The server an `mcp:` id is about, read up to its first `/` whether or not the
  rest is valid: what a refusal names.
  """
  @spec server_of(String.t()) :: String.t()
  def server_of(@prefix <> rest), do: rest |> String.split("/", parts: 2) |> hd()

  defp checked(server, ref, valid_ref?) do
    if valid_ref? and McpConfig.valid_name?(server), do: {:ok, server, ref}, else: :error
  end

  @doc "The secret writer's key for one declared value."
  @spec key(String.t(), ref()) :: SecretWriter.mcp_key()
  def key(server, ref), do: {:mcp, id(server, ref)}

  @doc "Every value `server` declares, in the order its row lists them."
  @spec declared(McpConfig.server_config()) :: [ref()]
  def declared(%{transport: :stdio, env_secrets: names}), do: Enum.map(names, &{:env, &1})

  def declared(%{transport: :http, header_secrets: names, oauth_client_id: client_id}) do
    headers = Enum.map(names, &{:header, &1})
    if is_binary(client_id), do: headers ++ [:client_secret], else: headers
  end

  @doc "Whether `server` declares `ref`."
  @spec declares?(McpConfig.server_config(), ref()) :: boolean()
  def declares?(server, ref), do: ref in declared(server)

  @doc "Whether `value` may be stored: 1 to 8,192 bytes, no NUL, CR or LF."
  @spec validate_value(String.t()) :: :ok | {:error, value_error()}
  def validate_value(value) when is_binary(value) do
    cond do
      value == "" -> {:error, :empty_value}
      byte_size(value) > @max_value_bytes -> {:error, :value_too_large}
      String.contains?(value, @line_breaks) -> {:error, :value_not_single_line}
      true -> :ok
    end
  end

  @doc """
  Stores one value and reads it back. `Authorization` is sent as
  `Bearer <value>`, so a pasted `Bearer …` is stored as what follows it.
  """
  @spec put(String.t(), ref(), String.t()) :: :ok | {:error, term()}
  def put(server, ref, value) when is_binary(server) and is_binary(value) do
    stored = stored_value(ref, value)

    with :ok <- validate_value(stored),
         :ok <- SecretWriter.put(key(server, ref), stored) do
      verify(server, ref, stored)
    end
  end

  defp stored_value({:header, name}, value) do
    if String.downcase(name) == "authorization",
      do: value |> String.replace(~r/\Abearer\s+/i, "") |> String.trim(),
      else: value
  end

  defp stored_value(_ref, value), do: value

  defp verify(server, ref, stored) do
    case fetch(server, ref) do
      {:ok, ^stored} -> :ok
      {:ok, _other} -> {:error, :verify_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Reads one value: the read a server's transport makes when it starts."
  @spec fetch(String.t(), ref()) :: {:ok, String.t()} | {:error, term()}
  def fetch(server, ref) when is_binary(server) do
    if McpConfig.valid_name?(server),
      do: SecretWriter.get(key(server, ref)),
      else: {:error, :unaddressable_server}
  end

  @doc "Forgets one value. Forgetting one that is not stored succeeds."
  @spec delete(String.t(), ref()) :: :ok | {:error, term()}
  def delete(server, ref) when is_binary(server), do: SecretWriter.delete(key(server, ref))

  @doc """
  Forgets every value `server` declares, stopping at the first the store
  refuses, so a refusal leaves the declarations that name what is left. A
  server no id addresses holds none.
  """
  @spec delete_declared(McpConfig.server_config()) :: :ok | {:error, term()}
  def delete_declared(%{name: name} = server) do
    if McpConfig.valid_name?(name), do: delete_each(server), else: :ok
  end

  defp delete_each(%{name: name} = server) do
    server
    |> declared()
    |> Enum.reduce_while(:ok, fn ref, :ok ->
      case delete(name, ref) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @doc "Whether each value `server` declares is present, by kind, for its row."
  @spec presence(McpConfig.server_config()) :: presence()
  def presence(%{name: name} = server) do
    refs = declared(server)

    %{
      env: for({:env, var} <- refs, do: {var, present?(name, {:env, var})}),
      headers: for({:header, header} <- refs, do: {header, present?(name, {:header, header})}),
      client_secret: :client_secret in refs and present?(name, :client_secret)
    }
  end

  @doc """
  Every value `server` cannot start without, in the order its row lists them:
  what it declares but the client secret, which a public client has none of.
  """
  @spec needed(McpConfig.server_config()) :: [ref()]
  def needed(server), do: declared(server) -- [:client_secret]

  @doc "Whether every value `server` needs is present."
  @spec complete?(McpConfig.server_config()) :: boolean()
  def complete?(%{name: name} = server),
    do: server |> needed() |> Enum.all?(&present?(name, &1))

  defp present?(server, ref), do: match?({:ok, _value}, fetch(server, ref))
end
