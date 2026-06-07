defmodule FermixCore.Browser.Error do
  @moduledoc false

  @enforce_keys [:code, :message]
  defstruct [:code, :message, details: %{}]

  @type t :: %__MODULE__{code: String.t(), message: String.t(), details: map()}

  @spec new(String.t() | atom(), String.t(), map()) :: t()
  def new(code, message, details \\ %{}) when is_binary(message) and is_map(details) do
    %__MODULE__{code: to_string(code), message: message, details: details}
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = error) do
    %{
      "code" => error.code,
      "message" => error.message,
      "details" => error.details
    }
  end
end
