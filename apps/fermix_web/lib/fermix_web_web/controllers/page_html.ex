defmodule FermixWebWeb.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.

  See the `page_html` directory for all templates available.
  """
  use FermixWebWeb, :html

  embed_templates "page_html/*"

  def status_label(nil), do: "unknown"

  def status_label(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> status_label()
  end

  def status_label(value) when is_binary(value) do
    String.replace(value, "_", " ")
  end

  def status_label(value), do: inspect(value)

  def datetime_label(nil), do: "none"
  def datetime_label(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def datetime_label(value) when is_binary(value), do: value
  def datetime_label(value), do: inspect(value)
end
