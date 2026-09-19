defmodule FermixTestSupport.SecretWriterStub do
  @moduledoc false

  # A `:named_table` dies with the process that created it. When the first
  # caller is a short-lived `Task`, every sibling still holding the name gets an
  # ArgumentError the moment that task exits, so the table is created and held
  # by this process instead — started once, race-safely, for the VM's life.
  defmodule TableOwner do
    @moduledoc false

    use GenServer

    @spec start(atom()) :: {:ok, pid()} | {:error, {:already_started, pid()}}
    def start(table) when is_atom(table) do
      GenServer.start(__MODULE__, table, name: __MODULE__)
    end

    @doc """
    Blocks until the owner has finished `init/1`, i.e. until the table exists.
    A losing racer gets `{:error, {:already_started, pid}}` while the winner is
    still inside `init/1`, and a GenServer serves no call before then.
    """
    @spec await_table(pid()) :: :ok
    def await_table(pid) when is_pid(pid), do: GenServer.call(pid, :await_table)

    @impl true
    def init(table) do
      _tid = :ets.new(table, [:named_table, :public, read_concurrency: true])
      {:ok, table}
    end

    @impl true
    def handle_call(:await_table, _from, table), do: {:reply, :ok, table}
  end

  @behaviour FermixCore.Setup.SecretWriter

  import FermixCore.Setup.SecretWriter, only: [is_secret_key: 1]

  alias FermixCore.Setup.SecretWriter

  @table __MODULE__

  @impl true
  def available?(_opts \\ []), do: true

  @impl true
  def put(key, value, opts \\ []) when is_secret_key(key) and is_binary(value) do
    ensure_table()
    :ets.insert(@table, {{profile(opts), key}, value})
    :ok
  end

  @impl true
  def get(key, opts \\ []) when is_secret_key(key) do
    ensure_table()

    case :ets.lookup(@table, {profile(opts), key}) do
      [{_entry, value}] -> {:ok, value}
      [] -> {:error, :missing_secret}
    end
  end

  # Mirrors the real writers: deleting an absent item succeeds, because the
  # postcondition (no stored value under this key) already holds.
  @impl true
  def delete(key, opts \\ []) when is_secret_key(key) do
    ensure_table()
    :ets.delete(@table, {profile(opts), key})
    :ok
  end

  @impl true
  def command_source(key, opts \\ [])

  def command_source(key, _opts) when is_atom(key) do
    %{source: :command, command: "stub-keyring", args: [Atom.to_string(key)]}
  end

  # A skill's own key names its profile the way the real writers do, so a test
  # can observe that "stored by Fermix" is decided per profile (M45 §4.2).
  def command_source({:external_env, _name} = key, opts) do
    address = "#{SecretWriter.scoped_prefix(opts)}:#{SecretWriter.item_name(key)}"
    %{source: :command, command: "stub-keyring", args: [address]}
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
      :undefined -> start_owner()
      _tid -> @table
    end
  end

  defp start_owner do
    case TableOwner.start(@table) do
      {:ok, _pid} -> @table
      {:error, {:already_started, pid}} -> table_after(TableOwner.await_table(pid))
    end
  end

  defp table_after(:ok), do: @table
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
  def delete(_key, _opts \\ []), do: {:error, :unavailable}

  @impl true
  def command_source(_key, _opts \\ []), do: %{source: :command, command: "", args: []}
end

defmodule FermixTestSupport.CountingSecretWriter do
  @moduledoc """
  A secret writer that reports every read to a watching process.

  Exists so a test can assert that a code path takes NO keychain read at all.
  A stub that merely answers is not enough for that: the assertion has to be
  about calls, not about answers.
  """

  @behaviour FermixCore.Setup.SecretWriter

  import FermixCore.Setup.SecretWriter, only: [is_secret_key: 1]

  alias FermixCore.Setup.SecretWriter

  @observer __MODULE__.Observer

  @doc "Registers the calling process as the one told about every read."
  @spec watch() :: :ok
  def watch do
    Process.register(self(), @observer)
    :ok
  end

  @doc "Stops reporting. Safe to call when no process is registered."
  @spec unwatch() :: :ok
  def unwatch do
    case Process.whereis(@observer) do
      nil -> :ok
      _pid -> unregister()
    end
  end

  @impl true
  def available?(_opts \\ []), do: true

  @impl true
  def put(key, _value, _opts \\ []) when is_secret_key(key), do: :ok

  @impl true
  def get(key, _opts \\ []) when is_secret_key(key) do
    report({:secret_writer_get, key})
    {:error, :missing_secret}
  end

  @impl true
  def delete(key, _opts \\ []) when is_secret_key(key), do: :ok

  @impl true
  def command_source(key, opts \\ [])

  def command_source(key, _opts) when is_atom(key) do
    %{source: :command, command: "counting-keyring", args: [Atom.to_string(key)]}
  end

  def command_source({:external_env, _name} = key, _opts) do
    %{source: :command, command: "counting-keyring", args: [SecretWriter.item_name(key)]}
  end

  defp report(message) do
    case Process.whereis(@observer) do
      nil -> :ok
      pid -> send(pid, message)
    end
  end

  defp unregister do
    Process.unregister(@observer)
    :ok
  end
end

defmodule FermixTestSupport.TreeLessSecretWriter do
  @moduledoc """
  The keychain as a tree-less `fermix` verb meets it: no command host exists.

  `FermixCore.Application.cli_dispatch/2` runs most verbs without the
  supervision tree, so an installed binary has no
  `FermixCore.CommandHost.Supervisor` while such a verb runs, and `mix test`
  always has one. This writer puts a test in the verb's world. Like the real
  writers it sends every keychain call through `CommandRunner.run/3` carrying
  only the caller's own `:supervised` option, but aims it at a supervisor that
  is never started. A call that did not say `supervised: false` therefore raises
  the error an installed binary raises, before any process spawns. A call that
  did runs `true` inline and is then answered by `SecretWriterStub`, so nothing
  a test does through this writer reaches a real keychain.

  `watch/0` registers the calling process to be told
  `{:tree_less_keychain, op, key}` after every call that ran, whichever process
  made it: the keychain reads of an apply run in tasks. The registration ends
  with the process that made it.
  """

  @behaviour FermixCore.Setup.SecretWriter

  import FermixCore.Setup.SecretWriter, only: [is_secret_key: 1]

  alias FermixCore.CommandRunner
  alias FermixTestSupport.SecretWriterStub

  @observer __MODULE__.Observer
  # Nothing ever starts a process under this name: it is the absent host.
  @absent_command_host __MODULE__.AbsentCommandHostSupervisor

  @doc "Registers the calling process as the one told about every call that ran."
  @spec watch() :: :ok
  def watch do
    Process.register(self(), @observer)
    :ok
  end

  @impl true
  def available?(opts \\ []), do: SecretWriterStub.available?(opts)

  @impl true
  def put(key, value, opts \\ []) when is_secret_key(key) and is_binary(value) do
    :ok = run_helper(:put, key, opts)
    SecretWriterStub.put(key, value, opts)
  end

  @impl true
  def get(key, opts \\ []) when is_secret_key(key) do
    :ok = run_helper(:get, key, opts)
    SecretWriterStub.get(key, opts)
  end

  @impl true
  def delete(key, opts \\ []) when is_secret_key(key) do
    :ok = run_helper(:delete, key, opts)
    SecretWriterStub.delete(key, opts)
  end

  @impl true
  def command_source(key, opts \\ []) when is_secret_key(key),
    do: SecretWriterStub.command_source(key, opts)

  defp run_helper(op, key, opts) do
    run_opts = Keyword.take(opts, [:supervised]) ++ [dynamic_supervisor: @absent_command_host]
    {:ok, %{exit: 0}} = CommandRunner.run(true_executable(), [], run_opts)
    report({:tree_less_keychain, op, key})
  end

  defp true_executable do
    System.find_executable("true") || raise "the tree-less secret writer needs `true` on PATH"
  end

  defp report(message) do
    case Process.whereis(@observer) do
      nil -> :ok
      pid -> send(pid, message)
    end

    :ok
  end
end
