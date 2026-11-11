defmodule FermixCore.Computers.Capability do
  @moduledoc """
  One thing the server can ask a computer to do (M97 §6, §6.4): what it is,
  its operations, and how a computer admits and runs one. The computer runs
  it through the same local code a primary runs, with its own settings
  (`FermixChannels.Desktop.Invoke`); the server sends it as an
  `invoke_open` (`FermixCore.Computers.call/6`) and reads its answer back as
  an `Computers.Outcome`.

  Each capability is one module. A computer's capabilities are a map from
  the wire's `capability` to its module (`Desktop.Invoke.capabilities/0`),
  and so are the home's services a computer may ask of its server
  (`Desktop.InvokeFamily`).

  - `id/0`: the capability's name on the wire, `^[a-z][a-z0-9_]{0,31}$`;
  - `offer/0`: the offer its switch is (`Computers.Switches`), or nil for
    one gated by the master switch alone;
  - `ops/0`, and for each op whether it changes something (`effect?/1`,
    never sent twice by the link, `Computers.Outcome`'s `unknown`) and
    whether it may run until cancelled (`long_lived?/1`: `deadline_ms` 0);
  - `validate/2` the args, `bounds/1` the bytes of its answer and its part;
  - `admit/3`, the capability's own rules on this computer (the origin, the
    sandbox's roots), and `run/4`, which does it;
  - `target/2`, a short description of what it acts on (a path, a host or
    an action, at most #{256} bytes), never content: the journal and the
    receipt hold it;
  - optionally `here?/1`, whether the server's own host has it too, which
    `Computers.Choice` reads for a call that names no computer,
    `continues_on/1`, the computer the turn's earlier calls ran on, which
    such a call carries on on, and `deadline_ms/2`, the tool's own timeout
    for an op.

  A capability's code reads this computer's settings from the context it is
  handed (`context/0`), never from application environment, so two engines
  run in one test VM.
  """

  alias FermixCore.Computers.Outcome

  @max_target_bytes 256
  @name ~r/\A[a-z][a-z0-9_]{0,31}\z/
  @op ~r/\A[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)*\z/
  @max_op_bytes 64

  @typedoc """
  What a capability is handed on the computer: the invocation's id, its
  origin, the primary epoch it named, the turn that asked (nil for a
  computer's own request), this computer's home and switches, the clock,
  and the deadline it runs within (0: until cancelled); and this computer's
  sandbox config (`sandbox`, `FermixCore.Sandbox.Config`), which the files and
  shell capabilities run under.
  """
  @type context :: %{
          required(:id) => String.t(),
          required(:origin) => atom(),
          required(:epoch) => pos_integer(),
          required(:turn) => %{session_id: String.t(), tool_call_id: String.t()} | nil,
          required(:home) => Path.t(),
          required(:switches) => keyword(),
          required(:clock) => (-> DateTime.t()),
          required(:deadline_ms) => non_neg_integer(),
          optional(atom()) => term()
        }

  @doc "The capability's name on the wire."
  @callback id() :: atom()

  @doc "The offer whose switch gates it, or nil for the master switch alone."
  @callback offer() :: atom() | nil

  @doc "Its operations."
  @callback ops() :: [String.t()]

  @doc "Whether `op` changes something: never sent twice by the link."
  @callback effect?(String.t()) :: boolean()

  @doc "Whether `op` may run until cancelled (`deadline_ms` 0)."
  @callback long_lived?(String.t()) :: boolean()

  @doc "Whether `args` are what `op` takes, or the sentence that says what is wrong."
  @callback validate(String.t(), map()) :: :ok | {:error, String.t()}

  @doc "The most bytes `op`'s answer and its part may carry."
  @callback bounds(String.t()) :: %{result_bytes: pos_integer(), part_bytes: non_neg_integer()}

  @doc "The capability's own rules on this computer, before anything runs."
  @callback admit(String.t(), map(), context()) ::
              :ok | {:refused, Outcome.refusal(), String.t()}

  @doc """
  Runs `op` with `args` and the part that came with it, on this computer:
  `{:ok, result, part}` when it did what was asked; `{:failed, message}` when
  it could not; `{:failed, message, result, part}` when it ran and failed
  with a result of its own (a tool's error), whose short `message` the
  journal and the server's exec event go by and whose whole result and part
  the answer still carries; or a refusal.
  """
  @callback run(String.t(), map(), binary() | nil, context()) ::
              {:ok, map(), binary() | nil}
              | {:failed, String.t()}
              | {:failed, String.t(), map(), binary() | nil}
              | {:refused, Outcome.refusal(), String.t()}

  @doc "What `op` acts on, in at most #{@max_target_bytes} bytes; never content."
  @callback target(String.t(), map()) :: String.t()

  @doc "Lets go of what the run `pid` holds before it is stopped."
  @callback cancel(String.t(), pid()) :: :ok

  @doc """
  Whether this engine's own host has the capability, for the turn whose loop
  context is given (M97 §6.5: a call that names no computer runs here when it
  does). A capability that does not say is not taken to run here.
  """
  @callback here?(map()) :: boolean()

  @doc """
  The deadline the server gives `op` with `args`: the tool's own timeout and
  the time its sandbox takes to start, at most #{900_000} ms. Without it a
  request waits #{30_000} ms (`Computers.call/6`).
  """
  @callback deadline_ms(String.t(), map()) :: pos_integer()

  @doc """
  The computer (its device id) this turn's earlier calls of the capability
  ran on, which a call that names no computer carries on on, for the turn
  whose loop context is given; nil when none (M97 §6.4: a task in a
  computer's browser is never moved to this server's, silently).
  """
  @callback continues_on(map()) :: String.t() | nil

  @optional_callbacks cancel: 2, here?: 1, deadline_ms: 2, continues_on: 1

  @doc "The most bytes a target holds."
  @spec max_target_bytes() :: pos_integer()
  def max_target_bytes, do: @max_target_bytes

  @doc "The capability's name as the wire carries it."
  @spec wire_id(module()) :: String.t()
  def wire_id(module) when is_atom(module), do: Atom.to_string(module.id())

  @doc "Whether `name` is a capability's name as the wire allows it."
  @spec name?(term()) :: boolean()
  def name?(name), do: is_binary(name) and Regex.match?(@name, name)

  @doc "Whether `op` is an operation's name as the wire allows it."
  @spec op?(term()) :: boolean()
  def op?(op), do: is_binary(op) and byte_size(op) <= @max_op_bytes and Regex.match?(@op, op)

  @doc "Whether `module` runs `op`."
  @spec runs?(module(), String.t()) :: boolean()
  def runs?(module, op) when is_atom(module) and is_binary(op), do: op in module.ops()

  @doc """
  A target cut to at most #{@max_target_bytes} bytes on a character
  boundary, with control characters made spaces.
  """
  @spec bounded_target(String.t()) :: String.t()
  def bounded_target(target) when is_binary(target) do
    target
    |> String.replace_invalid()
    |> String.replace(~r/[\x{0000}-\x{001F}\x{007F}-\x{009F}]/u, " ")
    |> truncate(@max_target_bytes)
  end

  defp truncate(text, max) when byte_size(text) <= max, do: text

  defp truncate(text, max) do
    text
    |> String.graphemes()
    |> Enum.reduce_while("", fn grapheme, acc ->
      if byte_size(acc) + byte_size(grapheme) <= max,
        do: {:cont, acc <> grapheme},
        else: {:halt, acc}
    end)
  end
end
