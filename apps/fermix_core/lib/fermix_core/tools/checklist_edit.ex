defmodule FermixCore.Tools.ChecklistEdit do
  @moduledoc """
  Change the owner's lists (MILESTONE_85 §05): one call holds a change per
  list, each with its ops by row number, and `Checklists.Registry` applies the
  whole call in one transaction, at most 8 lists and 100 ops, or none of it.
  The answer is one line per list of what changed and its new counts, never
  the whole list.

  After outside content an add or a check still lands, its row stamped, and
  every other op, a create included, is refused (`Checklists.Ops`).
  A stamped row's words come back framed in the answer, which brings the turn
  an outside source, as a read does.

  Offered and run only where `Checklists.Access.permitted?/2` admits it. Every
  list the call touched is recorded for the reply's block with the rows it
  added or changed (`ReplyBlocks.put_checklists/3`).

  Context seams: `:memory_repo`, `:reply_blocks` and `:now_fn`.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Checklists.Access
  alias FermixCore.Checklists.Registry
  alias FermixCore.Memory.Repo
  alias FermixCore.ReplyBlocks
  alias FermixCore.Telemetry
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

  @impl true
  @spec name() :: String.t()
  def name, do: "checklist_edit"

  @impl true
  @spec description() :: String.t()
  def description do
    "Change the owner's lists, only as the owner asks. One call holds every change, a list " <>
      "each with its ops, and lands whole or not at all. Rows are named by their [n] from " <>
      "checklist_read; an add needs none."
  end

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      type: "object",
      required: ["changes"],
      properties: %{
        changes: %{
          type: "array",
          maxItems: Registry.max_changes(),
          items: %{
            type: "object",
            required: ["list", "ops"],
            properties: %{
              list: %{type: "string", description: "Title or id; a created list's title."},
              ops: %{type: "array", items: op_schema()}
            }
          }
        }
      }
    }
  end

  defp op_schema do
    %{
      type: "object",
      required: ["op"],
      properties: %{
        op: %{
          type: "string",
          enum: Registry.ops(),
          description:
            "create (first op; folder?) makes the list. add (text, note?, section? or after?). " <>
              "check, uncheck, remove (n). edit (n, text?, note?; \"\" clears). move (n, " <>
              "section?, after?, to_list?). section (text, after?). folder (folder; none takes " <>
              "it out). rename (text). remove_list. replace (markdown, rev): a line with [n] " <>
              "keeps that row, one without is new, a missing number is removed."
        },
        n: %{type: "integer"},
        text: %{type: "string"},
        note: %{type: "string"},
        section: %{type: "string", description: "A section's name."},
        after: %{type: "integer", description: "The [n] to put it after."},
        to_list: %{type: "string"},
        folder: %{type: "string"},
        markdown: %{type: "string"},
        rev: %{type: "integer", description: "The rev it was read at."}
      }
    }
  end

  @impl true
  def when_to_use, do: "Change the owner's lists: add, tick, edit, move or remove their rows."

  @impl true
  def examples do
    [
      %{
        args: %{
          "changes" => [
            %{"list" => "Fermix", "ops" => [%{"op" => "check", "n" => 4}]},
            %{"list" => "Groceries", "ops" => [%{"op" => "add", "text" => "Lemons"}]}
          ]
        },
        note: "a tick in one list and an item for another, in one call"
      }
    ]
  end

  @impl true
  def failure_modes do
    [
      %{tag: "no_list", description: "no live list has that title or id"},
      %{tag: "no_row", description: "the list has no row with that number"},
      %{tag: "no_section", description: "the list has no section of that name"},
      %{tag: "stale", description: "a replace's rev is behind the list's"},
      %{
        tag: "outside_content",
        description: "an op other than add or check after outside content"
      },
      %{tag: "list_full", description: "the list holds 500 rows"},
      %{tag: "too_many_lists", description: "the owner keeps 50 lists"},
      %{
        tag: "not_permitted",
        description: "not the owner's private turn, and not a job naming it"
      }
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :scheduling

  @doc "Offered where `Checklists.Access.permitted?/2` admits it; `execute/2` asks again."
  @spec advertise?(map()) :: boolean()
  def advertise?(context) when is_map(context), do: Access.permitted?(context, name())

  @impl true
  @spec execute(map(), Tool.context()) :: {:ok, Tool.tool_result()}
  def execute(args, context) when is_map(args) and is_map(context) do
    start = System.monotonic_time(:millisecond)
    {result, error} = edit(args, context)
    duration = System.monotonic_time(:millisecond) - start
    success = match?({:ok, %{success: true}}, result)

    ToolTelemetry.exec(name(), context, success, duration,
      input: args,
      result: result,
      metadata: error
    )

    result
  end

  defp edit(args, context) do
    opts = [repo: Map.get(context, :memory_repo, Repo)] ++ clock(context)

    case Registry.edit(Map.take(args, ["changes"]), context, opts) do
      {:ok, %{text: text, touched: touched}} ->
        :ok =
          context
          |> Map.get(:reply_blocks, ReplyBlocks)
          |> ReplyBlocks.put_checklists(Map.fetch!(context, :conversation_key), touched)

        {{:ok, Tool.success(text)}, %{}}

      {:error, reason} ->
        refused(reason)
    end
  end

  defp refused(reason) do
    sentence = Registry.describe_error(reason)
    error = %{error_code: Registry.error_tag(reason), error_summary: Telemetry.preview(sentence)}
    {{:ok, Tool.error(sentence)}, error}
  end

  defp clock(%{now_fn: now_fn}) when is_function(now_fn, 0), do: [now: now_fn.()]
  defp clock(_context), do: []
end
