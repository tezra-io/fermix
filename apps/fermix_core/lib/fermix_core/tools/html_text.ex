defmodule FermixCore.Tools.HtmlText do
  @moduledoc """
  Render Floki nodes to compact markdown-light text.
  """

  @spec extract(term()) :: String.t()
  def extract(document) do
    document
    |> render_nodes()
    |> IO.iodata_to_binary()
    |> normalize_output()
  end

  defp render_nodes(nodes) when is_list(nodes), do: Enum.map(nodes, &render_node/1)
  defp render_nodes(node), do: render_node(node)

  defp render_node(text) when is_binary(text), do: text
  defp render_node({"script", _attrs, _children}), do: []
  defp render_node({"style", _attrs, _children}), do: []
  defp render_node({"noscript", _attrs, _children}), do: []

  defp render_node({tag, _attrs, children}) when tag in ~w(h1 h2 h3 h4 h5 h6) do
    level = tag |> String.trim_leading("h") |> String.to_integer()
    ["\n", String.duplicate("#", level), " ", inline(children), "\n\n"]
  end

  defp render_node({"p", _attrs, children}), do: ["\n", inline(children), "\n\n"]
  defp render_node({"br", _attrs, _children}), do: "\n"
  defp render_node({"ul", _attrs, children}), do: ["\n", list_items(children, "- "), "\n"]
  defp render_node({"ol", _attrs, children}), do: ["\n", list_items(children, "1. "), "\n"]

  defp render_node({"pre", _attrs, children}) do
    ["\n```\n", text_only(children) |> String.trim(), "\n```\n\n"]
  end

  defp render_node({"code", _attrs, children}),
    do: ["`", text_only(children) |> String.trim(), "`"]

  defp render_node({"a", attrs, children}) do
    text = inline(children)

    case attr(attrs, "href") do
      nil -> text
      href -> ["[", text, "](", href, ")"]
    end
  end

  defp render_node({_tag, _attrs, children}), do: render_nodes(children)
  defp render_node(_node), do: []

  defp list_items(children, marker) do
    children
    |> Enum.filter(&match?({"li", _attrs, _children}, &1))
    |> Enum.map(fn {"li", _attrs, li_children} -> [marker, inline(li_children), "\n"] end)
  end

  defp inline(children) do
    children
    |> render_nodes()
    |> IO.iodata_to_binary()
    |> String.replace(~r/\s+/, " ")
    |> String.replace(~r/([[:alnum:]])\[/u, "\\1 [")
    |> String.replace(~r/\s+([.,;:!?])/, "\\1")
    |> String.trim()
  end

  defp text_only(nodes) when is_list(nodes), do: nodes |> Enum.map(&text_only/1) |> Enum.join("")
  defp text_only(text) when is_binary(text), do: text
  defp text_only({_tag, _attrs, children}), do: text_only(children)
  defp text_only(_node), do: ""

  defp attr(attrs, key) do
    Enum.find_value(attrs, fn
      {^key, value} -> value
      _other -> nil
    end)
  end

  defp normalize_output(text) do
    text
    |> String.replace(~r/[ \t]+\n/, "\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end
end
