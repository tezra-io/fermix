defmodule FermixCore.Harness.Adapter do
  @moduledoc """
  The per-vendor adapter behaviour: lifecycle plumbing for one coding-harness
  vendor CLI (design §16.3 — "lifecycle plumbing ONLY").

  An adapter turns a vendor-specific `params` map into an executable `plan`
  (binary + argv + cwd + lock roots), classifies the vendor's JSON event stream
  (`terminal?/1`, `extract/1`), and renders the human resume invocation
  (`resume_hint/1`). It does **not** normalize params across vendors: each
  adapter owns and validates its own `params` map alone, because the two CLIs
  expose different flags. Unknown keys and bad enums fail loud.

  ## The plan

  `plan/2` renders argv with two Fermix-owned placeholders that the `Harness.Run`
  substitutes at spawn time, so the plan never carries the full prompt text nor a
  caller-specifiable output path (§8.4):

    * `:prompt` — the LAST positional argument; replaced with the transported
      prompt (inline text or a `brief.md` pointer, `Harness.Prompt`).
    * `:output_file` — the vendor `-o` result-file slot (codex only); replaced
      with a path generated under the run's `artifacts_dir`.

  Every path-bearing param is gated through `FermixCore.Sandbox` here — read
  inputs via `read_path/2`, writable `add_dirs` via `write_path/2` (returned as
  `extra_lock_roots` for admission) — so a denied path is `{:error,
  {:path_denied, key, reason}}` and never reaches an OS spawn.

  The vendor binary is resolved to an absolute path at call time (a stale boot
  registry yields a clean `{:error, :cli_unavailable}`, never a crash). Tests
  inject `:find_executable` in `ctx` to stay hermetic.
  """

  @typedoc "An argv element: a literal string or a Run-substituted placeholder."
  @type argv_part :: String.t() | :prompt | :output_file

  @typedoc """
  An executable plan. `argv` carries `:prompt`/`:output_file` placeholders the
  `Harness.Run` fills; `cwd` is the port working directory; `extra_lock_roots`
  are writable `add_dirs` that admission must also lock; `env_names` is the extra
  `Sandbox.Env` passthrough set beyond the reserved `HOME`/`PATH`/`TERM`.
  """
  @type plan :: %{
          binary: String.t(),
          argv: [argv_part()],
          cwd: String.t(),
          extra_lock_roots: [String.t()],
          resumable: boolean(),
          env_names: [String.t()]
        }

  @doc ~S(The vendor tag: `"codex"` or `"claude"`.)
  @callback vendor() :: String.t()

  @doc """
  Validates `params` and renders the executable plan for `ctx`.

  `ctx` carries the resolved working dir (`:cwd`, validated by the tool layer),
  the sandbox context for path gating, and an optional `:find_executable`
  binary resolver. Fails loud on unknown params, bad enums, denied paths, or a
  missing CLI.
  """
  @callback plan(params :: map(), ctx :: map()) :: {:ok, plan()} | {:error, term()}

  @doc "True when `event` is the vendor's terminal stream event."
  @callback terminal?(event :: map()) :: boolean()

  @doc """
  Harvests correlation/progress fields from one decoded stream event. Returns an
  empty map for events that carry nothing of interest.
  """
  @callback extract(event :: map()) :: %{
              optional(:vendor_session_id) => String.t(),
              optional(:usage) => map(),
              optional(:result_text) => String.t(),
              optional(:phase) => String.t()
            }

  @doc """
  The exact CLI invocation to resume `row`, or `nil` when the run is not
  resumable (ephemeral) or has no persisted vendor session id.
  """
  @callback resume_hint(row :: map()) :: String.t() | nil

  alias FermixCore.Sandbox

  @doc """
  Resolves `name` to an absolute executable path at call time.

  Uses `ctx.find_executable` (default `System.find_executable/1`) so tests stay
  hermetic. A miss is `{:error, :cli_unavailable}` — the caller ledgers a clean
  block, never crashes.
  """
  @spec resolve_binary(String.t(), map()) :: {:ok, String.t()} | {:error, :cli_unavailable}
  def resolve_binary(name, ctx) when is_binary(name) and is_map(ctx) do
    find = Map.get(ctx, :find_executable, &System.find_executable/1)

    case find.(name) do
      path when is_binary(path) and path != "" -> {:ok, path}
      _absent -> {:error, :cli_unavailable}
    end
  end

  @doc """
  Read-gates a path-bearing param value through the sandbox, tagging denials
  with `key` so the failure names the offending param.
  """
  @spec read_path(atom(), String.t(), map()) ::
          {:ok, String.t()} | {:error, {:path_denied, atom(), term()}}
  def read_path(key, path, ctx) when is_atom(key) and is_binary(path) and is_map(ctx) do
    case Sandbox.read_path(path, :harness_input, ctx) do
      {:ok, resolved} -> {:ok, resolved}
      {:error, reason} -> {:error, {:path_denied, key, reason}}
    end
  end

  @doc """
  Write-gates a writable directory param (`add_dirs`) through the sandbox,
  tagging denials with `key`. The resolved path is also an admission lock root.
  """
  @spec write_path(atom(), String.t(), map()) ::
          {:ok, String.t()} | {:error, {:path_denied, atom(), term()}}
  def write_path(key, path, ctx) when is_atom(key) and is_binary(path) and is_map(ctx) do
    case Sandbox.write_path(path, :harness_add_dir, ctx) do
      {:ok, resolved} -> {:ok, resolved}
      {:error, reason} -> {:error, {:path_denied, key, reason}}
    end
  end

  @doc """
  Read-gates each path in `paths` (order preserved), stopping at the first
  denial. Used for repeated read params such as codex `images`.
  """
  @spec read_paths(atom(), [String.t()], map()) ::
          {:ok, [String.t()]}
          | {:error, {:path_denied, atom(), term()} | {:invalid_param, atom()}}
  def read_paths(key, paths, ctx) when is_atom(key) and is_map(ctx) do
    gate_each(key, paths, ctx, &read_path/3)
  end

  @doc """
  Write-gates each directory in `dirs` (order preserved), stopping at the first
  denial. Used for the repeated `add_dirs` param; the resolved list is the
  admission lock-root set.
  """
  @spec write_paths(atom(), [String.t()], map()) ::
          {:ok, [String.t()]}
          | {:error, {:path_denied, atom(), term()} | {:invalid_param, atom()}}
  def write_paths(key, dirs, ctx) when is_atom(key) and is_map(ctx) do
    gate_each(key, dirs, ctx, &write_path/3)
  end

  defp gate_each(key, paths, ctx, gate) when is_list(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      case gate_one(key, path, ctx, gate) do
        {:ok, resolved} -> {:cont, {:ok, [resolved | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, resolved} -> {:ok, Enum.reverse(resolved)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp gate_each(key, _paths, _ctx, _gate), do: {:error, {:invalid_param, key}}

  defp gate_one(key, path, ctx, gate) when is_binary(path) and path != "",
    do: gate.(key, path, ctx)

  defp gate_one(key, _path, _ctx, _gate), do: {:error, {:invalid_param, key}}
end
