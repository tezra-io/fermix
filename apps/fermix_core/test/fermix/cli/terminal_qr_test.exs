defmodule Fermix.CLI.TerminalQRTest do
  use ExUnit.Case, async: true

  alias Fermix.CLI.TerminalQR

  @uri "fermix://pair?v=1&port=4031&secret=EXAMPLE"

  test "renders a square code of block pairs inside a two-module quiet zone" do
    assert {:ok, qr} = TerminalQR.render(@uri)

    rows = String.split(qr, "\n")
    {:ok, %{matrix: matrix}} = QRCode.create(@uri, :medium)
    width = (length(matrix) + 4) * 2

    assert length(rows) == length(matrix) + 4
    assert Enum.all?(rows, &(String.length(&1) == width))
    assert String.replace(qr, ["██", "  ", "\n"], "") == ""

    blank = String.duplicate(" ", width)
    assert Enum.take(rows, 2) == [blank, blank]
    assert Enum.take(rows, -2) == [blank, blank]
    assert Enum.all?(rows, &String.starts_with?(&1, "    "))
    assert Enum.all?(rows, &String.ends_with?(&1, "    "))
    assert qr =~ "██"
  end

  test "the same link renders the same code" do
    assert TerminalQR.render(@uri) == TerminalQR.render(@uri)
  end

  test "a link longer than any code can hold is refused, not truncated" do
    assert {:error, {:qr_generation_failed, _reason}} =
             TerminalQR.render(String.duplicate("x", 3_000))
  end
end
