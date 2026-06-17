defmodule FermixCore.Tools.ModelRoutingConfig do
  @moduledoc """
  Read or update the Fermix routing config section.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Providers.RoutingOverrides
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Tools.Support

  # Sub-agent model routing (docs/design/SUBAGENT_MODEL_SELECTION.md). The cron_*
  # keys are deliberately NOT settable here — they are an unadvertised,
  # config.toml-only provision (they still surface in a `read`).
  @allowed_keys %{
    "subagent_provider" => :subagent_provider,
    "subagent_model" => :subagent_model,
    "subagent_reasoning_effort" => :subagent_reasoning_effort
  }

  @impl true
  def name, do: "model_routing_config"

  @impl true
  def description,
    do: "Read or update the sub-agent model routing keys in [fermix_core.routing] (config.toml)."

  @impl true
  def parameters do
    %{
      type: "object",
      required: ["action"],
      properties: %{
        action: %{type: "string", enum: ["read", "set", "delete"]},
        key: %{
          type: "string",
          enum: ["subagent_provider", "subagent_model", "subagent_reasoning_effort"],
          description:
            "Routing key for set/delete: subagent_provider, subagent_model, or subagent_reasoning_effort."
        },
        value: %{type: "string", description: "Routing value for set."}
      }
    }
  end

  @impl true
  def when_to_use,
    do: "Inspect or set the model/provider/effort that delegated sub-agents use, in config.toml."

  @impl true
  def examples do
    [
      %{args: %{"action" => "read"}, note: "inspect current routing"},
      %{
        args: %{"action" => "set", "key" => "subagent_model", "value" => "gpt-5.4-mini"},
        note: "run sub-agents on a smaller, faster model"
      }
    ]
  end

  @impl true
  def failure_modes do
    [
      %{tag: "invalid_action", description: "action is not read, set, or delete"},
      %{tag: "invalid_key", description: "key is not a supported routing key"},
      %{tag: "write_failed", description: "config.toml write failed"}
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :config

  @impl true
  def execute(args, context) when is_map(args) and is_map(context) do
    Support.run(name(), context, fn -> do_execute(args) end)
  end

  defp do_execute(%{"action" => "read"}) do
    with {:ok, snapshot} <- ConfigStore.load_runtime_config() do
      snapshot
      |> routing()
      |> Enum.into(%{}, fn {key, value} -> {Atom.to_string(key), value} end)
      |> Support.success_json()
    else
      {:error, reason} when is_binary(reason) -> Support.error(reason)
      {:error, reason} -> Support.error(reason)
    end
  end

  defp do_execute(%{"action" => "set"} = args) do
    with {:ok, key} <- fetch_allowed_key(args),
         {:ok, value} <- Support.required_string(args, "value"),
         :ok <- validate_value(key, value),
         {:ok, snapshot} <- ConfigStore.load_runtime_config(),
         next <- put_routing(snapshot, key, value),
         :ok <- ConfigStore.save_snapshot(next),
         :ok <- ConfigStore.apply_snapshot(next) do
      Support.success_json(%{updated: Atom.to_string(key), value: value})
    else
      {:error, reason} when is_binary(reason) -> Support.error(reason)
      {:error, reason} -> Support.error(reason)
    end
  end

  defp do_execute(%{"action" => "delete"} = args) do
    with {:ok, key} <- fetch_allowed_key(args),
         {:ok, snapshot} <- ConfigStore.load_runtime_config(),
         next <- delete_routing(snapshot, key),
         :ok <- ConfigStore.save_snapshot(next),
         :ok <- ConfigStore.apply_snapshot(next) do
      Support.success_json(%{deleted: Atom.to_string(key)})
    else
      {:error, reason} when is_binary(reason) -> Support.error(reason)
      {:error, reason} -> Support.error(reason)
    end
  end

  defp do_execute(%{"action" => action}), do: Support.error("invalid_action: #{action}")
  defp do_execute(_args), do: Support.error("Missing required parameter: action")

  defp fetch_allowed_key(args) do
    with {:ok, key} <- Support.required_string(args, "key"),
         {:ok, atom_key} <- Map.fetch(@allowed_keys, key) do
      {:ok, atom_key}
    else
      :error -> {:error, "invalid_key"}
      {:error, reason} -> {:error, reason}
    end
  end

  # Reuse the consumption-seam validator so a bad provider/effort is rejected at
  # write time, not when a sub-agent later spawns. A free-form model slug always
  # passes (the provider API is the source of truth for an unknown model).
  defp validate_value(key, value) do
    RoutingOverrides.parse([{key, value}], :subagent)
    :ok
  rescue
    e in ArgumentError -> {:error, Exception.message(e)}
  end

  defp routing(snapshot), do: Keyword.get(snapshot.fermix_core, :routing, [])

  defp put_routing(snapshot, key, value) do
    routing = snapshot |> routing() |> Keyword.put(key, value)
    put_in(snapshot, [:fermix_core], Keyword.put(snapshot.fermix_core, :routing, routing))
  end

  defp delete_routing(snapshot, key) do
    routing = snapshot |> routing() |> Keyword.delete(key)
    put_in(snapshot, [:fermix_core], Keyword.put(snapshot.fermix_core, :routing, routing))
  end
end
