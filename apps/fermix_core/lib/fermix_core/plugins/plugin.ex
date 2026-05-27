defmodule FermixCore.Plugins.Plugin do
  @moduledoc """
  Validated bundled plugin manifest.
  """

  @type auth :: %{
          type: :none | :oauth2,
          provider: String.t() | nil,
          account_mode: String.t() | nil,
          scopes: [String.t()]
        }

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          name: String.t(),
          display_name: String.t(),
          description: String.t(),
          category: String.t(),
          version: String.t(),
          default_enabled?: boolean(),
          interface: map(),
          auth: auth(),
          tools: [map()],
          skills: [map()],
          health_check: map() | nil,
          path: String.t()
        }

  @enforce_keys [
    :schema_version,
    :name,
    :display_name,
    :description,
    :category,
    :version,
    :default_enabled?,
    :auth,
    :tools,
    :skills,
    :path
  ]
  defstruct [
    :schema_version,
    :name,
    :display_name,
    :description,
    :category,
    :version,
    :auth,
    :health_check,
    :path,
    default_enabled?: false,
    interface: %{},
    tools: [],
    skills: []
  ]
end
