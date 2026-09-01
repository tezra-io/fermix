defmodule FermixWebWeb.ProductCopyTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Product-copy gate for the web surface, mirroring the macOS app's
  ProductStringsTests: no em dashes in anything that can render. The case set
  is derived from the live sources, not a hand-maintained list: every `.ex`
  and `.heex` file under `lib/fermix_web_web` is scanned, with Elixir `#`
  comment lines and HEEx `<%!-- --%>` comments stripped (comments are not
  product copy).
  """

  @web_root Path.expand("../../lib/fermix_web_web", __DIR__)

  test "renderable web copy contains no em dashes" do
    offenders =
      @web_root
      |> Path.join("**/*.{ex,heex}")
      |> Path.wildcard()
      |> Enum.flat_map(&em_dash_lines/1)

    assert offenders == [],
           "em dash (U+2014) in web copy; reword (the product copy rule bans it):\n" <>
             Enum.join(offenders, "\n")
  end

  defp em_dash_lines(path) do
    path
    |> File.read!()
    |> strip_heex_comments()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reject(fn {line, _n} -> comment_line?(path, line) end)
    |> Enum.filter(fn {line, _n} -> String.contains?(line, "—") end)
    |> Enum.map(fn {line, n} ->
      "#{Path.relative_to(path, @web_root)}:#{n}: #{String.trim(line)}"
    end)
  end

  # Blank the comment's non-newline characters so line numbers stay accurate.
  defp strip_heex_comments(content) do
    Regex.replace(~r/<%!--.*?--%>/s, content, fn match ->
      String.replace(match, ~r/[^\n]+/, "")
    end)
  end

  defp comment_line?(path, line) do
    Path.extname(path) == ".ex" and String.starts_with?(String.trim_leading(line), "#")
  end
end
