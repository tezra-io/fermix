defmodule FermixCore.ComputerUse.Protocol do
  @moduledoc """
  The line-framed JSON action protocol between `ComputerUse.Session` and the
  OS-driver sidecar (docs/design/COMPUTER_USE.md §5): one request line to the
  sidecar's stdin, one response line back. This module is the CONTRACT the
  vendored Rust `enigo`+`xcap` sidecar implements — it is pure (validation +
  encode/decode + read-only classification) and fully testable without the binary.

  Validation is fail-loud: an out-of-shape action from the model is rejected with
  a clear reason rather than forwarded to a process that drives real input.
  """

  @actions ~w(screenshot left_click right_click double_click mouse_move left_click_drag scroll type key wait)
  @read_only ~w(screenshot mouse_move wait)
  @modifiers ~w(cmd ctrl alt shift)
  @scroll_directions ~w(up down left right)
  @max_type_bytes 10_000
  @max_wait_ms 10_000

  @spec actions() :: [String.t()]
  def actions, do: @actions

  @doc """
  Read-only actions never mutate the screen, so they auto-run (no confirmation,
  §7.3) and carry no post-action screenshot (§5).
  """
  @spec read_only?(String.t()) :: boolean()
  def read_only?(action) when is_binary(action), do: action in @read_only

  @doc """
  Validate + canonicalize an action params map (the tool's discriminated-union
  arguments) into a sidecar request. Returns `{:ok, request}` or `{:error,
  reason}`. The caller (Session) fills the default `display` and the
  `screenshot_after` flag from config before encoding.
  """
  @spec validate(map()) :: {:ok, map()} | {:error, String.t()}
  def validate(params) when is_map(params) do
    case Map.get(params, "action") do
      action when action in @actions -> validate_action(action, params)
      nil -> {:error, "missing required field: action"}
      other -> {:error, "unknown action: #{inspect(other)}"}
    end
  end

  def validate(_other), do: {:error, "action params must be a map"}

  @doc "Encode a validated request to a single JSON line for the sidecar's stdin."
  @spec encode_request(map()) :: binary()
  def encode_request(request) when is_map(request), do: Jason.encode!(request) <> "\n"

  @doc """
  Decode one sidecar response line. A success carries `ok: true`; a failure
  carries `ok: false` + `error`. Anything else (or invalid JSON) fails loud so a
  malformed sidecar can never look like a successful action.
  """
  @spec decode_response(binary()) :: {:ok, map()} | {:error, String.t()}
  def decode_response(line) when is_binary(line) do
    case Jason.decode(String.trim(line)) do
      {:ok, %{"ok" => true} = resp} ->
        {:ok, resp}

      {:ok, %{"ok" => false, "error" => error}} ->
        {:error, to_string(error)}

      {:ok, %{"error" => error}} ->
        {:error, to_string(error)}

      {:ok, other} ->
        {:error, "malformed sidecar response: #{inspect(other)}"}

      {:error, %Jason.DecodeError{} = error} ->
        {:error, "invalid JSON from sidecar: #{Exception.message(error)}"}
    end
  end

  defp validate_action("screenshot", params) do
    with {:ok, display} <- opt_display(params) do
      {:ok, put_display(%{"action" => "screenshot"}, display)}
    end
  end

  defp validate_action(action, params)
       when action in ~w(left_click right_click double_click mouse_move) do
    with {:ok, x} <- coord(params, "x"),
         {:ok, y} <- coord(params, "y"),
         {:ok, modifiers} <- opt_modifiers(params),
         {:ok, display} <- opt_display(params) do
      request = %{"action" => action, "x" => x, "y" => y}
      request = if modifiers == [], do: request, else: Map.put(request, "modifiers", modifiers)
      {:ok, put_display(request, display)}
    end
  end

  defp validate_action("left_click_drag", params) do
    with {:ok, from} <- point(params, "from"),
         {:ok, to} <- point(params, "to"),
         {:ok, display} <- opt_display(params) do
      {:ok, put_display(%{"action" => "left_click_drag", "from" => from, "to" => to}, display)}
    end
  end

  defp validate_action("scroll", params) do
    with {:ok, x} <- coord(params, "x"),
         {:ok, y} <- coord(params, "y"),
         {:ok, direction} <- scroll_direction(params),
         {:ok, amount} <- positive(params, "amount"),
         {:ok, display} <- opt_display(params) do
      request = %{
        "action" => "scroll",
        "x" => x,
        "y" => y,
        "direction" => direction,
        "amount" => amount
      }

      {:ok, put_display(request, display)}
    end
  end

  defp validate_action("type", params) do
    case Map.get(params, "text") do
      text when is_binary(text) and byte_size(text) > 0 and byte_size(text) <= @max_type_bytes ->
        {:ok, %{"action" => "type", "text" => text}}

      text when is_binary(text) ->
        {:error, "type.text must be 1..#{@max_type_bytes} bytes"}

      _other ->
        {:error, "type requires a non-empty string text"}
    end
  end

  defp validate_action("key", params) do
    case Map.get(params, "chord") do
      chord when is_binary(chord) and chord != "" -> {:ok, %{"action" => "key", "chord" => chord}}
      _other -> {:error, ~s(key requires a non-empty string chord, e.g. "ctrl+s")}
    end
  end

  defp validate_action("wait", params) do
    case Map.get(params, "ms") do
      ms when is_integer(ms) and ms > 0 and ms <= @max_wait_ms ->
        {:ok, %{"action" => "wait", "ms" => ms}}

      _other ->
        {:error, "wait.ms must be a positive integer ≤ #{@max_wait_ms}"}
    end
  end

  defp coord(params, key) do
    case Map.get(params, key) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _other -> {:error, "#{key} must be a non-negative integer (screenshot pixel space)"}
    end
  end

  defp point(params, key) do
    case Map.get(params, key) do
      %{"x" => x, "y" => y} when is_integer(x) and is_integer(y) and x >= 0 and y >= 0 ->
        {:ok, %{"x" => x, "y" => y}}

      _other ->
        {:error, ~s(#{key} must be an object with non-negative integer x and y)}
    end
  end

  defp positive(params, key) do
    case Map.get(params, key) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _other -> {:error, "#{key} must be a positive integer"}
    end
  end

  defp scroll_direction(params) do
    case Map.get(params, "direction") do
      direction when direction in @scroll_directions -> {:ok, direction}
      _other -> {:error, "scroll.direction must be one of #{Enum.join(@scroll_directions, ", ")}"}
    end
  end

  defp opt_modifiers(params) do
    case Map.get(params, "modifiers") do
      nil ->
        {:ok, []}

      modifiers when is_list(modifiers) ->
        if Enum.all?(modifiers, &(&1 in @modifiers)),
          do: {:ok, modifiers},
          else: {:error, "modifiers must be a subset of #{inspect(@modifiers)}"}

      _other ->
        {:error, "modifiers must be a list of strings"}
    end
  end

  defp opt_display(params) do
    case Map.get(params, "display") do
      nil -> {:ok, nil}
      display when is_integer(display) and display >= 0 -> {:ok, display}
      _other -> {:error, "display must be a non-negative integer"}
    end
  end

  defp put_display(request, nil), do: request
  defp put_display(request, display), do: Map.put(request, "display", display)
end
