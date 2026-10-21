defmodule FermixCore.Realtime.GrokTaskCall do
  @moduledoc """
  The one function a Grok call registers, `fermix_task` (M70 §04): how the
  voice hands work to Fermix, cancels it, or replaces it with a corrected
  request.

  Grok plans nothing and runs no tool of its own. Its function call is a
  request, never an authority: the arguments are validated here, the task id
  it may name must be one Fermix minted, and what the task runs with is built
  from the owner's own words on the call's transcript (`CallTasks`), the
  voice model's paraphrase riding beside them labelled as its own. No hosted
  xAI tool is ever registered beside it.

  Every call gets exactly one output, `output/2`: a JSON object the model
  reads as data. A result is the trusted short line Fermix composed, never the
  backend's text rewritten as an instruction.
  """

  @name "fermix_task"

  # Bounds the design fixes (M70 §05): the whole arguments string, and the
  # request inside it.
  @max_arguments_bytes 8_192
  @max_request_bytes 4_096
  @max_task_id_bytes 64

  @statuses ~w(completed failed cancelled superseded busy rejected)

  @type action :: {:submit, String.t(), String.t() | nil} | {:cancel, String.t()}

  @type refusal ::
          :arguments_too_large
          | :invalid_json
          | :not_an_object
          | :unknown_field
          | :unknown_action
          | :missing_request
          | :request_too_large
          | :missing_task_id
          | :invalid_task_id

  @doc "The function's name, as the model calls it."
  @spec name() :: String.t()
  def name, do: @name

  @doc "The function's definition for `session.update`'s `tools`."
  @spec tool() :: map()
  def tool do
    %{
      type: "function",
      name: @name,
      description:
        "Hand a task to Fermix, the owner's agent, which can use the owner's tools, files, " <>
          "accounts and memory. Submit anything that needs a tool, current information, the " <>
          "owner's own records or an action; submit again with a task_id to replace a task " <>
          "with a corrected request; cancel a task the owner wants stopped. The output arrives " <>
          "when the task ends.",
      parameters: %{
        type: "object",
        properties: %{
          action: %{
            type: "string",
            enum: ["submit", "cancel"],
            description: "submit hands over or replaces a task; cancel stops one."
          },
          request: %{
            type: "string",
            description:
              "For submit: what the owner asked for, complete enough to act on, in the " <>
                "owner's own terms."
          },
          task_id: %{
            type: "string",
            description:
              "A task_id from an earlier output of this function: required to cancel, " <>
                "given with submit to replace that task."
          }
        },
        required: ["action"],
        additionalProperties: false
      }
    }
  end

  @doc """
  The validated action in a call's `arguments` (a JSON string), or why it is
  refused. Nothing the model sent beyond the three documented fields is
  accepted, and a task id is only shape-checked here: whether Fermix knows it
  is the session's question.
  """
  @spec parse(String.t()) :: {:ok, action()} | {:error, refusal()}
  def parse(arguments) when is_binary(arguments) do
    with :ok <- within(arguments, @max_arguments_bytes, :arguments_too_large),
         {:ok, fields} <- decode(arguments),
         :ok <- known_fields(fields) do
      action(fields)
    end
  end

  @doc """
  One function output, the JSON string `conversation.item.create` carries.
  `status` is one of #{Enum.join(@statuses, ", ")}; `fields` are the
  task's id and what the model may say (`result`, `message`, `reason`,
  `revision`), each a string or an integer, nils dropped.
  """
  @spec output(String.t(), map()) :: String.t()
  def output(status, fields) when status in @statuses and is_map(fields) do
    fields
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} when is_binary(value) or is_integer(value) -> {key, value} end)
    |> Map.put(:status, status)
    |> Jason.encode!()
  end

  defp decode(arguments) do
    case Jason.decode(arguments) do
      {:ok, %{} = fields} -> {:ok, fields}
      {:ok, _other} -> {:error, :not_an_object}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp known_fields(fields) do
    if Enum.all?(Map.keys(fields), &(&1 in ["action", "request", "task_id"])),
      do: :ok,
      else: {:error, :unknown_field}
  end

  defp action(%{"action" => "submit"} = fields) do
    with {:ok, request} <- request(Map.get(fields, "request")),
         {:ok, task_id} <- optional_task_id(Map.get(fields, "task_id")) do
      {:ok, {:submit, request, task_id}}
    end
  end

  defp action(%{"action" => "cancel"} = fields) do
    case optional_task_id(Map.get(fields, "task_id")) do
      {:ok, nil} -> {:error, :missing_task_id}
      {:ok, task_id} -> {:ok, {:cancel, task_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp action(_fields), do: {:error, :unknown_action}

  defp request(request) when is_binary(request) do
    case String.trim(request) do
      "" ->
        {:error, :missing_request}

      trimmed ->
        with :ok <- within(trimmed, @max_request_bytes, :request_too_large), do: {:ok, trimmed}
    end
  end

  defp request(_absent_or_not_text), do: {:error, :missing_request}

  defp optional_task_id(nil), do: {:ok, nil}

  defp optional_task_id(task_id)
       when is_binary(task_id) and task_id != "" and byte_size(task_id) <= @max_task_id_bytes,
       do: {:ok, task_id}

  defp optional_task_id(_task_id), do: {:error, :invalid_task_id}

  defp within(text, max_bytes, refusal) do
    if byte_size(text) <= max_bytes, do: :ok, else: {:error, refusal}
  end
end
