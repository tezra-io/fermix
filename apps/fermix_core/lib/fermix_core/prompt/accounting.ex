defmodule FermixCore.Prompt.Accounting do
  @moduledoc """
  Prompt accounting helpers.

  Accounting is intentionally approximate. M4.5 records prompt-part size for
  inspection, but does not enforce prompt budgets or clipping policy here.
  """

  alias FermixCore.Prompt.BootstrapFile

  @type entry :: %{
          name: atom(),
          source_path: String.t() | nil,
          approx_size: non_neg_integer(),
          approx_tokens: non_neg_integer()
        }

  @spec entry(atom(), String.t() | nil, String.t()) :: entry()
  def entry(name, source_path, content)
      when is_atom(name) and (is_binary(source_path) or is_nil(source_path)) and
             is_binary(content) do
    %{
      name: name,
      source_path: source_path,
      approx_size: byte_size(content),
      approx_tokens: BootstrapFile.estimated_tokens(content)
    }
  end
end
