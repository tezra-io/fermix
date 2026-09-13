defmodule FermixCore.Prompt.TemplateRenderer do
  @moduledoc """
  Renders prompt templates from `priv/templates/`.

  Each template is precompiled at build time: templates with `<% ... %>`
  expressions become EEx-generated functions via `EEx.function_from_file/5`,
  and static templates are inlined as string literals. `render/2` is a
  direct function call with no per-call disk read or interpretation.
  Templates use the strict `<%= @assign %>` form; missing assigns raise
  `KeyError` at render time so silent missing values cannot produce
  half-rendered files.
  """

  require EEx

  @type template_name ::
          :identity | :fermix | :soul | :user | :memory | :realtime | :live

  @templates [:identity, :fermix, :soul, :user, :memory, :realtime, :live]

  for name <- @templates do
    path =
      [__DIR__, "..", "..", "..", "priv", "templates", "#{name}.md.eex"]
      |> Path.join()
      |> Path.expand()

    @external_resource path
    content = File.read!(path)

    if String.contains?(content, "<%") do
      EEx.function_from_file(:defp, :"render_#{name}", path, [:assigns], trim: true)
    else
      defp unquote(:"render_#{name}")(_assigns), do: unquote(content)
    end
  end

  @spec render(template_name(), map()) :: {:ok, String.t()} | {:error, term()}
  def render(name, assigns) when is_atom(name) and is_map(assigns) do
    render_template(name, Map.to_list(assigns))
  end

  # Dispatch is generated from `@templates` (kept in its own loop so the
  # clauses stay grouped) — the module list is the single place a template is
  # declared, and adding one never means editing `render/2`.
  for name <- @templates do
    defp render_template(unquote(name), assigns) do
      {:ok, unquote(:"render_#{name}")(assigns)}
    end
  end

  defp render_template(_name, _assigns), do: {:error, :not_found}
end
