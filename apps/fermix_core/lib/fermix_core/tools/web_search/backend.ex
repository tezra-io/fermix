defmodule FermixCore.Tools.WebSearch.Backend do
  @moduledoc """
  Behaviour for web_search backend adapters.
  """

  @type result :: %{
          title: String.t(),
          url: String.t(),
          snippet: String.t()
        }
  @type trace_metadata :: %{optional(atom()) => term()}

  @callback name() :: atom()
  @callback configured?(opts :: keyword()) :: boolean()
  @callback search(query :: String.t(), opts :: keyword()) ::
              {:ok, [result()], trace_metadata()} | {:error, String.t(), trace_metadata()}
end
