defmodule FermixCore.ComputerUse.AmbiguousGridTest do
  @moduledoc """
  The wrong-grid tripwire (M28 A1) and the dual-space cursor disclosure (M28 A2).

  Observed live (2026-07-28 EDT, voice session:16 on a 3840x1080 @1x display): the
  model was sent a 1355x959 magnified crop of region {23,11,482,341}, then answered
  15 clicks whose coordinates all fit inside the REGION RECTANGLE — it was reading
  the full-screen 1366x384 grid, not the crop it was told to read. The contract
  interpreted them as crop pixels, so every click executed ÷2.81 toward the region
  origin, and the cursor echo (rendered in the same crop space) confirmed each miss
  as a perfect hit. These tests pin the two fixes:

  A1: coordinates that are plausible on BOTH live grids (inside the POSITIONED
  region rect while the view is magnified >1.5x) refuse with a typed
  `ambiguous_coordinates` naming the exact conversion; `confirm_grid: true`
  re-sends them as crop pixels. The rect is positioned (r.x..r.x+r.w), not
  origin-anchored (0..r.w) — an origin-anchored test goes silently blind for any
  window not at the screen's top-left.

  A2: the cursor echo carries its full-screen equivalent alongside the crop
  coordinate, so a wrong-grid click stops being self-consistent.
  """

  use ExUnit.Case, async: true

  alias FermixCore.ComputerUse.Config
  alias FermixCore.ComputerUse.Session

  # Mirrors compux's real screenshot payload shape for the incident display
  # (3840x1080 @1x -> full sent image 1366x384): width/height + region echo, so
  # the session learns the view's dims exactly the way it does in production.
  # `dims` maps a request region (nil = full screen) to the sent image size.
  defmodule GeomDriver do
    @behaviour Compux.Driver

    @full_region %{"x" => 0, "y" => 0, "w" => 1366, "h" => 384}

    @impl true
    def start(opts) do
      {:ok,
       %{
         test_pid: Keyword.fetch!(opts, :test_pid),
         dims: Keyword.fetch!(opts, :dims),
         cursor: Keyword.get(opts, :cursor)
       }}
    end

    @impl true
    def execute(state, request) do
      send(state.test_pid, {:driver_execute, request})
      respond(state, request)
    end

    defp respond(state, %{"action" => "screenshot"} = request) do
      {w, h} = Map.fetch!(state.dims, request["region"])

      base = %{
        "ok" => true,
        "data" => Base.encode64("png"),
        "mime" => "image/png",
        "width" => w,
        "height" => h,
        "region" => request["region"] || @full_region
      }

      {:ok, if(state.cursor, do: Map.put(base, "cursor", state.cursor), else: base)}
    end

    defp respond(_state, %{"action" => "elements"}),
      do: {:ok, %{"elements" => [%{"role" => "AXButton", "x" => 40, "y" => 50}]}}

    defp respond(_state, _request), do: {:ok, %{"ok" => true}}

    @impl true
    def stop(_state), do: :ok
  end

  # The live incident geometry: region {23,11,482,341} in full-sent space came
  # back as a 1355x959 native-resolution crop (kz_eff = 1355/482 = 2.811).
  @incident_region %{"x" => 23, "y" => 11, "w" => 482, "h" => 341}
  @incident_dims {1355, 959}

  # The same window shape positioned right of center — the geometry an
  # origin-anchored (0..w) tripwire would go blind on.
  @offcenter_region %{"x" => 700, "y" => 40, "w" => 482, "h" => 341}

  # A mild zoom below the 1.5x threshold: kz_eff = 1366/1000 = 1.366.
  @mild_region %{"x" => 0, "y" => 0, "w" => 1000, "h" => 341}
  @mild_dims {1366, 466}

  defp start_session(opts \\ []) do
    dims =
      Keyword.get(opts, :dims, %{
        nil => {1366, 384},
        @incident_region => @incident_dims,
        @offcenter_region => @incident_dims,
        @mild_region => @mild_dims
      })

    driver_opts = [test_pid: self(), dims: dims, cursor: Keyword.get(opts, :cursor)]

    start_supervised!(
      {Session,
       [
         config: Config.normalize(enabled: true),
         driver: {GeomDriver, driver_opts},
         origin: :interactive,
         session_id: "cua_grid_#{System.unique_integer([:positive])}",
         agent: "main"
       ]}
    )
  end

  defp zoom_to(session, region) do
    {:ok, :auto, request} =
      Session.classify(session, %{"action" => "screenshot", "region" => region})

    {:ok, _} = Session.execute(session, request)
    session
  end

  describe "the wrong-grid tripwire (A1)" do
    test "the live incident click is refused with the exact conversion" do
      session = start_session() |> zoom_to(@incident_region)

      assert {:error, {:ambiguous_coordinates, info}} =
               Session.classify(session, %{
                 "action" => "left_click",
                 "x" => 400,
                 "y" => 265,
                 "region" => @incident_region
               })

      assert info.region == @incident_region
      assert info.view == %{"w" => 1355, "h" => 959}
      # (400-23)x2.811, (265-11)x2.811 — the point the model meant, in crop pixels.
      assert info.crop_equivalents == [{1060, 714}]
    end

    test "the corrected crop-space point executes" do
      session = start_session() |> zoom_to(@incident_region)

      assert {:ok, :auto, _request} =
               Session.classify(session, %{
                 "action" => "left_click",
                 "x" => 1060,
                 "y" => 714,
                 "region" => @incident_region
               })
    end

    test "confirm_grid re-sends the same point as crop pixels, and is stripped" do
      session = start_session() |> zoom_to(@incident_region)

      assert {:ok, :auto, request} =
               Session.classify(session, %{
                 "action" => "left_click",
                 "x" => 400,
                 "y" => 265,
                 "region" => @incident_region,
                 "confirm_grid" => true
               })

      refute Map.has_key?(request, "confirm_grid"),
             "the sidecar must never see the confirmation flag"
    end

    test "the rect is POSITIONED: an off-center window refuses inside r.x..r.x+r.w only" do
      session = start_session() |> zoom_to(@offcenter_region)

      # Inside the positioned rect [700,1182]x[40,381]: ambiguous.
      assert {:error, {:ambiguous_coordinates, _info}} =
               Session.classify(session, %{
                 "action" => "left_click",
                 "x" => 750,
                 "y" => 200,
                 "region" => @offcenter_region
               })

      # Left of the positioned rect — plausible ONLY as a crop pixel. An
      # origin-anchored (x <= w) test would wrongly refuse this.
      assert {:ok, :auto, _request} =
               Session.classify(session, %{
                 "action" => "left_click",
                 "x" => 400,
                 "y" => 265,
                 "region" => @offcenter_region
               })
    end

    test "magnification at or below the threshold never trips" do
      session = start_session() |> zoom_to(@mild_region)

      assert {:ok, :auto, _request} =
               Session.classify(session, %{
                 "action" => "left_click",
                 "x" => 400,
                 "y" => 265,
                 "region" => @mild_region
               })
    end

    test "a drag is ambiguous only when BOTH endpoints are inside the rect" do
      session = start_session() |> zoom_to(@incident_region)

      assert {:error, {:ambiguous_coordinates, info}} =
               Session.classify(session, %{
                 "action" => "left_click_drag",
                 "from" => %{"x" => 148, "y" => 279},
                 "to" => %{"x" => 148, "y" => 214},
                 "region" => @incident_region
               })

      assert length(info.crop_equivalents) == 2

      assert {:ok, :auto, _request} =
               Session.classify(session, %{
                 "action" => "left_click_drag",
                 "from" => %{"x" => 148, "y" => 279},
                 "to" => %{"x" => 900, "y" => 500},
                 "region" => @incident_region
               })
    end

    test "scroll and inspect coordinates are guarded like clicks" do
      session = start_session() |> zoom_to(@incident_region)

      assert {:error, {:ambiguous_coordinates, _info}} =
               Session.classify(session, %{
                 "action" => "scroll",
                 "x" => 240,
                 "y" => 170,
                 "direction" => "down",
                 "amount" => 3,
                 "region" => @incident_region
               })

      assert {:error, {:ambiguous_coordinates, _info}} =
               Session.classify(session, %{
                 "action" => "inspect",
                 "x" => 240,
                 "y" => 170,
                 "region" => @incident_region
               })
    end

    # The refusal exists to catch a model reading the wrong IMAGE grid; a view
    # established by `elements` has no image dims, and its points are copied
    # verbatim from the listing — nothing to trip on.
    test "a view established by elements (no image dims) never trips" do
      session = start_session()

      {:ok, :auto, elements} =
        Session.classify(session, %{"action" => "elements", "region" => @incident_region})

      {:ok, _} = Session.execute(session, elements)

      assert {:ok, :auto, _request} =
               Session.classify(session, %{
                 "action" => "left_click",
                 "x" => 40,
                 "y" => 50,
                 "region" => @incident_region
               })
    end

    # Exhaustive sweep of the predicate: with the incident view, a point refuses
    # iff it lies inside the positioned rect — never outside it.
    test "refusal iff the point is inside the positioned region rect" do
      session = start_session() |> zoom_to(@incident_region)
      %{"x" => rx, "y" => ry, "w" => rw, "h" => rh} = @incident_region

      for x <- [0, rx - 1, rx, rx + div(rw, 2), rx + rw, rx + rw + 1, 1300],
          y <- [0, ry - 1, ry, ry + div(rh, 2), ry + rh, ry + rh + 1, 900] do
        inside = x >= rx and x <= rx + rw and y >= ry and y <= ry + rh

        result =
          Session.classify(session, %{
            "action" => "left_click",
            "x" => x,
            "y" => y,
            "region" => @incident_region
          })

        if inside do
          assert {:error, {:ambiguous_coordinates, _info}} = result, "(#{x},#{y}) must refuse"
        else
          assert {:ok, :auto, _request} = result, "(#{x},#{y}) must execute"
        end
      end
    end
  end

  describe "dual-space cursor disclosure (A2)" do
    test "a magnified view's cursor carries its full-screen equivalent" do
      session = start_session(cursor: %{"x" => 400, "y" => 265})

      {:ok, :auto, request} =
        Session.classify(session, %{"action" => "screenshot", "region" => @incident_region})

      {:ok, result} = Session.execute(session, request)

      # 23 + 400/2.811 = 165, 11 + 265/2.811 = 105.
      assert result.summary =~ "Cursor at (400,265) = (165,105) on the full screen"
    end

    test "a full-screen view discloses no second grid" do
      session = start_session(cursor: %{"x" => 400, "y" => 265})

      {:ok, :auto, request} = Session.classify(session, %{"action" => "screenshot"})
      {:ok, result} = Session.execute(session, request)

      assert result.summary =~ "Cursor at (400,265)"
      refute result.summary =~ "on the full screen"
    end
  end
end
