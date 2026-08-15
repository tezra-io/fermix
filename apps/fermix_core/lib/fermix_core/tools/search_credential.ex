defmodule FermixCore.Tools.SearchCredential do
  @moduledoc """
  The one Brave credential seam (MILESTONE_31 §8.1).

  Brave has several consumers — the `web_search` Brave backend today,
  `place_search` next — and exactly one credential:
  `[fermix_core.tools.web_search].brave_api_key`. M31 keeps that config path and
  mints no second secret, so every consumer must decide "is the key present"
  identically or they drift: a doctor reporting a credential as present while
  the tool refuses with `auth_failed` is the failure this module exists to
  prevent.

  Two functions, one rule:

    * `brave/1` is pure. Callers holding the resolved
      `[fermix_core.tools.web_search]` keyword — or the backend opts built from
      it — pass it in.
    * `brave/0` is the reader: it performs the `Application` env read, so
      config I/O stays a visible operation at the call site instead of hiding
      inside the resolver.

  `Setup.ConfigStore` materializes keyring references at config load, so a
  surviving `@keyring` sentinel means the secret never resolved — missing, not a
  credential. Blank and whitespace-only values are missing for the same reason:
  `Setup.ConfigStore` trims and drops them on save, so one can only arrive from
  a hand-set application env, and sending it would buy a metered `401` instead
  of a loud local refusal.

  Value normalization is not this module's job — `Setup.ConfigStore` owns it,
  one owner per concept. A present key is returned exactly as configured.
  """

  @config_key :brave_api_key
  @missing_error "auth_failed: missing Brave API key"

  @doc """
  Resolves the Brave key from the current `[fermix_core.tools.web_search]`
  application config.

  Reads application env — the config I/O every other function here avoids.
  """
  @spec brave() :: {:ok, String.t()} | {:error, String.t()}
  def brave, do: brave(web_search_config())

  @doc """
  Resolves the Brave key from a caller-supplied `[fermix_core.tools.web_search]`
  keyword, or from the backend opts built from it.

  Pure: identical config in, identical answer out, from a tool, a test, or a
  readiness probe.
  """
  @spec brave(keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def brave(config) when is_list(config), do: credential(Keyword.get(config, @config_key))

  defp credential(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, @missing_error}
      "@keyring" -> {:error, @missing_error}
      _present -> {:ok, value}
    end
  end

  defp credential(_value), do: {:error, @missing_error}

  # Mirrors `FermixCore.Tools.WebSearch.config/0`. A section of an unexpected
  # shape reads as unconfigured rather than raising: raising here would render
  # the surrounding section — the API key included — into an exception message
  # and its stacktrace.
  defp web_search_config do
    tools = Application.get_env(:fermix_core, :tools, [])

    if is_list(tools), do: section(Keyword.get(tools, :web_search, [])), else: []
  end

  defp section(config) when is_list(config), do: config
  defp section(_config), do: []
end
