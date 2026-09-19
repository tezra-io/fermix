defmodule FermixTestSupport.ComputerUseObservations do
  @moduledoc """
  The `observation_id` a compux sidecar mints on every reply that hands the model
  coordinates (M42 slice 3 §3.3), for the driver doubles that stand in for it.

  It exists for the same reason `ComputerUseReceipts` does: the id is not
  decoration. `ComputerUse.Session` records it, `ComputerUse.Observations` resolves
  marks and the wrong-grid tripwire against it, and every screenshot summary leads
  with it — so a double that answered a `screenshot` with bare image bytes would be
  describing a sidecar that cannot exist, and the next pointer action in that test
  would be refused for naming an image nothing minted.

  The id is DETERMINISTIC (`"obs-1"` by default), because a test that has to read
  an id back out of a summary before it can click is a test about string parsing.
  """

  # The replies that hand back coordinates, mirroring `Compux.Protocol`'s producing
  # set plus `windows` (which answers in the full display's own pixels).
  @image ~w(screenshot wait_for_change)
  @semantic ~w(elements windows)

  @doc "The id the doubles mint by default."
  @spec id() :: String.t()
  def id, do: "obs-1"

  @doc """
  Stamp `response` with the observation `request`'s action would mint: the id, its
  kind, and the capture stamp. A reply that hands back no coordinates — a click's
  ack, a probe, an idle read — is left exactly as it was.

  `:id` names the image, for a test that needs two of them to be different.
  """
  @spec stamp(map(), map(), keyword()) :: map()
  def stamp(response, %{"action" => action}, opts \\ [])
      when is_map(response) and is_binary(action) and is_list(opts) do
    case kind(action) do
      nil -> response
      kind -> Map.merge(response, minted(kind, Keyword.get(opts, :id, id())))
    end
  end

  defp minted(kind, id) do
    %{
      "observation_id" => id,
      "observation_kind" => kind,
      "captured_at_monotonic_ns" => 1_000
    }
  end

  @doc """
  The id a double mints for a capture of `region` (nil = the whole display).

  It ENCODES the rectangle, which is what lets `resolved_region/1` answer as the
  helper's stored transform does without a double keeping a table of its own.
  """
  @spec image_id(map() | nil) :: String.t()
  def image_id(nil), do: "obs-full"

  def image_id(%{"x" => x, "y" => y, "w" => w, "h" => h}), do: "obs-#{x}-#{y}-#{w}-#{h}"

  @doc """
  The rectangle the helper echoes on a reply: whatever was asked for, resolved
  into the FULL-DISPLAY image's pixels.

  A `screenshot` may name an `observation_id` beside its `region`, and the
  rectangle is then in that image's pixels — a crop of a crop. The helper maps it
  through the transform it stored when it made that image; a double does the same
  by reading the rectangle back out of the id. An id that encodes none (the plain
  `"obs-1"` the simple doubles mint) leaves the request's own rectangle, which is
  right for every double that never nests.
  """
  @spec resolved_region(map()) :: map() | nil
  def resolved_region(request) when is_map(request) do
    case request["observation_id"] do
      id when is_binary(id) -> region_of(id) || request["region"]
      _none -> request["region"]
    end
  end

  @doc """
  The rectangle an id encodes, or `nil` when it encodes none (the full display,
  and the plain `"obs-1"` the simple doubles mint).

  A mutating action's check re-captures the view the action was aimed in, so a
  double answering one reads that view's rectangle back out of the id it was given
  rather than keeping a table of its own.
  """
  @spec region_of(String.t()) :: map() | nil
  def region_of("obs-" <> rest) do
    case Enum.map(String.split(rest, "-"), &Integer.parse/1) do
      [{x, ""}, {y, ""}, {w, ""}, {h, ""}] -> %{"x" => x, "y" => y, "w" => w, "h" => h}
      _other -> nil
    end
  end

  def region_of(_id), do: nil

  defp kind(action) when action in @image, do: "image"
  defp kind(action) when action in @semantic, do: "semantic"
  defp kind(_action), do: nil
end
