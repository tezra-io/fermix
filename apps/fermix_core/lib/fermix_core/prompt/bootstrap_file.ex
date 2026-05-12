defmodule FermixCore.Prompt.BootstrapFile do
  @moduledoc """
  Shared file handling for prompt bootstrap resources.
  """

  @type name :: :identity | :agents | :soul | :realtime
  @type status :: :present | :fallback
  @type t :: %{
          name: name(),
          path: String.t(),
          content: String.t(),
          approx_size: non_neg_integer(),
          approx_tokens: non_neg_integer(),
          status: status()
        }

  @spec read_present(String.t()) ::
          {:ok, String.t()} | {:missing, :empty | :enoent} | {:error, term()}
  def read_present(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        if String.trim(content) == "" do
          {:missing, :empty}
        else
          {:ok, content}
        end

      {:error, :enoent} ->
        {:missing, :enoent}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec metadata(name(), String.t(), String.t(), status()) :: t()
  def metadata(name, path, content, status)
      when name in [:identity, :agents, :soul, :realtime] and is_binary(path) and
             is_binary(content) and
             status in [:present, :fallback] do
    size = byte_size(content)

    %{
      name: name,
      path: path,
      content: content,
      approx_size: size,
      approx_tokens: estimated_tokens(content),
      status: status
    }
  end

  @spec estimated_tokens(String.t()) :: non_neg_integer()
  def estimated_tokens("") do
    0
  end

  def estimated_tokens(content) when is_binary(content) do
    div(byte_size(content) + 3, 4)
  end
end
