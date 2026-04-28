defmodule Fermix.CLI.Version do
  @moduledoc """
  `fermix version` — prints the release version sourced from the
  `:fermix_core` application spec.
  """

  @spec run() :: non_neg_integer()
  def run do
    version = Application.spec(:fermix_core, :vsn) |> to_string()
    IO.puts("fermix #{version}")
    0
  end
end
