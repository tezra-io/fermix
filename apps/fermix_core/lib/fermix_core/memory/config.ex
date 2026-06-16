defmodule FermixCore.Memory.Config do
  @moduledoc """
  Typed accessors for durable memory runtime configuration.
  """

  alias FermixCore.Setup.ConfigStore

  @type options :: keyword()
  @type repo_server :: pid() | atom()

  @prompt_user_token_cap 1500
  @prompt_memory_token_cap 2000
  @extraction_timeout_ms 90_000
  @extraction_context_messages 12
  @extraction_min_confidence 0.75
  @review_interval_hours 24
  @review_max_messages 40
  @review_input_token_budget 4_000
  @review_failure_backoff_ms 300_000
  @compaction_token_budget 8_000
  @loop_detection_window 10
  @loop_detection_warn_threshold 3
  @loop_detection_kill_threshold 5

  @spec enabled?(options()) :: boolean()
  def enabled?(opts \\ []) do
    Keyword.get(opts, :enabled, Keyword.get(memory_config(), :enabled, true))
  end

  @spec extraction_enabled?(options()) :: boolean()
  def extraction_enabled?(opts \\ []) do
    Keyword.get(
      opts,
      :extraction_enabled,
      Keyword.get(memory_config(), :extraction_enabled, enabled?(opts))
    )
  end

  @spec extraction_model(options()) :: String.t() | nil
  def extraction_model(opts \\ []) do
    Keyword.get(opts, :extraction_model, Keyword.get(memory_config(), :extraction_model))
  end

  @spec extraction_timeout_ms(options()) :: pos_integer()
  def extraction_timeout_ms(opts \\ []) do
    opts
    |> Keyword.get(
      :extraction_timeout_ms,
      Keyword.get(memory_config(), :extraction_timeout_ms, @extraction_timeout_ms)
    )
    |> normalize_positive_integer!(:extraction_timeout_ms)
  end

  @spec extraction_context_messages(options()) :: pos_integer()
  def extraction_context_messages(opts \\ []) do
    opts
    |> Keyword.get(
      :extraction_context_messages,
      Keyword.get(
        memory_config(),
        :extraction_context_messages,
        @extraction_context_messages
      )
    )
    |> normalize_positive_integer!(:extraction_context_messages)
  end

  @spec extraction_min_confidence(options()) :: float()
  def extraction_min_confidence(opts \\ []) do
    opts
    |> Keyword.get(
      :extraction_min_confidence,
      Keyword.get(memory_config(), :extraction_min_confidence, @extraction_min_confidence)
    )
    |> normalize_probability!(:extraction_min_confidence)
  end

  @spec database_path(options()) :: String.t()
  def database_path(opts \\ []) do
    opts
    |> Keyword.get(
      :database_path,
      Keyword.get(memory_config(), :database_path, ConfigStore.memory_paths().database_path)
    )
    |> normalize_database_path()
  end

  @spec owner_id(options()) :: String.t()
  def owner_id(opts \\ []) do
    Keyword.get(opts, :owner_id, Keyword.get(memory_config(), :owner_id, "default"))
  end

  @spec agent_id(options()) :: String.t()
  def agent_id(opts \\ []) do
    Keyword.get(opts, :agent_id, Keyword.get(memory_config(), :agent_id, "main"))
  end

  @spec prompt_base_dir(options()) :: String.t()
  def prompt_base_dir(opts \\ []) do
    opts
    |> Keyword.get(
      :prompt_base_dir,
      Keyword.get(memory_config(), :prompt_base_dir, ConfigStore.memory_paths().prompt_base_dir)
    )
    |> Path.expand()
  end

  @spec prompt_user_token_cap(options()) :: pos_integer()
  def prompt_user_token_cap(opts \\ []) do
    opts
    |> Keyword.get(
      :prompt_user_token_cap,
      Keyword.get(memory_config(), :prompt_user_token_cap, @prompt_user_token_cap)
    )
    |> normalize_positive_integer!(:prompt_user_token_cap)
  end

  @spec prompt_memory_token_cap(options()) :: pos_integer()
  def prompt_memory_token_cap(opts \\ []) do
    opts
    |> Keyword.get(
      :prompt_memory_token_cap,
      Keyword.get(memory_config(), :prompt_memory_token_cap, @prompt_memory_token_cap)
    )
    |> normalize_positive_integer!(:prompt_memory_token_cap)
  end

  @spec repo_server(options()) :: repo_server()
  def repo_server(opts \\ []) do
    Keyword.get(opts, :repo, Keyword.get(memory_config(), :repo, FermixCore.Memory.Repo))
  end

  @spec scheduler_enabled?(options()) :: boolean()
  def scheduler_enabled?(opts \\ []) do
    Keyword.get(
      opts,
      :scheduler_enabled,
      Keyword.get(memory_config(), :scheduler_enabled, enabled?(opts))
    )
  end

  @spec review_interval_hours(options()) :: non_neg_integer()
  def review_interval_hours(opts \\ []) do
    opts
    |> Keyword.get(
      :review_interval_hours,
      Keyword.get(memory_config(), :review_interval_hours, @review_interval_hours)
    )
    |> normalize_non_negative_integer!(:review_interval_hours)
  end

  @spec review_max_messages(options()) :: pos_integer()
  def review_max_messages(opts \\ []) do
    opts
    |> Keyword.get(
      :review_max_messages,
      Keyword.get(memory_config(), :review_max_messages, @review_max_messages)
    )
    |> normalize_positive_integer!(:review_max_messages)
  end

  @spec review_input_token_budget(options()) :: pos_integer()
  def review_input_token_budget(opts \\ []) do
    opts
    |> Keyword.get(
      :review_input_token_budget,
      Keyword.get(memory_config(), :review_input_token_budget, @review_input_token_budget)
    )
    |> normalize_positive_integer!(:review_input_token_budget)
  end

  @spec review_failure_backoff_ms(options()) :: non_neg_integer()
  def review_failure_backoff_ms(opts \\ []) do
    opts
    |> Keyword.get(
      :review_failure_backoff_ms,
      Keyword.get(memory_config(), :review_failure_backoff_ms, @review_failure_backoff_ms)
    )
    |> normalize_non_negative_integer!(:review_failure_backoff_ms)
  end

  @spec compaction_enabled?(options()) :: boolean()
  def compaction_enabled?(opts \\ []) do
    Keyword.get(
      opts,
      :compaction_enabled,
      Keyword.get(memory_config(), :compaction_enabled, enabled?(opts))
    )
  end

  @spec compaction_token_budget(options()) :: pos_integer()
  def compaction_token_budget(opts \\ []) do
    opts
    |> Keyword.get(
      :compaction_token_budget,
      Keyword.get(memory_config(), :compaction_token_budget, @compaction_token_budget)
    )
    |> normalize_positive_integer!(:compaction_token_budget)
  end

  @spec checkpoint_persistence_enabled?(options()) :: boolean()
  def checkpoint_persistence_enabled?(opts \\ []) do
    Keyword.get(
      opts,
      :checkpoint_persistence_enabled,
      Keyword.get(memory_config(), :checkpoint_persistence_enabled, true)
    )
  end

  @spec loop_detection_window(options()) :: pos_integer()
  def loop_detection_window(opts \\ []) do
    opts
    |> Keyword.get(
      :loop_detection_window,
      Keyword.get(memory_config(), :loop_detection_window, @loop_detection_window)
    )
    |> normalize_positive_integer!(:loop_detection_window)
  end

  @spec loop_detection_warn_threshold(options()) :: pos_integer()
  def loop_detection_warn_threshold(opts \\ []) do
    opts
    |> Keyword.get(
      :loop_detection_warn_threshold,
      Keyword.get(memory_config(), :loop_detection_warn_threshold, @loop_detection_warn_threshold)
    )
    |> normalize_positive_integer!(:loop_detection_warn_threshold)
  end

  @spec loop_detection_kill_threshold(options()) :: pos_integer()
  def loop_detection_kill_threshold(opts \\ []) do
    opts
    |> Keyword.get(
      :loop_detection_kill_threshold,
      Keyword.get(memory_config(), :loop_detection_kill_threshold, @loop_detection_kill_threshold)
    )
    |> normalize_positive_integer!(:loop_detection_kill_threshold)
  end

  defp memory_config do
    Application.get_env(:fermix_core, :memory, [])
  end

  defp normalize_database_path(":memory"), do: ":memory:"
  defp normalize_database_path(":memory:"), do: ":memory:"
  defp normalize_database_path(path), do: Path.expand(path)

  defp normalize_positive_integer!(value, _key) when is_integer(value) and value > 0, do: value

  defp normalize_positive_integer!(value, key) do
    raise ArgumentError, "#{key} must be a positive integer, got: #{inspect(value)}"
  end

  defp normalize_non_negative_integer!(value, _key) when is_integer(value) and value >= 0,
    do: value

  defp normalize_non_negative_integer!(value, key) do
    raise ArgumentError, "#{key} must be a non-negative integer, got: #{inspect(value)}"
  end

  defp normalize_probability!(value, _key)
       when is_float(value) and value >= 0.0 and value <= 1.0,
       do: value

  defp normalize_probability!(value, _key)
       when is_integer(value) and value >= 0 and value <= 1,
       do: value * 1.0

  defp normalize_probability!(value, key) do
    raise ArgumentError, "#{key} must be between 0.0 and 1.0, got: #{inspect(value)}"
  end
end
