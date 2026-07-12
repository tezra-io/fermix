defmodule FermixCore.Providers.Descriptor do
  @moduledoc """
  Static per-provider metadata registry (docs/design/MILESTONE_12_PROVIDER_EXPANSION.md §2).

  One declarative entry per provider; ships in code, versioned with the
  release — like the model catalog. List-shaped and data-shaped call sites
  (provider enumerations, setup fields, config-key allowlists, default
  base URLs, auth-mode menus) derive from this registry so they cannot
  drift per provider. Genuinely behavioral code — adapter modules, OAuth
  login flows, doctor probe request shapes — stays per-provider: the
  descriptor describes, it does not execute.

  `all/0` order is load-bearing: it is the fallback order
  (`Selection.ordered_providers/1`) and the auto-promotion tie-break.
  """

  @type auth_mode :: :api_key | :oauth | :none

  @typedoc """
  One wizard/web setup field for the provider's config block.

    * `:key` — the wizard answer key (for secrets, equal to the
      `SecretPaths` registry key)
    * `:config_key` — the provider-block key the value lands on
    * `:label` — CLI prompt / web field label
    * `:secret?` — secret fields route through `SecretWriter` and store
      the keyring sentinel; plain fields persist as-is
    * `:default` — prefill for plain fields (`nil` for secrets)
  """
  @type setup_field :: %{
          key: atom(),
          config_key: atom(),
          label: String.t(),
          secret?: boolean(),
          default: String.t() | nil
        }

  @type t :: %__MODULE__{
          id: atom(),
          label: String.t(),
          adapter: module() | :routed,
          default_base_url: String.t() | nil,
          auth_modes: [auth_mode(), ...],
          secrets: [atom()],
          config_keys: [atom(), ...],
          setup_fields: [setup_field()],
          effort?: boolean(),
          default_req_options: keyword()
        }

  @enforce_keys [
    :id,
    :label,
    :adapter,
    :auth_modes,
    :secrets,
    :config_keys,
    :setup_fields,
    :effort?
  ]
  defstruct [
    :id,
    :label,
    :adapter,
    :default_base_url,
    :auth_modes,
    :secrets,
    :config_keys,
    :setup_fields,
    :effort?,
    default_req_options: []
  ]

  # `config_keys` order = the persisted TOML key order (the normalizer
  # builds blocks in this sequence). `auth_modes` carries a single element
  # for single-mode providers; `length > 1` is what gates the web
  # auth-mode picker. `:routed` keeps `Adapter.for_route/1`'s
  # Responses-vs-ChatCompletions split for direct OpenAI.
  #
  # Raw maps here (structs of a module cannot be built in its own module
  # attributes); materialized via `struct!/2` below so `@enforce_keys`
  # still validates every entry at compile time.
  @raw_descriptors [
    %{
      id: :openai_codex,
      label: "OpenAI Codex (ChatGPT)",
      adapter: FermixCore.Providers.OpenAI.Codex,
      default_base_url: "https://chatgpt.com/backend-api/codex/responses",
      auth_modes: [:oauth],
      secrets: [],
      config_keys: [:default_model, :reasoning_effort, :fast, :primary],
      setup_fields: [],
      effort?: true
    },
    %{
      id: :openai,
      label: "OpenAI",
      adapter: :routed,
      default_base_url: "https://api.openai.com/v1",
      auth_modes: [:api_key],
      secrets: [:openai_api_key],
      # No :base_url here: config.exs seeds a baseline base_url into the
      # openai app-env block, so persisting it would make every
      # current-vs-persisted snapshot diff (restart_required?) dirty.
      config_keys: [:api_key, :default_model, :reasoning_effort, :primary],
      setup_fields: [
        %{
          key: :openai_api_key,
          config_key: :api_key,
          label: "OpenAI API key",
          secret?: true,
          default: nil
        }
      ],
      effort?: true
    },
    %{
      id: :anthropic,
      label: "Anthropic",
      adapter: FermixCore.Providers.Anthropic.Messages,
      default_base_url: "https://api.anthropic.com/v1",
      auth_modes: [:api_key, :oauth],
      secrets: [:anthropic_api_key],
      config_keys: [:auth_mode, :api_key, :base_url, :default_model, :reasoning_effort, :primary],
      setup_fields: [
        %{
          key: :anthropic_api_key,
          config_key: :api_key,
          label: "Anthropic API key",
          secret?: true,
          default: nil
        }
      ],
      effort?: true
    },
    %{
      id: :xai,
      label: "SpaceXAI",
      adapter: FermixCore.Providers.XAI.Responses,
      default_base_url: "https://api.x.ai/v1",
      auth_modes: [:api_key, :oauth],
      secrets: [:xai_api_key],
      config_keys: [:auth_mode, :api_key, :base_url, :default_model, :reasoning_effort, :primary],
      setup_fields: [
        %{
          key: :xai_api_key,
          config_key: :api_key,
          label: "SpaceXAI API key (or connect OAuth later: fermix auth login --provider xai)",
          secret?: true,
          default: nil
        }
      ],
      effort?: true
    },
    %{
      id: :openrouter,
      label: "OpenRouter",
      adapter: FermixCore.Providers.OpenAI.ChatCompletions,
      default_base_url: "https://openrouter.ai/api/v1",
      auth_modes: [:api_key],
      secrets: [:openrouter_api_key],
      config_keys: [:api_key, :base_url, :default_model, :primary],
      setup_fields: [
        %{
          key: :openrouter_api_key,
          config_key: :api_key,
          label: "OpenRouter API key",
          secret?: true,
          default: nil
        }
      ],
      effort?: false
    },
    %{
      id: :mistral,
      label: "Mistral",
      adapter: FermixCore.Providers.OpenAI.ChatCompletions,
      default_base_url: "https://api.mistral.ai/v1",
      auth_modes: [:api_key],
      secrets: [:mistral_api_key],
      config_keys: [:api_key, :base_url, :default_model, :primary],
      setup_fields: [
        %{
          key: :mistral_api_key,
          config_key: :api_key,
          label: "Mistral API key",
          secret?: true,
          default: nil
        }
      ],
      # Mistral's effort vocabulary is high|none, not the canonical
      # none|low|medium|high subset; rather than map a partial range we omit
      # the field entirely (like OpenRouter) and take the server default.
      effort?: false
    },
    # Ollama stays last: a local model is the last-resort fallback hop, so
    # every cloud provider (Mistral included) is tried before it.
    %{
      id: :ollama,
      label: "Ollama",
      adapter: FermixCore.Providers.OpenAI.ChatCompletions,
      default_base_url: "http://localhost:11434/v1",
      auth_modes: [:none],
      secrets: [],
      config_keys: [:base_url, :default_model, :primary],
      setup_fields: [
        %{
          key: :ollama_base_url,
          config_key: :base_url,
          label: "Ollama base URL (blank = http://localhost:11434/v1)",
          secret?: false,
          default: "http://localhost:11434/v1"
        }
      ],
      effort?: false,
      # Local inference is slow; explicit per-route req_options still win.
      default_req_options: [receive_timeout: 300_000]
    }
  ]

  @ids Enum.map(@raw_descriptors, & &1.id)

  @spec all() :: [t(), ...]
  def all, do: Enum.map(@raw_descriptors, &struct!(__MODULE__, &1))

  @spec ids() :: [atom(), ...]
  def ids, do: @ids

  @spec fetch(atom()) :: {:ok, t()} | :error
  def fetch(id) when is_atom(id) do
    case Enum.find(@raw_descriptors, &(&1.id == id)) do
      nil -> :error
      raw -> {:ok, struct!(__MODULE__, raw)}
    end
  end

  @spec fetch!(atom()) :: t()
  def fetch!(id) when is_atom(id) do
    case fetch(id) do
      {:ok, descriptor} ->
        descriptor

      :error ->
        raise ArgumentError,
              "unknown provider #{inspect(id)}; expected one of #{Enum.map_join(@ids, ", ", &inspect/1)}"
    end
  end

  @doc "The provider's default auth mode (single-mode providers have exactly one)."
  @spec default_auth_mode(t()) :: auth_mode()
  def default_auth_mode(%__MODULE__{auth_modes: [mode | _rest]}), do: mode

  @doc "Whether the provider exposes an auth-mode choice (gates the web picker)."
  @spec multi_auth_mode?(t()) :: boolean()
  def multi_auth_mode?(%__MODULE__{auth_modes: modes}), do: length(modes) > 1
end
