defmodule FermixCore.Plugins.Plugin do
  @moduledoc """
  Validated bundled plugin manifest.
  """

  @type auth :: %{
          type: :none | :oauth2 | :api_key,
          provider: String.t() | nil,
          account_mode: String.t() | nil,
          scopes: [String.t()],
          key_name: String.t() | nil,
          header: String.t() | nil,
          scheme: String.t() | nil,
          prompt: String.t() | nil,
          help_url: String.t() | nil
        }

  @type config_entry :: %{key: String.t(), prompt: String.t(), required: boolean()}

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          name: String.t(),
          display_name: String.t(),
          description: String.t(),
          category: String.t(),
          version: String.t(),
          min_core_version: String.t() | nil,
          plugin_api: integer() | nil,
          runtime: map() | nil,
          default_enabled?: boolean(),
          interface: map(),
          auth: auth(),
          config: [config_entry()],
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
    :min_core_version,
    :plugin_api,
    :runtime,
    :auth,
    :health_check,
    :path,
    default_enabled?: false,
    interface: %{},
    config: [],
    tools: [],
    skills: []
  ]
end
