defmodule FermixCore.Tools.MemorySupport do
  @moduledoc """
  What the memory tools share: the `Memory.LongTerm` context a tool call runs
  under, and the words a refusal or a receipt is reported in.
  """

  alias FermixCore.Agents.MainAgent
  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Memory.Admission
  alias FermixCore.Memory.Config
  alias FermixCore.Memory.LongTerm
  alias FermixCore.Memory.Repo

  @spec long_term_context(Tool.context()) :: LongTerm.context()
  def long_term_context(context) when is_map(context) do
    %{
      agent_id: Map.get(context, :memory_agent_id) || Config.agent_id(),
      owner_id: Map.get(context, :memory_owner_id) || Config.owner_id(),
      repo: Map.get(context, :memory_repo) || Repo,
      source_trust: Map.get(context, :source_trust),
      main_agent_server: Map.get(context, :main_agent_server) || MainAgent
    }
  end

  @doc "A row id as the model sent it: an integer, or digits in a string."
  @spec parse_id(term()) :: {:ok, pos_integer()} | :error
  def parse_id(id) when is_integer(id) and id > 0, do: {:ok, id}

  def parse_id(id) when is_binary(id) do
    case Integer.parse(String.trim(id)) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _invalid -> :error
    end
  end

  def parse_id(_id), do: :error

  @doc "What became of the prompt files after a write, as the model is told it."
  @spec published_note(LongTerm.receipt()) :: String.t()
  def published_note(%{published: :ok}),
    do: " The prompt shows the change from the next turn, in every conversation."

  def published_note(%{published: :not_shown}), do: ""

  def published_note(%{published: {:error, reason}}) do
    " It is saved, but the prompt files could not be rebuilt (#{inspect(reason)}), " <>
      "so the prompt does not show the change yet."
  end

  @spec refusal(LongTerm.refusal() | term()) :: String.t()
  def refusal(:disabled), do: "Durable memory is turned off; nothing was changed."

  def refusal(:not_found),
    do: "No memory has that id. Find the id with memory_recall (search, scope all)."

  def refusal(:blank_key), do: "key must not be empty."
  def refusal(:blank_value), do: "value must not be empty."

  def refusal({:invalid_category, category}) do
    "Unknown category #{inspect(category)}. Use one of: " <>
      Enum.join(Admission.categories(), ", ") <> "."
  end

  def refusal({:category_not_allowed, category}),
    do: "This caller may not save #{category} memories."

  def refusal({:not_editable, category}),
    do: "A #{category} memory is not one these tools may change."

  def refusal({:value_too_long, length, max}) do
    "A long-term memory is one short sentence, #{max} characters at most; this one is " <>
      "#{length}. Shorten it and save again."
  end

  def refusal(reason), do: "The memory store rejected the change: #{inspect(reason)}"
end
