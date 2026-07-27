defmodule FermixCore.Harness.Adapters.ClaudeHeadless do
  @moduledoc """
  Claude Code local rail: `claude -p --output-format stream-json` (design §5.2).

  Renders `claude -p --output-format stream-json --verbose [params] <prompt>`,
  spawned in `<cwd>`. Flag names verified against claude 2.1.216 `claude --help`
  (`--append-system-prompt` / `--append-system-prompt-file` / `--max-turns` /
  `--json-schema` are the accepted forms; `--allowed-tools` / `--disallowed-tools`
  take comma-joined names).

  Schema'd params: `model`, `effort`, `permission_mode`, `allowed_tools`,
  `disallowed_tools`, `dangerously_skip_permissions`, `append_system_prompt`
  (string) / `append_system_prompt_file` (sandbox-read path), `add_dirs`,
  `max_turns`, `json_schema`, `resume` / `continue`, `bare`. `--bare` is not
  default: it skips OAuth/keychain and reads `ANTHROPIC_API_KEY` only, so a bare
  run declares that key in its env passthrough set.

  The result and per-model usage arrive on the terminal `result` event (there is
  no `-o` result file), so the plan carries no `:output_file` slot.
  """

  @behaviour FermixCore.Harness.Adapter

  alias FermixCore.Harness.Adapter

  @cli "claude"

  @base_argv ["-p", "--output-format", "stream-json", "--verbose"]

  @effort_levels ~w(low medium high xhigh max)
  @permission_modes ~w(acceptEdits auto bypassPermissions manual dontAsk plan)

  @known_params ~w(model effort permission_mode allowed_tools disallowed_tools
                   dangerously_skip_permissions append_system_prompt append_system_prompt_file
                   add_dirs max_turns json_schema resume continue bare)a

  @impl true
  @spec vendor() :: String.t()
  def vendor, do: "claude"

  @impl true
  @spec plan(map(), map()) :: {:ok, Adapter.plan()} | {:error, term()}
  def plan(params, ctx) when is_map(params) and is_map(ctx) do
    with :ok <- reject_unknown(params),
         :ok <- reject_resume_conflict(params),
         {:ok, cwd} <- fetch_cwd(ctx),
         {:ok, binary} <- Adapter.resolve_binary(@cli, ctx),
         {:ok, opt_args, lock_roots} <- option_args(params, ctx) do
      {:ok,
       %{
         binary: binary,
         argv: @base_argv ++ opt_args ++ [:prompt],
         cwd: cwd,
         extra_lock_roots: lock_roots,
         resumable: true,
         env_names: env_names(params)
       }}
    end
  end

  @impl true
  @spec terminal?(map()) :: boolean()
  def terminal?(%{"type" => "result"}), do: true
  def terminal?(_event), do: false

  @impl true
  @spec extract(map()) :: map()
  def extract(%{"type" => "system", "subtype" => "init", "session_id" => id})
      when is_binary(id),
      do: %{vendor_session_id: id}

  def extract(%{"type" => "result"} = event) do
    %{usage: result_usage(event)}
    |> maybe_put(:result_text, Map.get(event, "result"))
  end

  def extract(%{"type" => "assistant"}), do: %{phase: "assistant"}
  def extract(_event), do: %{}

  @impl true
  @spec resume_hint(map()) :: String.t() | nil
  def resume_hint(row) when is_map(row) do
    case {Map.get(row, :vendor_session_id), Map.get(row, :cwd)} do
      {sid, cwd} when is_binary(sid) and is_binary(cwd) -> "cd #{cwd} && claude --resume #{sid}"
      _incomplete -> nil
    end
  end

  # Rendered in a fixed order for deterministic argv.
  defp option_args(params, ctx) do
    with {:ok, model} <- model_args(params),
         {:ok, effort} <- effort_args(params),
         {:ok, permission} <- permission_args(params),
         {:ok, allowed} <- tool_list_args(params, :allowed_tools, "--allowed-tools"),
         {:ok, disallowed} <- tool_list_args(params, :disallowed_tools, "--disallowed-tools"),
         {:ok, append} <- append_prompt_args(params),
         {:ok, append_file} <- append_prompt_file_args(params, ctx),
         {:ok, add_dirs, lock_roots} <- add_dir_args(params, ctx),
         {:ok, turns} <- max_turns_args(params),
         {:ok, schema} <- json_schema_args(params) do
      flags =
        skip_perm_flag(params) ++
          continue_flag(params) ++ resume_args(params) ++ bare_flag(params)

      {:ok,
       model ++
         effort ++
         permission ++
         allowed ++ disallowed ++ append ++ append_file ++ add_dirs ++ turns ++ schema ++ flags,
       lock_roots}
    end
  end

  defp model_args(%{model: model}) when is_binary(model) and model != "",
    do: {:ok, ["--model", model]}

  defp model_args(%{model: bad}), do: {:error, {:invalid_param, :model, bad}}
  defp model_args(_params), do: {:ok, []}

  defp effort_args(%{effort: effort}) when effort in @effort_levels,
    do: {:ok, ["--effort", effort]}

  defp effort_args(%{effort: bad}), do: {:error, {:invalid_effort, bad}}
  defp effort_args(_params), do: {:ok, []}

  defp permission_args(%{permission_mode: mode}) when mode in @permission_modes,
    do: {:ok, ["--permission-mode", mode]}

  defp permission_args(%{permission_mode: bad}), do: {:error, {:invalid_permission_mode, bad}}
  defp permission_args(_params), do: {:ok, []}

  defp tool_list_args(params, key, flag) do
    case Map.fetch(params, key) do
      :error -> {:ok, []}
      {:ok, tools} -> join_tools(tools, key, flag)
    end
  end

  defp join_tools(tools, _key, flag) when is_list(tools) do
    if Enum.all?(tools, &(is_binary(&1) and &1 != "")) do
      {:ok, [flag, Enum.join(tools, ",")]}
    else
      {:error, {:invalid_param, :tool_list}}
    end
  end

  defp join_tools(_tools, key, _flag), do: {:error, {:invalid_param, key}}

  defp append_prompt_args(%{append_system_prompt: text}) when is_binary(text) and text != "",
    do: {:ok, ["--append-system-prompt", text]}

  defp append_prompt_args(%{append_system_prompt: bad}),
    do: {:error, {:invalid_param, :append_system_prompt, bad}}

  defp append_prompt_args(_params), do: {:ok, []}

  defp append_prompt_file_args(%{append_system_prompt_file: path}, ctx) when is_binary(path) do
    case Adapter.read_path(:append_system_prompt_file, path, ctx) do
      {:ok, resolved} -> {:ok, ["--append-system-prompt-file", resolved]}
      {:error, reason} -> {:error, reason}
    end
  end

  defp append_prompt_file_args(%{append_system_prompt_file: bad}, _ctx),
    do: {:error, {:invalid_param, :append_system_prompt_file, bad}}

  defp append_prompt_file_args(_params, _ctx), do: {:ok, []}

  defp add_dir_args(%{add_dirs: dirs}, ctx) do
    case Adapter.write_paths(:add_dirs, dirs, ctx) do
      {:ok, resolved} -> {:ok, Enum.flat_map(resolved, &["--add-dir", &1]), resolved}
      {:error, reason} -> {:error, reason}
    end
  end

  defp add_dir_args(_params, _ctx), do: {:ok, [], []}

  defp max_turns_args(%{max_turns: turns}) when is_integer(turns) and turns > 0,
    do: {:ok, ["--max-turns", Integer.to_string(turns)]}

  defp max_turns_args(%{max_turns: bad}), do: {:error, {:invalid_param, :max_turns, bad}}
  defp max_turns_args(_params), do: {:ok, []}

  defp json_schema_args(%{json_schema: schema}) when is_binary(schema) and schema != "",
    do: {:ok, ["--json-schema", schema]}

  defp json_schema_args(%{json_schema: schema}) when is_map(schema),
    do: {:ok, ["--json-schema", Jason.encode!(schema)]}

  defp json_schema_args(%{json_schema: bad}), do: {:error, {:invalid_param, :json_schema, bad}}
  defp json_schema_args(_params), do: {:ok, []}

  defp skip_perm_flag(%{dangerously_skip_permissions: true}),
    do: ["--dangerously-skip-permissions"]

  defp skip_perm_flag(_params), do: []

  defp continue_flag(%{continue: true}), do: ["--continue"]
  defp continue_flag(_params), do: []

  defp resume_args(%{resume: sid}) when is_binary(sid) and sid != "", do: ["--resume", sid]
  defp resume_args(_params), do: []

  defp bare_flag(%{bare: true}), do: ["--bare"]
  defp bare_flag(_params), do: []

  # A bare run reads ANTHROPIC_API_KEY only (OAuth/keychain are skipped), so it
  # must pass that key through. A normal run authenticates against the CLI's own
  # credential store — a file under HOME on Linux, but the macOS Keychain item
  # whose account is `$USER` — both of which `Harness.Env` supplies as reserved
  # identity, so no passthrough name is needed.
  defp env_names(%{bare: true}), do: ["ANTHROPIC_API_KEY"]
  defp env_names(_params), do: []

  defp result_usage(event) do
    %{}
    |> maybe_put("total_cost_usd", Map.get(event, "total_cost_usd"))
    |> maybe_put("usage", Map.get(event, "usage"))
    |> maybe_put("modelUsage", Map.get(event, "modelUsage"))
  end

  defp reject_unknown(params) do
    case Enum.find(Map.keys(params), &(&1 not in @known_params)) do
      nil -> :ok
      key -> {:error, {:unknown_param, key}}
    end
  end

  # resume (specific session) and continue (most recent) are mutually exclusive.
  defp reject_resume_conflict(params) do
    if Map.has_key?(params, :resume) and Map.get(params, :continue) == true do
      {:error, :resume_and_continue}
    else
      :ok
    end
  end

  defp fetch_cwd(ctx) do
    case Map.get(ctx, :cwd) do
      cwd when is_binary(cwd) and cwd != "" -> {:ok, cwd}
      _missing -> {:error, :missing_cwd}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
