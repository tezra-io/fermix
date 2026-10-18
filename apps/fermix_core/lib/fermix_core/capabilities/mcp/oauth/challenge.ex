defmodule FermixCore.Capabilities.MCP.OAuth.Challenge do
  @moduledoc """
  The `Bearer` challenge an MCP server answers a refused request with
  (RFC 6750 §3, RFC 9728 §5.1, M74 E5): `resource_metadata`, `scope` and
  `error` from its `WWW-Authenticate` header.

  The header is read as RFC 9110 §11.6.1 writes one: challenges separated by
  commas, each an auth scheme and then auth params of `token=token` or
  `token="quoted string"`. Only the first `Bearer` challenge is read; a
  header that does not parse has none.
  """

  @type t :: %{
          resource_metadata: String.t() | nil,
          scope: String.t() | nil,
          error: String.t() | nil
        }

  @token ~r/\A[!#$%&'*+.^_`|~0-9A-Za-z-]+/
  @token68 ~r/\A[A-Za-z0-9._~+\/-]+=*/

  @doc "The `Bearer` challenge among `headers`' `WWW-Authenticate` values, or `nil`."
  @spec bearer([{String.t(), String.t()}]) :: t() | nil
  def bearer(headers) when is_list(headers) do
    headers
    |> Enum.filter(fn {name, _value} -> String.downcase(name) == "www-authenticate" end)
    |> Enum.find_value(fn {_name, value} -> parse(value) end)
  end

  @doc "The `Bearer` challenge one `WWW-Authenticate` value holds, or `nil`."
  @spec parse(String.t() | nil) :: t() | nil
  def parse(nil), do: nil

  def parse(value) when is_binary(value) do
    case challenges(value, []) do
      {:ok, found} -> Enum.find_value(found, &bearer_params/1)
      :error -> nil
    end
  end

  defp bearer_params({scheme, params}) do
    if String.downcase(scheme) == "bearer" do
      %{
        resource_metadata: param(params, "resource_metadata"),
        scope: param(params, "scope"),
        error: param(params, "error")
      }
    end
  end

  defp param(params, name) do
    Enum.find_value(params, fn {key, value} -> if String.downcase(key) == name, do: value end)
  end

  # Challenges in order, each with its params in order.
  defp challenges(rest, acc) do
    case skip(rest) do
      "" -> {:ok, Enum.reverse(acc)}
      text -> scheme(text, acc)
    end
  end

  defp scheme(text, acc) do
    case Regex.run(@token, text) do
      [name] -> after_scheme(name, String.trim_leading(drop(text, name)), acc)
      nil -> :error
    end
  end

  # A scheme alone, then the next challenge or params; a token68 is skipped.
  defp after_scheme(name, rest, acc) do
    cond do
      rest == "" or String.starts_with?(rest, ",") -> challenges(rest, [{name, []} | acc])
      param_start?(rest) -> params(rest, name, [], acc)
      true -> token68(rest, name, acc)
    end
  end

  defp token68(rest, name, acc) do
    case Regex.run(@token68, rest) do
      [value] -> challenges(drop(rest, value), [{name, []} | acc])
      nil -> :error
    end
  end

  defp param_start?(text) do
    case Regex.run(@token, text) do
      [key] -> text |> drop(key) |> String.trim_leading() |> String.starts_with?("=")
      nil -> false
    end
  end

  # Params until one that is not a param starts: the next challenge.
  defp params(text, scheme, found, acc) do
    text = skip(text)

    if param_start?(text) do
      with {:ok, key, value, rest} <- one_param(text) do
        params(rest, scheme, [{key, value} | found], acc)
      end
    else
      challenges(text, [{scheme, Enum.reverse(found)} | acc])
    end
  end

  defp one_param(text) do
    [key] = Regex.run(@token, text)
    rest = text |> drop(key) |> String.trim_leading() |> drop("=") |> String.trim_leading()

    with {:ok, value, rest} <- value(rest), do: {:ok, key, value, rest}
  end

  defp value("\"" <> rest), do: quoted(rest, [])

  defp value(text) do
    case Regex.run(@token, text) do
      [value] -> {:ok, value, drop(text, value)}
      nil -> :error
    end
  end

  defp quoted("\\" <> <<char::utf8, rest::binary>>, acc), do: quoted(rest, [<<char::utf8>> | acc])
  defp quoted("\"" <> rest, acc), do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}
  defp quoted(<<char::utf8, rest::binary>>, acc), do: quoted(rest, [<<char::utf8>> | acc])
  defp quoted(_unterminated, _acc), do: :error

  defp skip(text), do: String.trim_leading(text, " ") |> String.trim_leading(",") |> trim_list()

  defp trim_list(text) do
    trimmed = String.trim_leading(text)
    if String.starts_with?(trimmed, ","), do: skip(trimmed), else: trimmed
  end

  defp drop(text, prefix),
    do: binary_part(text, byte_size(prefix), byte_size(text) - byte_size(prefix))
end
