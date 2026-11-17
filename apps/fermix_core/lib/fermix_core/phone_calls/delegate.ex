defmodule FermixCore.PhoneCalls.Delegate do
  @moduledoc """
  The behaviour for running ONE scoped backend turn for a phone call's
  delegation (M94 §07, "Ask Core when work is needed").

  `fermix_core` never depends on `fermix_channels`, so the implementation is
  injected by module: `config :fermix_core, :phone_calls_delegate, Module`, the
  same app-env module injection `Harness.ContinuationDispatcher` uses, read
  through `configured/0` and nowhere else. The composition root
  (`FermixCore.Application`) hands the module to every call's worker in its
  start args; `PhoneCalls.Readiness` refuses calls while none is configured,
  since a call could then neither press a key nor end through a backend turn.
  A worker started with none answers every delegation with an honest
  limitation and logs it once.

  `PhoneCalls.Call` is the only caller and the authority on what a result may
  do: `run/1` hands one turn over and returns once it is accepted to run; the
  result arrives later as ONE message to `reply_to`:

      {:phone_call_delegation, call_id, delegation_id, revision,
       {:ok, %{reply: String.t(), backend_usage: map() | nil}} | {:error, reason}}

  The worker acts on it only while its call id, delegation id and revision are
  current and the call is not ending, so a late or stale answer cannot speak,
  press a key or reopen anything. `reply` has already passed
  `PhoneCalls.Disclosure`, the one owner of its byte bound (the voice
  session's append limit), and is spoken as given; a reply the check withheld
  is an `{:error, _}`. `cancel/2` is a best-effort stop of a running turn,
  which the worker never waits on; that fencing, not the cancel, is what keeps
  a stale turn out.

  `handle` is minted by the worker for each turn it starts and is never shown
  to a model. The turn's in-call controls (`PhoneCalls.CallControls`) present
  it, and the worker accepts it only while that turn is the call's running
  one.
  """

  alias FermixCore.PhoneCalls.Brief

  @type transcript_entry :: %{
          speaker: :remote | :assistant,
          text: String.t(),
          start_ms: integer() | nil,
          end_ms: integer() | nil
        }

  @type request :: %{
          call_id: String.t(),
          handle: String.t(),
          delegation_id: String.t(),
          revision: pos_integer(),
          brief: Brief.t(),
          window: [transcript_entry()],
          session_id: String.t(),
          deadline_ms: pos_integer(),
          max_steps: pos_integer(),
          reply_to: pid()
        }

  @type result :: {:ok, %{reply: String.t(), backend_usage: map() | nil}} | {:error, term()}

  @doc """
  Starts one scoped backend turn for `request`. `:ok` once it is accepted to
  run; its one result message follows. `{:error, reason}` when it was not
  started, and no message follows.
  """
  @callback run(request()) :: :ok | {:error, term()}

  @doc "Best effort stop of the call's running turn for `delegation_id`."
  @callback cancel(call_id :: String.t(), delegation_id :: String.t()) :: :ok

  @doc """
  The configured implementation: `{:ok, module}` when
  `config :fermix_core, :phone_calls_delegate` names a loaded module that
  exports both callbacks, `{:error, :not_configured}` when it names none, and
  `{:error, {:not_a_delegate, value}}` otherwise.
  """
  @spec configured() :: {:ok, module()} | {:error, :not_configured | {:not_a_delegate, term()}}
  def configured, do: :fermix_core |> Application.get_env(:phone_calls_delegate) |> checked()

  @doc "Whether `module` implements this behaviour: `{:ok, module}` or why not."
  @spec checked(term()) :: {:ok, module()} | {:error, :not_configured | {:not_a_delegate, term()}}
  def checked(nil), do: {:error, :not_configured}

  def checked(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :run, 1) and
         function_exported?(module, :cancel, 2),
       do: {:ok, module},
       else: {:error, {:not_a_delegate, module}}
  end

  def checked(other), do: {:error, {:not_a_delegate, other}}
end
