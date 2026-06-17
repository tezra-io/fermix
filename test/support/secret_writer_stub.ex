defmodule FermixTestSupport.SecretWriterStub do
  @moduledoc false

  @behaviour FermixCore.Setup.SecretWriter

  @table __MODULE__

  @impl true
  def available?(_opts \\ []), do: true

  @impl true
  def put(key, value, opts \\ []) when is_atom(key) and is_binary(value) do
    ensure_table()
    :ets.insert(@table, {{profile(opts), key}, value})
    :ok
  end

  @impl true
  def get(key, opts \\ []) when is_atom(key) do
    ensure_table()

    case :ets.lookup(@table, {profile(opts), key}) do
      [{_entry, value}] -> {:ok, value}
      [] -> {:error, :missing_secret}
    end
  end

  @impl true
  def command_source(key, _opts \\ []) when is_atom(key) do
    %{source: :command, command: "stub-keyring", args: [Atom.to_string(key)]}
  end

  # Mirror the real writers: secrets are namespaced by profile so tests observe
  # the profile being threaded end-to-end (a dropped `profile:` would collide).
  defp profile(opts), do: Keyword.get(opts, :profile) || "general"

  def reset do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, read_concurrency: true])
        rescue
          ArgumentError -> @table
        end

      _tid ->
        @table
    end
  end
end

defmodule FermixTestSupport.UnavailableSecretWriter do
  @moduledoc false

  @behaviour FermixCore.Setup.SecretWriter

  @impl true
  def available?(_opts \\ []), do: false

  @impl true
  def put(_key, _value, _opts \\ []), do: {:error, :unavailable}

  @impl true
  def get(_key, _opts \\ []), do: {:error, :unavailable}

  @impl true
  def command_source(_key, _opts \\ []), do: %{source: :command, command: "", args: []}
end
