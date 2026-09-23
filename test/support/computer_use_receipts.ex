defmodule FermixTestSupport.ComputerUseReceipts do
  @moduledoc """
  The `receipt` a compux sidecar returns on every action that is not read-only
  (M42 slice 2 §3), for the driver doubles that stand in for it.

  It exists because the receipt is not decoration: `ComputerUse.Session` derives
  the model-facing `outcome` from `dispatch` and treats an absent receipt on a
  mutating action as a protocol fault rather than inferring one. A double that
  answered a click with a bare `{"ok": true}` would therefore be describing a
  sidecar that cannot exist, and every test built on it would prove nothing about
  the code that ships. One definition here keeps the ~twenty doubles honest and
  keeps the shape in one place when the wire adds a field.
  """

  alias Compux.Protocol

  # Instant, and honest about being instant: a double neither settles nor encodes,
  # so every phase but the input costs nothing. A double that reported no timings
  # at all would be describing a helper that cannot exist (M42 slice 6 §2.5).
  @timings %{"input" => 1, "settle" => 0, "capture" => 0, "encode" => 0}

  @doc """
  A receipt with the given dispatch verdict: `:not_sent`, `:sent`, `:partial` or
  `:unknown`. `effect` is `not_observed` when the sidecar took an after-image and
  `unknown` when it did not; the doubles here do not, so `unknown` is the default.

  `input_method` is `foreground_hid` — the pointer and the keyboard — unless the
  action reached its target through accessibility, which is the one case where
  `effect` is an ANSWER rather than a field the method cannot fill in (M42 slice 4
  §3.3), and `foreground_changed` says whether the action pulled its application
  to the front.

  `check` is the evidence this frame carries (M42 slice 6 §2.1) and `timings_ms`
  what each phase cost. Both are omitted when the caller passes `nil`, which is
  the one shape a test needs for a helper that sent neither.
  """
  @spec receipt(:not_sent | :sent | :partial | :unknown, keyword()) :: map()
  def receipt(dispatch, opts \\ [])
      when dispatch in [:not_sent, :sent, :partial, :unknown] and is_list(opts) do
    %{
      "dispatch" => Atom.to_string(dispatch),
      "effect" => Keyword.get(opts, :effect, "unknown"),
      "input_method" => Keyword.get(opts, :input_method, "foreground_hid"),
      "foreground_changed" => Keyword.get(opts, :foreground_changed, false)
    }
    |> put_optional("timings_ms", Keyword.get(opts, :timings_ms, @timings))
    |> put_optional("check", Keyword.get(opts, :check))
  end

  @doc """
  The receipt an accessibility action earns: the `ax` method, and the effect the
  helper's own read-back proved. `press` is `not_observed` unless a later check
  says otherwise — a successful AX return is a dispatch result, not an effect —
  and `unknown` is the call that was made and never came back. Its check is the
  control read again, which is what an accessibility action is asked for.
  """
  @spec ax(:verified | :not_observed | :unknown, keyword()) :: map()
  def ax(effect, opts \\ []) when effect in [:verified, :not_observed, :unknown] do
    opts
    |> Keyword.put_new(:check, %{"kind" => "semantic"})
    |> Keyword.merge(effect: Atom.to_string(effect), input_method: "ax")
    |> then(&receipt(:sent, &1))
  end

  @doc """
  Stamp `response` with a `sent` receipt when `request`'s action is a mutating
  one, exactly as the sidecar does. A read-only action carries no receipt, and a
  response that already names its own is left alone.

  The check the receipt reports is the one the REQUEST asked for, because that is
  what the helper answers: a double that reported a picture nobody asked for would
  let this side come to depend on evidence a real run never gets.
  """
  @spec stamp(map(), map(), keyword()) :: map()
  def stamp(response, %{"action" => action} = request, opts \\ [])
      when is_map(response) and is_binary(action) do
    if Protocol.read_only?(action) do
      response
    else
      opts = Keyword.put_new_lazy(opts, :check, fn -> requested_check(request) end)
      Map.put_new(response, "receipt", receipt(Keyword.get(opts, :dispatch, :sent), opts))
    end
  end

  # A settled, changed view for an image check; the control for a semantic one;
  # nothing at all where the request asked for nothing.
  defp requested_check(%{"check" => "image"}),
    do: %{"kind" => "image", "settle" => "stable", "changed" => true}

  defp requested_check(%{"check" => "semantic"}), do: %{"kind" => "semantic"}
  defp requested_check(_request), do: %{"kind" => "none"}

  defp put_optional(receipt, _key, nil), do: receipt
  defp put_optional(receipt, key, value), do: Map.put(receipt, key, value)
end
