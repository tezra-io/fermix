defmodule FermixCore.Resource.Revision do
  @moduledoc """
  Typed resource revision snapshot with parsed provenance metadata.
  """

  @enforce_keys [
    :id,
    :agent_id,
    :resource_type,
    :scope_id,
    :revision,
    :content_hash,
    :content,
    :byte_size,
    :mutation_source,
    :created_at
  ]
  defstruct [
    :id,
    :agent_id,
    :resource_type,
    :scope_id,
    :revision,
    :parent_revision,
    :content_hash,
    :content,
    :byte_size,
    :mutation_source,
    :provenance,
    :created_at
  ]

  @type t :: %__MODULE__{
          id: integer(),
          agent_id: String.t(),
          resource_type: String.t(),
          scope_id: String.t(),
          revision: pos_integer(),
          parent_revision: pos_integer() | nil,
          content_hash: String.t(),
          content: String.t(),
          byte_size: non_neg_integer(),
          mutation_source: String.t(),
          provenance: map() | nil,
          created_at: DateTime.t()
        }

  @spec from_repo_row(map()) :: t()
  def from_repo_row(row) when is_map(row) do
    %__MODULE__{
      id: Map.fetch!(row, :id),
      agent_id: Map.fetch!(row, :agent_id),
      resource_type: Map.fetch!(row, :resource_type),
      scope_id: Map.fetch!(row, :scope_id),
      revision: Map.fetch!(row, :revision),
      parent_revision: Map.get(row, :parent_revision),
      content_hash: Map.fetch!(row, :content_hash),
      content: Map.fetch!(row, :content),
      byte_size: Map.fetch!(row, :byte_size),
      mutation_source: Map.fetch!(row, :mutation_source),
      provenance: provenance(row),
      created_at: Map.fetch!(row, :created_at)
    }
  end

  defp provenance(%{provenance: provenance}), do: provenance
  defp provenance(%{provenance_json: nil}), do: nil
  defp provenance(%{provenance_json: provenance_json}), do: Jason.decode!(provenance_json)
  defp provenance(_row), do: nil
end
