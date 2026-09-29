defmodule Fermix.CLI.TerminalQR do
  @moduledoc """
  Renders a pairing link as a QR code a terminal can print.

  Each dark module is two full-block characters and each light one two spaces,
  so the code reads square in a monospace font, and a two-module quiet zone
  surrounds it so a phone camera can find its edges.
  """

  @quiet_modules 2

  @doc "The QR code for `uri`, one text row per module row."
  @spec render(String.t()) :: {:ok, String.t()} | {:error, term()}
  def render(uri) when is_binary(uri) and uri != "" do
    case QRCode.create(uri, :medium) do
      {:ok, %{matrix: matrix}} -> {:ok, render_matrix(matrix)}
      {:error, reason} -> {:error, {:qr_generation_failed, reason}}
    end
  end

  defp render_matrix(matrix) do
    pad = List.duplicate(0, @quiet_modules)
    quiet_row = List.duplicate(0, length(matrix) + 2 * @quiet_modules)
    quiet = List.duplicate(quiet_row, @quiet_modules)
    rows = quiet ++ Enum.map(matrix, fn row -> pad ++ row ++ pad end) ++ quiet

    Enum.map_join(rows, "\n", &render_row/1)
  end

  defp render_row(row), do: Enum.map_join(row, &render_module/1)
  defp render_module(1), do: "██"
  defp render_module(_value), do: "  "
end
