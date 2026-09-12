defmodule FermixCore.Management.Settings.Tools do
  @moduledoc """
  The `computer_use`, `computer_history`, `harness`, `web_search`,
  `generate_image` and `sandbox` sections (M34 native setup §5.5, §5.7).

  Search and images publish the key row of the backend in force rather than
  every backend's slot: asking an operator to store six keys to use one is how
  the browser door's search tab reads today.
  """

  alias FermixCore.Harness.Config, as: HarnessConfig
  alias FermixCore.Harness.Vendors
  alias FermixCore.Management.Settings.Row
  alias FermixCore.Management.Settings.Source
  alias FermixCore.Sandbox.Config, as: SandboxConfig
  alias FermixCore.Tools.Media.Registry, as: MediaRegistry
  alias FermixCore.Tools.WebSearch

  @sections [
    %{id: "computer_use", pane: "computer", title: "Computer use"},
    %{id: "computer_history", pane: "computer", title: "Computer history"},
    %{id: "harness", pane: "coding", title: "Coding agents"},
    %{id: "web_search", pane: "search", title: "Web search"},
    %{id: "generate_image", pane: "images", title: "Images"},
    %{id: "sandbox", pane: "sandbox", title: "Sandbox"}
  ]

  # Keyed by the wire spelling, not by an atom: the configured value is read
  # from the snapshot, and converting it would raise on a name this build does
  # not know, turning a hand-edited file into an unreadable pane rather than a
  # row showing the value in force.
  @search_labels %{
    "duckduckgo" => "DuckDuckGo",
    "tavily" => "Tavily",
    "exa" => "Exa",
    "parallel" => "Parallel",
    "brave" => "Brave",
    "perplexity" => "Perplexity",
    "firecrawl" => "Firecrawl"
  }

  # The key slot each search backend reads. DuckDuckGo needs none, which is why
  # it is the keyless default rather than an unconfigured one.
  @search_secrets %{
    "tavily" => :tavily_api_key,
    "exa" => :exa_api_key,
    "parallel" => :parallel_api_key,
    "brave" => :brave_api_key,
    "perplexity" => :perplexity_api_key,
    "firecrawl" => :firecrawl_api_key
  }

  @image_labels %{
    "openai" => "OpenAI",
    "xai" => "SpaceXAI",
    "google" => "Google",
    "openai_codex" => "ChatGPT"
  }

  # ChatGPT signs in through the Codex provider and has no key of its own.
  @image_secrets %{
    "openai" => :openai_api_key,
    "xai" => :xai_api_key,
    "google" => :google_api_key
  }

  @vendor_labels %{"codex" => "Codex", "claude" => "Claude Code"}

  @sandbox_mode_hints %{
    strict: "Reads only what you name",
    standard: "Reads your Fermix home and what you name",
    open: "Reads anything you can read"
  }

  @doc "Every section this module owns, in publication order."
  @spec sections() :: [%{id: String.t(), pane: String.t(), title: String.t()}]
  def sections, do: @sections

  @doc "Whether this module owns the named section."
  @spec owns?(String.t()) :: boolean()
  def owns?(section) when is_binary(section), do: Enum.any?(@sections, &(&1.id == section))

  @doc "The rows of one owned section."
  @spec rows(String.t(), Source.snapshot()) :: [Row.t()]
  def rows("computer_use", snapshot) do
    [
      Row.new("computer_use_enabled", :toggle, "Computer use",
        footer: "Runs as Fermix Computer Use, a separate signed helper.",
        value: Source.boolean(Source.core(snapshot, :computer_use), :enabled, false),
        restart: Row.restart?(:computer_use)
      )
    ]
  end

  def rows("computer_history", snapshot) do
    block = Source.core(snapshot, :computer_history)
    restart = Row.restart?(:computer_history)

    [
      Row.new("computer_history_enabled", :toggle, "Computer history",
        value: Source.boolean(block, :enabled, false),
        restart: restart
      ),
      Row.new("computer_history_apps", :list, "Apps",
        footer: "Only these apps are watched.",
        value: Source.strings(block, :apps),
        restart: restart
      ),
      summarizer_row(block, restart)
    ]
  end

  def rows("harness", snapshot) do
    block = Source.core(snapshot, :harness)
    restart = Row.restart?(:harness)

    [
      Row.new("harness_approved", :toggle, "Allow coding agents to run on this Mac",
        footer: "Each tool keeps its own login. Cloud runs are off in this release.",
        value: Source.boolean(block, :approved, HarnessConfig.approved?([])),
        restart: restart
      ),
      Row.new("harness_default_vendor", :choice, "Preferred tool",
        value: Source.string(block, :default_vendor),
        options: [Row.option("", "No preference") | vendor_options()],
        restart: restart
      )
    ]
  end

  def rows("web_search", snapshot) do
    block = Source.tool(snapshot, :web_search)
    backend = Source.string(block, :backend, "duckduckgo")
    restart = Row.restart?(:tools)

    [
      Row.new("web_search_backend", :choice, "Web search",
        value: backend,
        options: search_options(),
        restart: restart
      )
    ] ++ search_key_rows(snapshot, backend, restart)
  end

  def rows("generate_image", snapshot) do
    block = Source.tool(snapshot, :generate_image)
    backend = Source.string(block, :backend, "openai")
    restart = Row.restart?(:tools)

    [
      Row.new("image_backend", :choice, "Images",
        value: backend,
        options: Enum.map(MediaRegistry.providers(:image), &Row.option(&1, image_label(&1))),
        restart: restart
      ),
      Row.new("image_model", :choice, "Model",
        value: Source.string(block, :model),
        options: image_model_options(backend),
        suggestions: true,
        restart: restart
      )
    ] ++ image_key_row(snapshot, backend, restart)
  end

  def rows("sandbox", snapshot) do
    config = SandboxConfig.normalize(Map.get(snapshot, :sandbox))
    restart = Row.restart?(:sandbox)

    [
      Row.new("sandbox_mode", :choice, "Sandbox",
        value: config.mode,
        options: Enum.map(SandboxConfig.modes(), &mode_option/1),
        restart: restart
      ),
      Row.new("sandbox_profile", :choice, "Command profile",
        value: Map.get(config.commands, :profile),
        options: Enum.map(SandboxConfig.command_profiles(), &Row.option(word(&1), title(&1))),
        restart: restart
      ),
      Row.new("sandbox_env_allow", :list, "Allowed environment variables",
        footer: "These are names only. Values are never shown here.",
        value: Map.get(config.env, :allow, []),
        restart: restart
      )
    ]
  end

  # Read-only until the summarizer has an answer key of its own: a control whose
  # save always refuses is worse than a row that says what is in force.
  defp summarizer_row(block, restart) do
    Row.new("computer_history_summarizer", :choice, "Summarize with",
      value: Source.string(block, :summarizer, "default_provider"),
      options: [
        Row.option("default_provider", "The primary provider"),
        Row.option("local", "On this Mac")
      ],
      read_only: true,
      restart: restart
    )
  end

  # A vendor that is not installed is still offered and still disabled, so the
  # pane says why rather than hiding the choice. Detection is `setup.detect`'s
  # job; a descriptor read never shells out.
  defp vendor_options do
    Enum.map(Vendors.vendors(), &Row.option(&1, Map.fetch!(@vendor_labels, &1)))
  end

  defp search_options do
    Enum.map(WebSearch.backend_names(), fn name ->
      word = Atom.to_string(name)
      Row.option(word, Map.fetch!(@search_labels, word), hint: search_hint(word))
    end)
  end

  defp search_hint("duckduckgo"), do: "Needs no key"
  defp search_hint(_name), do: nil

  # The selected backend's key, plus Brave, which also powers place search and
  # is therefore useful with any web backend selected.
  defp search_key_rows(snapshot, backend, restart) do
    keys = Enum.uniq(Enum.reject([Map.get(@search_secrets, backend), :brave_api_key], &is_nil/1))

    Enum.map(keys, fn key ->
      Row.new(Atom.to_string(key), :secret, search_key_label(key),
        footer: search_key_footer(key),
        present: Source.secret_present?(snapshot, key),
        restart: restart
      )
    end)
  end

  defp search_key_label(key) do
    name = key |> Atom.to_string() |> String.replace_suffix("_api_key", "")
    "#{Map.fetch!(@search_labels, name)} key"
  end

  defp search_key_footer(:brave_api_key), do: "Also powers place search."
  defp search_key_footer(_key), do: nil

  defp image_key_row(snapshot, backend, restart) do
    case Map.fetch(@image_secrets, backend) do
      {:ok, key} ->
        [
          Row.new(Atom.to_string(key), :secret, "#{image_label(backend)} key",
            present: Source.secret_present?(snapshot, key),
            restart: restart
          )
        ]

      :error ->
        []
    end
  end

  defp image_model_options(backend) do
    case MediaRegistry.supported_models(:image, backend) do
      {:ok, models} -> Enum.map(models, &Row.option(&1, &1))
      {:error, _reason} -> []
    end
  end

  defp image_label(backend), do: Map.get(@image_labels, backend, backend)

  defp mode_option(mode),
    do: Row.option(word(mode), title(mode), hint: Map.fetch!(@sandbox_mode_hints, mode))

  defp word(value) when is_atom(value), do: Atom.to_string(value)
  defp title(value) when is_atom(value), do: value |> Atom.to_string() |> String.capitalize()
end
