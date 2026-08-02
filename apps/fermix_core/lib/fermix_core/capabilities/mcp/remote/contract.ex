defmodule FermixCore.Capabilities.MCP.Remote.Contract do
  @moduledoc """
  The signed tool contract, compiled once and enforced on every path (M27 §7.6,
  §7.7, §7.9).

  For a remote MCP plugin the manifest's `tools` block is an **enforcement
  boundary, not a preview**. This module turns the server spec
  `Plugins.Dist.McpSource` materialized into an immutable compiled contract and
  answers four questions with it:

    * which raw upstream names may be looked at at all (`select/2`);
    * whether every selected descriptor still hashes to what was signed
      (`verify/2`), all-or-none;
    * what the agent-facing name and parameter schema are (`final_name/2`,
      `agent_parameters/2`); and
    * what a returned MCP result means (`classify_result/2`).

  Three orderings here are load-bearing:

    * **Raw-name filtering happens before any schema work.** An extra tool the
      server invented is discarded by `select/2` by name; nothing walks, bounds,
      hashes, or compiles its schema, so an unlisted descriptor cannot consume
      unbounded parser work or reach the capability registry.
    * **Bounding happens before hashing.** A selected schema is walked under
      `Limits` node/depth caps first; only then is it canonicalized.
    * **Verification is all-or-none.** One missing or changed descriptor fails
      the whole profile with `:upstream_contract_mismatch`. There is no
      permissive schema fallback and no partial registration — a half-honoured
      contract is exactly what the signed hash exists to prevent.

  The compiled contract is the only thing that follows the invocation path.
  Raw mutable manifest data does not.
  """

  alias FermixCore.Capabilities.MCP.Naming
  alias FermixCore.Capabilities.MCP.Remote.Limits
  alias FermixCore.Plugins.CanonicalJson

  @credential_scopes %{"read" => :read, "write" => :write}
  @result_contract_kinds %{"json_boolean" => :json_boolean}

  # The MCP content block forms this rail reviewed for v1. Binary blobs, base64
  # media, audio/image blocks, and embedded resources are refused outright: an
  # allowlisted tool may return bounded metadata or URLs, never inline media.
  @reviewed_content_types ~w(text)

  @max_schema_depth Limits.max_schema_depth()
  @max_status_class_bytes 48

  @type source_id :: {atom(), String.t()}

  @type tool_policy :: %{
          name: String.t(),
          read_only: boolean(),
          replay_safe: boolean(),
          credential_scope: :read | :write,
          descriptor_sha256: String.t(),
          collection_policy: map() | nil,
          argument_guards: [map()]
        }

  @type t :: %{
          source_id: source_id(),
          plugin: String.t() | nil,
          server_name: String.t(),
          selected_profile: String.t(),
          name_mode: :prefix | :preserve,
          name_prefix: String.t() | nil,
          resource_scope: %{kind: atom(), argument: String.t(), id: String.t()},
          tools: %{String.t() => tool_policy()},
          budgets: %{turn_calls: pos_integer(), turn_paginated_calls: pos_integer()},
          result_contract: map()
        }

  @type verified :: %{
          name: String.t(),
          final_name: String.t(),
          description: String.t(),
          parameters: map(),
          policy: tool_policy()
        }

  @doc "True when the spec describes the remote (Streamable HTTP) rail."
  @spec remote?(map()) :: boolean()
  def remote?(spec) when is_map(spec), do: Map.get(spec, :transport) == :streamable_http

  @doc """
  Compile a server spec into the immutable contract.

  Every field is required. A remote spec missing its signed `budgets`,
  `result_contract`, `allowed_tools`, `resource_scope`, `selected_profile`, or
  `name_mode` is not a spec with defaults to fill in — it is an invalid install,
  and it is refused with `:invalid_remote_config` rather than started with a
  weaker contract than the one that was signed.
  """
  @spec compile(map()) :: {:ok, t()} | {:error, term()}
  def compile(spec) when is_map(spec) do
    with {:ok, source_id} <- fetch_source_id(spec),
         {:ok, profile} <- fetch_string(spec, :selected_profile),
         {:ok, name_mode} <- fetch_name_mode(spec),
         {:ok, scope} <- fetch_resource_scope(spec),
         {:ok, tools} <- compile_tools(spec),
         {:ok, budgets} <- compile_budgets(spec),
         {:ok, result_contract} <- compile_result_contract(spec) do
      {:ok,
       %{
         source_id: source_id,
         plugin: plugin_of(source_id),
         server_name: elem(source_id, 1),
         selected_profile: profile,
         name_mode: name_mode,
         name_prefix: name_prefix(source_id),
         resource_scope: scope,
         tools: tools,
         budgets: budgets,
         result_contract: result_contract
       }}
    end
  end

  @doc """
  Keep only the descriptors the selected profile signed, matched on the **raw
  upstream name**, and prove the profile is complete.

  This runs before anything looks at a schema. An extra tool is dropped here; a
  missing one fails the whole profile.
  """
  @spec select(t(), [map()]) :: {:ok, [map()]} | {:error, term()}
  def select(contract, descriptors) when is_map(contract) and is_list(descriptors) do
    selected = Enum.filter(descriptors, &allowed_raw?(contract, &1))

    with :ok <- refuse_duplicates(selected),
         :ok <- require_complete(contract, selected) do
      {:ok, selected}
    end
  end

  @doc """
  Verify every selected descriptor against its signed `descriptor_sha256` and
  build the registrable view.

  All-or-none: the first missing or changed descriptor returns
  `{:error, {:upstream_contract_mismatch, detail}}` and nothing registers.
  """
  @spec verify(t(), [map()]) :: {:ok, [verified()]} | {:error, term()}
  def verify(contract, descriptors) when is_map(contract) and is_list(descriptors) do
    descriptors
    |> Enum.reduce_while({:ok, []}, fn descriptor, {:ok, acc} ->
      case verify_one(contract, descriptor) do
        {:ok, verified} -> {:cont, {:ok, [verified | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The agent-facing capability name for one raw upstream name.

  `:preserve` keeps the exact upstream name and additionally requires the
  `<plugin>_` namespace, so a preserved name can never squat on another
  plugin's surface. `:prefix` keeps the existing sanitizing behaviour.
  """
  @spec final_name(t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def final_name(%{name_mode: :preserve} = contract, raw) when is_binary(raw) do
    with :ok <- require_plugin_namespace(contract, raw),
         :ok <- Naming.validate_name(raw) do
      {:ok, raw}
    end
  end

  def final_name(%{name_mode: :prefix} = contract, raw) when is_binary(raw) do
    {:ok, Naming.candidate(contract.server_name, raw, prefix: contract.name_prefix)}
  rescue
    error in ArgumentError -> {:error, {:invalid_capability_name, Exception.message(error)}}
  end

  @doc """
  The parameter schema the agent sees: the live schema with the
  operator-selected resource-scope field removed.

  The model must not be able to name a workspace at all — the proxy injects the
  selected one. Removing the field from the advertised schema and rejecting a
  supplied value are two halves of the same boundary.
  """
  @spec agent_parameters(t(), map()) :: map()
  def agent_parameters(contract, schema) when is_map(schema) do
    argument = contract.resource_scope.argument

    schema
    |> drop_property(argument)
    |> drop_required(argument)
  end

  @doc """
  Classify one `tools/call` result into the tool result, using the signed
  `result_contract`.

  Three rules, in order:

    * a protocol `isError: true` is an error **whatever the body says** — a
      successful JSON-RPC envelope is not a successful tool call;
    * only reviewed content forms decode. An image/audio/resource/blob block is
      `:unsupported_content`, not a best-effort text extraction; and
    * the signed contract applies to a body that carries its `success_field`:
      `{ok: false}` is an error even when `isError` is absent.

  Errors carry a redacted **class** only. No body, no reason, and no
  `inspect(limit: :infinity)` ever leaves this function.
  """
  @spec classify_result(t(), term()) ::
          {:ok, String.t()}
          | {:error, {:remote_tool_error, String.t()}}
          | {:error, {:invalid_remote_result, atom()}}
  def classify_result(contract, result) when is_map(contract) do
    with {:ok, text} <- reviewed_text(result) do
      apply_result_contract(contract, result, text)
    end
  end

  # --- compile -----------------------------------------------------------

  defp fetch_source_id(%{source_id: {kind, name} = source_id})
       when is_atom(kind) and is_binary(name) and name != "",
       do: {:ok, source_id}

  defp fetch_source_id(_spec), do: {:error, {:invalid_remote_config, :source_id}}

  defp fetch_string(spec, key) do
    case Map.get(spec, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, {:invalid_remote_config, key}}
    end
  end

  defp fetch_name_mode(%{name_mode: mode}) when mode in [:prefix, :preserve], do: {:ok, mode}
  defp fetch_name_mode(_spec), do: {:error, {:invalid_remote_config, :name_mode}}

  defp fetch_resource_scope(%{resource_scope: %{kind: kind, argument: argument, id: id}})
       when is_atom(kind) and is_binary(argument) and argument != "" and is_binary(id) and
              id != "",
       do: {:ok, %{kind: kind, argument: argument, id: id}}

  defp fetch_resource_scope(_spec), do: {:error, {:invalid_remote_config, :resource_scope}}

  defp compile_tools(%{allowed_tools: tools}) when is_map(tools) and map_size(tools) > 0 do
    tools
    |> Enum.reduce_while({:ok, %{}}, fn {name, facts}, {:ok, acc} ->
      case compile_tool(name, facts) do
        {:ok, policy} -> {:cont, {:ok, Map.put(acc, name, policy)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp compile_tools(_spec), do: {:error, {:invalid_remote_config, :allowed_tools}}

  defp compile_tool(name, facts) when is_binary(name) and is_map(facts) do
    with :ok <- require_boolean(facts, :read_only, name),
         :ok <- require_boolean(facts, :replay_safe, name),
         {:ok, scope} <- credential_scope(facts, name),
         {:ok, digest} <- descriptor_sha256(facts, name),
         {:ok, policy} <- collection_policy(facts, name),
         {:ok, guards} <- argument_guards(facts, name) do
      {:ok,
       %{
         name: name,
         read_only: Map.fetch!(facts, :read_only),
         replay_safe: Map.fetch!(facts, :replay_safe),
         credential_scope: scope,
         descriptor_sha256: digest,
         collection_policy: policy,
         argument_guards: guards
       }}
    end
  end

  defp compile_tool(name, _facts), do: {:error, {:invalid_remote_config, {:tool_facts, name}}}

  defp require_boolean(facts, key, name) do
    if is_boolean(Map.get(facts, key)),
      do: :ok,
      else: {:error, {:invalid_remote_config, {key, name}}}
  end

  defp credential_scope(facts, name) do
    case Map.get(@credential_scopes, Map.get(facts, :required_credential_scope)) do
      nil -> {:error, {:invalid_remote_config, {:required_credential_scope, name}}}
      scope -> {:ok, scope}
    end
  end

  defp descriptor_sha256(facts, name) do
    case Map.get(facts, :descriptor_sha256) do
      digest when is_binary(digest) and byte_size(digest) == 64 -> {:ok, digest}
      _invalid -> {:error, {:invalid_remote_config, {:descriptor_sha256, name}}}
    end
  end

  # A tool that returns no collection carries no collection policy; that is a
  # signed state, not a missing one.
  defp collection_policy(facts, name) do
    case Map.get(facts, :collection_policy) do
      nil -> {:ok, nil}
      %{} = policy -> validate_collection_policy(policy, name)
      _invalid -> {:error, {:invalid_remote_config, {:collection_policy, name}}}
    end
  end

  defp validate_collection_policy(policy, name) do
    limit = Map.get(policy, "default_limit")
    max_items = Map.get(policy, "max_returned_items")

    if positive_integer?(limit) and positive_integer?(max_items) and
         is_binary(Map.get(policy, "request_limit_pointer")) and
         is_binary(Map.get(policy, "result_items_pointer")),
       do: {:ok, policy},
       else: {:error, {:invalid_remote_config, {:collection_policy, name}}}
  end

  defp argument_guards(facts, name) do
    case Map.get(facts, :argument_guards, []) do
      guards when is_list(guards) -> validate_guards(guards, name)
      _invalid -> {:error, {:invalid_remote_config, {:argument_guards, name}}}
    end
  end

  defp validate_guards(guards, name) do
    if Enum.all?(guards, &valid_guard?/1),
      do: {:ok, guards},
      else: {:error, {:invalid_remote_config, {:argument_guards, name}}}
  end

  defp valid_guard?(%{"pointer" => pointer, "kind" => kind, "max_items" => max_items}),
    do: is_binary(pointer) and is_binary(kind) and positive_integer?(max_items)

  defp valid_guard?(_guard), do: false

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp compile_budgets(%{budgets: %{} = budgets}) do
    calls = Map.get(budgets, "agent_turn_calls")
    paginated = Map.get(budgets, "agent_turn_paginated_calls")

    if positive_integer?(calls) and positive_integer?(paginated) and paginated <= calls,
      do: {:ok, %{turn_calls: calls, turn_paginated_calls: paginated}},
      else: {:error, {:invalid_remote_config, :budgets}}
  end

  defp compile_budgets(_spec), do: {:error, {:invalid_remote_config, :budgets}}

  defp compile_result_contract(%{result_contract: %{} = contract}) do
    kind = Map.get(@result_contract_kinds, Map.get(contract, "kind"))
    fields = ["success_field", "status_field", "message_field"]
    values = Enum.map(fields, &Map.get(contract, &1))

    if kind && Enum.all?(values, &(is_binary(&1) and &1 != "")) do
      [success, status, message] = values
      {:ok, %{kind: kind, success_field: success, status_field: status, message_field: message}}
    else
      {:error, {:invalid_remote_config, :result_contract}}
    end
  end

  defp compile_result_contract(_spec), do: {:error, {:invalid_remote_config, :result_contract}}

  defp plugin_of({:plugin, name}), do: name
  defp plugin_of({_kind, _name}), do: nil

  defp name_prefix({:plugin, name}), do: name <> "_"
  defp name_prefix({_kind, _name}), do: nil

  # --- selection ---------------------------------------------------------

  defp allowed_raw?(contract, %{name: name}) when is_binary(name),
    do: Map.has_key?(contract.tools, name)

  defp allowed_raw?(_contract, _descriptor), do: false

  defp refuse_duplicates(selected) do
    names = Enum.map(selected, & &1.name)

    case names -- Enum.uniq(names) do
      [] -> :ok
      [name | _rest] -> {:error, {:upstream_contract_mismatch, {:duplicate_tool, name}}}
    end
  end

  defp require_complete(contract, selected) do
    present = MapSet.new(selected, & &1.name)

    case contract.tools
         |> Map.keys()
         |> Enum.reject(&MapSet.member?(present, &1))
         |> Enum.sort() do
      [] -> :ok
      [name | _rest] -> {:error, {:upstream_contract_mismatch, {:missing_tool, name}}}
    end
  end

  # --- verification ------------------------------------------------------

  defp verify_one(contract, descriptor) do
    name = descriptor.name
    policy = Map.fetch!(contract.tools, name)
    input = Map.get(descriptor, :input_schema)

    with :ok <- require_object(input, name),
         :ok <- bound_schema(input, name),
         {:ok, digest} <- digest(descriptor, name, input),
         :ok <- match_digest(digest, policy, name),
         {:ok, final} <- final_name(contract, name) do
      {:ok,
       %{
         name: name,
         final_name: final,
         description: Map.get(descriptor, :description) || "",
         parameters: agent_parameters(contract, input),
         policy: policy
       }}
    end
  end

  defp require_object(schema, _name) when is_map(schema), do: :ok

  defp require_object(_schema, name),
    do: {:error, {:upstream_contract_mismatch, {:invalid_schema, name}}}

  defp digest(descriptor, name, input) do
    case CanonicalJson.descriptor_digest(
           name,
           input,
           Map.get(descriptor, :output_schema),
           Map.get(descriptor, :annotations)
         ) do
      {:ok, digest} -> {:ok, digest}
      {:error, _reason} -> {:error, {:upstream_contract_mismatch, {:uncanonicalizable, name}}}
    end
  end

  defp match_digest(digest, %{descriptor_sha256: digest}, _name), do: :ok

  defp match_digest(_digest, _policy, name),
    do: {:error, {:upstream_contract_mismatch, {:descriptor_changed, name}}}

  # A selected schema is still attacker-influenced input. Bound its node count
  # and depth before canonicalizing it, so a pathological but allowlisted
  # descriptor cannot turn into unbounded parser work either.
  defp bound_schema(schema, name) do
    case walk_schema(schema, 1, 0) do
      {:ok, _nodes} -> :ok
      {:error, class} -> {:error, {:upstream_contract_mismatch, {class, name}}}
    end
  end

  defp walk_schema(_node, depth, _nodes) when depth > @max_schema_depth,
    do: {:error, :schema_too_deep}

  defp walk_schema(node, depth, nodes) when is_map(node) do
    walk_children(Map.values(node), depth, nodes + 1)
  end

  defp walk_schema(node, depth, nodes) when is_list(node) do
    walk_children(node, depth, nodes + 1)
  end

  defp walk_schema(_leaf, _depth, nodes), do: {:ok, nodes + 1}

  defp walk_children(children, depth, nodes) do
    Enum.reduce_while(children, {:ok, nodes}, fn child, {:ok, acc} ->
      if acc > Limits.max_schema_nodes(),
        do: {:halt, {:error, :schema_too_large}},
        else: continue_walk(child, depth, acc)
    end)
  end

  defp continue_walk(child, depth, acc) do
    case walk_schema(child, depth + 1, acc) do
      {:ok, nodes} -> {:cont, {:ok, nodes}}
      {:error, class} -> {:halt, {:error, class}}
    end
  end

  defp require_plugin_namespace(%{plugin: plugin} = _contract, raw) when is_binary(plugin) do
    if String.starts_with?(raw, plugin <> "_"),
      do: :ok,
      else: {:error, {:upstream_contract_mismatch, {:name_outside_namespace, raw}}}
  end

  defp require_plugin_namespace(_contract, raw),
    do: {:error, {:invalid_remote_config, {:preserve_requires_plugin, raw}}}

  defp drop_property(%{"properties" => properties} = schema, argument) when is_map(properties),
    do: Map.put(schema, "properties", Map.delete(properties, argument))

  defp drop_property(schema, _argument), do: schema

  defp drop_required(%{"required" => required} = schema, argument) when is_list(required),
    do: Map.put(schema, "required", Enum.reject(required, &(&1 == argument)))

  defp drop_required(schema, _argument), do: schema

  # --- result classification --------------------------------------------

  defp reviewed_text(%{"content" => content}) when is_list(content) do
    content
    |> Enum.reduce_while({:ok, []}, &reduce_block/2)
    |> case do
      {:ok, chunks} -> bound_text(chunks)
      {:error, class} -> {:error, {:invalid_remote_result, class}}
    end
  end

  defp reviewed_text(result) when is_map(result), do: {:ok, ""}
  defp reviewed_text(_result), do: {:error, {:invalid_remote_result, :not_an_object}}

  defp reduce_block(%{"type" => type, "text" => text}, {:ok, acc})
       when type in @reviewed_content_types and is_binary(text),
       do: {:cont, {:ok, [text | acc]}}

  defp reduce_block(%{"type" => type}, _acc) when is_binary(type),
    do: {:halt, {:error, :unsupported_content}}

  defp reduce_block(_block, _acc), do: {:halt, {:error, :unsupported_content}}

  defp bound_text(chunks) do
    text = chunks |> Enum.reverse() |> Enum.join("\n")

    if byte_size(text) > Limits.max_result_bytes(),
      do: {:error, {:invalid_remote_result, :result_too_large}},
      else: {:ok, text}
  end

  defp apply_result_contract(contract, result, text) do
    body = decode_body(result, text)

    cond do
      Map.get(result, "isError") == true ->
        {:error, {:remote_tool_error, status_class(contract, body)}}

      contract_failure?(contract, body) ->
        {:error, {:remote_tool_error, status_class(contract, body)}}

      true ->
        {:ok, text}
    end
  end

  # `structuredContent` is the reviewed structured form; otherwise the text is
  # decoded when it is JSON. A body that is not JSON is a text result, not a
  # malformed one — the signed contract applies to bodies that carry its field.
  defp decode_body(%{"structuredContent" => %{} = structured}, _text), do: structured

  defp decode_body(_result, text) do
    case Jason.decode(text) do
      {:ok, %{} = decoded} -> decoded
      _not_an_object -> %{}
    end
  end

  defp contract_failure?(%{result_contract: %{kind: :json_boolean} = rc}, body),
    do: Map.get(body, rc.success_field) == false

  defp status_class(%{result_contract: rc}, body) do
    case Map.get(body, rc.status_field) do
      status when is_binary(status) -> safe_class(status)
      _absent -> "unspecified"
    end
  end

  # The status token is a short machine enum (`auth-expired`, `missing-workspace`)
  # and is the one part of an error body that is safe to surface. Anything longer
  # or non-ASCII could carry a message, so it collapses to a class. It stays a
  # BINARY: a server-controlled string turned into an atom is an atom-table leak
  # the peer gets to drive.
  defp safe_class(status) do
    if byte_size(status) <= @max_status_class_bytes and Regex.match?(~r/^[a-z0-9_-]+$/, status),
      do: status,
      else: "unspecified"
  end
end
