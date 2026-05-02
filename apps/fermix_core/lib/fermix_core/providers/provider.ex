defmodule FermixCore.Providers.Provider do
  @moduledoc """
  Behaviour for LLM providers.
  """

  @type chat_message :: %{
          required(:role) => String.t(),
          required(:content) => String.t(),
          optional(:tool_call_id) => String.t(),
          optional(:tool_calls) => [map()]
        }

  @type chat_opts :: [
          model: String.t(),
          temperature: float(),
          max_tokens: pos_integer()
        ]

  @type response :: %{
          content: String.t(),
          tool_calls: [map()],
          usage: %{
            prompt_tokens: non_neg_integer(),
            completion_tokens: non_neg_integer(),
            total_tokens: non_neg_integer()
          },
          model: String.t()
        }

  @doc "Send a chat request and get a response."
  @callback chat([chat_message()], chat_opts()) :: {:ok, response()} | {:error, term()}

  @doc "List available models."
  @callback models() :: {:ok, [String.t()]} | {:error, term()}
end
