defmodule FermixCore.Harness.Adapters.CodexExec do
  @moduledoc """
  Codex local rail: `codex exec --json` (design §5.1).

  Renders `codex exec --json --skip-git-repo-check -C <cwd> [params] -o <slot>
  <prompt>` — or, when `resume` is set, `codex exec resume <thread_id> --json
  --skip-git-repo-check [params] -o <slot> <prompt>`. Verified against codex-cli
  0.144.4 `codex exec --help` / `codex exec resume --help`.

  Schema'd params: `model`, `effort` (rendered as the ONE sanctioned `-c
  model_reasoning_effort=<v>`, never raw `-c`), `sandbox`, `add_dirs`,
  `ephemeral`, `profile`, `images`, `output_schema`, `resume`. `ephemeral`
  writes no session files, so it forces `resumable: false` and is rejected with
  `resume`. The `resume` subcommand does not accept `-C`/`-s`/`--add-dir`/`-p`
  (verified), so those params fail loud when combined with `resume` rather than
  being silently dropped.
  """

  @behaviour FermixCore.Harness.Adapter

  alias FermixCore.Harness.Adapter

  @cli "codex"

  # See `head_argv/2`: always rendered, on both the base and resume heads (both
  # accept it, verified).
  @skip_git_repo_check "--skip-git-repo-check"

  # Codex reasoning-effort is a model config override with no fixed CLI enum;
  # sandbox has a documented closed vocabulary.
  @sandbox_modes ~w(read-only workspace-write danger-full-access)

  @known_params ~w(model effort sandbox add_dirs ephemeral profile images output_schema resume)a

  # add_dirs/sandbox/profile have no expression on `codex exec resume`.
  @resume_incompatible ~w(sandbox add_dirs profile)a

  @impl true
  @spec vendor() :: String.t()
  def vendor, do: "codex"

  @impl true
  @spec plan(map(), map()) :: {:ok, Adapter.plan()} | {:error, term()}
  def plan(params, ctx) when is_map(params) and is_map(ctx) do
    with :ok <- reject_unknown(params),
         {:ok, cwd} <- fetch_cwd(ctx),
         {:ok, binary} <- Adapter.resolve_binary(@cli, ctx),
         {:ok, base_argv, resumable} <- head_argv(params, cwd),
         {:ok, opt_args, lock_roots} <- option_args(params, ctx) do
      {:ok,
       %{
         binary: binary,
         argv: base_argv ++ opt_args ++ ["-o", :output_file, :prompt],
         cwd: cwd,
         extra_lock_roots: lock_roots,
         resumable: resumable,
         env_names: []
       }}
    end
  end

  @impl true
  @spec terminal?(map()) :: boolean()
  def terminal?(%{"type" => type}) when type in ["turn.completed", "turn.failed"], do: true
  def terminal?(_event), do: false

  @impl true
  @spec extract(map()) :: map()
  def extract(%{"type" => "thread.started", "thread_id" => id}) when is_binary(id),
    do: %{vendor_session_id: id}

  def extract(%{"type" => "turn.completed", "usage" => usage}) when is_map(usage),
    do: %{usage: usage}

  def extract(%{
        "type" => "item.completed",
        "item" => %{"type" => "agent_message", "text" => text}
      })
      when is_binary(text),
      do: %{result_text: text, phase: "agent_message"}

  def extract(%{"type" => "item." <> _stage, "item" => %{"type" => item_type}})
      when is_binary(item_type),
      do: %{phase: item_type}

  def extract(_event), do: %{}

  @impl true
  @spec resume_hint(map()) :: String.t() | nil
  def resume_hint(row) when is_map(row) do
    case {Map.get(row, :resumable), Map.get(row, :vendor_session_id), Map.get(row, :cwd)} do
      {false, _sid, _cwd} ->
        nil

      {_resumable, sid, cwd} when is_binary(sid) and is_binary(cwd) ->
        "cd #{cwd} && codex exec resume #{sid} --json"

      _incomplete ->
        nil
    end
  end

  # `codex exec [--json -C <cwd>]` vs `codex exec resume <thread_id> --json`, both
  # carrying `--skip-git-repo-check`.
  #
  # The flag is UNCONDITIONAL (design §23.5, owner decision): `codex exec` refuses
  # a non-git cwd ("Not inside a trusted directory…"), which killed every run in a
  # brand-new project in ~250 ms with the cause buried as a bare exit_1. This is
  # not a bypass — the flag exists because codex cannot tell whether a directory is
  # trusted, whereas this cwd has already passed Fermix's sandbox working-dir
  # enforcement (a granted root, or the workspace root under strict mode). That
  # gate always runs before spawn, so there is one code path and no branch.
  defp head_argv(params, cwd) do
    case Map.fetch(params, :resume) do
      :error -> {:ok, base_head(cwd), not Map.get(params, :ephemeral, false)}
      {:ok, thread_id} -> resume_head(params, thread_id)
    end
  end

  defp base_head(cwd), do: ["exec", "--json", @skip_git_repo_check, "-C", cwd]

  defp resume_head(params, thread_id) when is_binary(thread_id) and thread_id != "" do
    cond do
      Map.get(params, :ephemeral, false) ->
        {:error, :ephemeral_not_resumable}

      (conflict = resume_conflict(params)) != nil ->
        {:error, {:param_not_supported_with_resume, conflict}}

      true ->
        {:ok, ["exec", "resume", thread_id, "--json", @skip_git_repo_check], true}
    end
  end

  defp resume_head(_params, _thread_id), do: {:error, {:invalid_param, :resume}}

  defp resume_conflict(params), do: Enum.find(@resume_incompatible, &Map.has_key?(params, &1))

  # Rendered in a fixed order for deterministic argv. `resume` never reaches
  # here as an option (it is consumed by head_argv); the resume-incompatible
  # params were already rejected above, so they are simply absent under resume.
  defp option_args(params, ctx) do
    with {:ok, model} <- model_args(params),
         {:ok, effort} <- effort_args(params),
         {:ok, sandbox} <- sandbox_args(params),
         {:ok, profile} <- profile_args(params),
         {:ok, add_dirs, lock_roots} <- add_dir_args(params, ctx),
         {:ok, images} <- image_args(params, ctx),
         {:ok, schema} <- output_schema_args(params, ctx) do
      ephemeral = if Map.get(params, :ephemeral, false), do: ["--ephemeral"], else: []

      {:ok, model ++ effort ++ sandbox ++ profile ++ add_dirs ++ images ++ schema ++ ephemeral,
       lock_roots}
    end
  end

  defp model_args(%{model: model}) when is_binary(model) and model != "", do: {:ok, ["-m", model]}
  defp model_args(%{model: bad}), do: {:error, {:invalid_param, :model, bad}}
  defp model_args(_params), do: {:ok, []}

  defp effort_args(%{effort: effort}) when is_binary(effort) and effort != "",
    do: {:ok, ["-c", "model_reasoning_effort=" <> effort]}

  defp effort_args(%{effort: bad}), do: {:error, {:invalid_param, :effort, bad}}
  defp effort_args(_params), do: {:ok, []}

  defp sandbox_args(%{sandbox: sandbox}) when sandbox in @sandbox_modes,
    do: {:ok, ["-s", sandbox]}

  defp sandbox_args(%{sandbox: bad}), do: {:error, {:invalid_sandbox, bad}}
  defp sandbox_args(_params), do: {:ok, []}

  defp profile_args(%{profile: profile}) when is_binary(profile) and profile != "",
    do: {:ok, ["-p", profile]}

  defp profile_args(%{profile: bad}), do: {:error, {:invalid_param, :profile, bad}}
  defp profile_args(_params), do: {:ok, []}

  defp add_dir_args(%{add_dirs: dirs}, ctx) do
    case Adapter.write_paths(:add_dirs, dirs, ctx) do
      {:ok, resolved} -> {:ok, Enum.flat_map(resolved, &["--add-dir", &1]), resolved}
      {:error, reason} -> {:error, reason}
    end
  end

  defp add_dir_args(_params, _ctx), do: {:ok, [], []}

  defp image_args(%{images: images}, ctx) do
    case Adapter.read_paths(:images, images, ctx) do
      {:ok, resolved} -> {:ok, Enum.flat_map(resolved, &["-i", &1])}
      {:error, reason} -> {:error, reason}
    end
  end

  defp image_args(_params, _ctx), do: {:ok, []}

  defp output_schema_args(%{output_schema: path}, ctx) when is_binary(path) do
    case Adapter.read_path(:output_schema, path, ctx) do
      {:ok, resolved} -> {:ok, ["--output-schema", resolved]}
      {:error, reason} -> {:error, reason}
    end
  end

  defp output_schema_args(%{output_schema: bad}, _ctx),
    do: {:error, {:invalid_param, :output_schema, bad}}

  defp output_schema_args(_params, _ctx), do: {:ok, []}

  defp reject_unknown(params) do
    case Enum.find(Map.keys(params), &(&1 not in @known_params)) do
      nil -> :ok
      key -> {:error, {:unknown_param, key}}
    end
  end

  defp fetch_cwd(ctx) do
    case Map.get(ctx, :cwd) do
      cwd when is_binary(cwd) and cwd != "" -> {:ok, cwd}
      _missing -> {:error, :missing_cwd}
    end
  end
end
