defmodule FermixNif do
  @moduledoc """
  Placeholder NIF app. No Rust crate or Rustler dependency is wired in yet, so
  this module exports only `hello/0` — there is no tokenizer or crypto NIF here
  today. Token estimation in the rest of the umbrella uses a plain byte-length
  heuristic (see `FermixCore.Memory.Compactor`), not a NIF.
  """

  @doc """
  Hello world.

  ## Examples

      iex> FermixNif.hello()
      :world

  """
  def hello do
    :world
  end
end
