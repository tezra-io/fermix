defmodule FermixCore.ComputerUse.Approval do
  @moduledoc """
  In-loop human-in-the-loop confirmation gate for consequential computer-use
  actions (docs/design/COMPUTER_USE.md §7.2).

  A consequential action against a real desktop must be confirmed by a present
  human. `request/3` prompts the owner via their confirm surface and BLOCKS the
  caller until the owner resolves it or the timeout elapses — and it is
  **fail-closed**: a nil/unattended surface, a denial, or a timeout all return an
  error, so the action never proceeds unconfirmed. The owner resolves through
  `resolve/2` (the owner-only channel command or the voice pet), which notifies
  the blocked caller.

  It borrows only the SHAPE of the sandbox confirmation store (a public ETS table
  of pending records keyed by a minted token); the timeout is configurable and far
  longer (a human reads a screenshot and decides), and an absent owner fails closed
  rather than waiting.
  """

  use GenServer

  alias FermixCore.ComputerUse.Config

  @table __MODULE__

  @typedoc "Prompts the owner to confirm `action`; they reply via resolve/2. nil = no owner present (fail-closed)."
  @type surface :: (token :: String.t(), action :: String.t() -> any()) | nil
  @type decision :: :approve | :deny

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Request confirmation for `action` and block until the owner resolves it or the
  `approval_timeout_ms` elapses. Fail-closed on every non-approval outcome.
  """
  @spec request(String.t(), surface(), Config.t()) ::
          :ok | {:error, :no_owner | :denied | :timeout}
  def request(_action, nil, %Config{}), do: {:error, :no_owner}

  def request(action, surface, %Config{approval_timeout_ms: timeout_ms})
      when is_binary(action) and is_function(surface, 2) do
    token = mint_token()
    :ets.insert(@table, {token, %{awaiter: self(), action: action}})

    surface.(token, action)

    receive do
      {__MODULE__, :resolved, ^token, :approve} -> :ok
      {__MODULE__, :resolved, ^token, :deny} -> {:error, :denied}
    after
      timeout_ms ->
        :ets.delete(@table, token)
        {:error, :timeout}
    end
  end

  @doc """
  Resolve a pending approval (owner approved or denied), notifying the blocked
  requester. `{:error, :unknown_token}` if the token is unknown or already
  expired/resolved.
  """
  @spec resolve(String.t(), decision()) :: :ok | {:error, :unknown_token}
  def resolve(token, decision) when is_binary(token) and decision in [:approve, :deny] do
    case :ets.take(@table, token) do
      [{^token, %{awaiter: awaiter}}] ->
        send(awaiter, {__MODULE__, :resolved, token, decision})
        :ok

      [] ->
        {:error, :unknown_token}
    end
  end

  @doc "Outstanding pending tokens — for introspection and tests."
  @spec pending() :: [String.t()]
  def pending, do: :ets.select(@table, [{{:"$1", :_}, [], [:"$1"]}])

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, %{}}
  end

  defp mint_token do
    18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
