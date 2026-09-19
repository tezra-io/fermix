defmodule FermixCore.ComputerUse.MarksTest do
  @moduledoc """
  M28 B1–B3, fermix side: set-of-marks resolution (a `mark: N` action resolves to
  the badge's exact point HERE, keeping the wire x/y-only and the respawnable
  sidecar stateless), mark staleness (a badge from a view the model has left is a
  wrong-element click waiting to happen — refused, never guessed), and the
  grounding-integrity stamps the session adds to its own capture requests
  (`rulers` on every tool capture, `annotate_point` on the crop check so the
  model SEES where its click landed).
  """

  use ExUnit.Case, async: true

  alias FermixCore.ComputerUse.Config
  alias FermixCore.ComputerUse.Session

  # Mirrors compux's screenshot payload for the incident display: dims plus the
  # minted `observation_id` (protocol 8), and a canned mark table when
  # `marks: true` rides the request.
  defmodule MarksDriver do
    @behaviour Compux.Driver

    @impl true
    def start(opts) do
      {:ok,
       %{
         test_pid: Keyword.fetch!(opts, :test_pid),
         dims: Keyword.fetch!(opts, :dims),
         marks: Keyword.get(opts, :marks, []),
         elements: Keyword.get(opts, :elements, [])
       }}
    end

    @impl true
    def execute(state, request) do
      send(state.test_pid, {:driver_execute, request})
      respond(state, request)
    end

    defp respond(state, %{"action" => "screenshot"} = request) do
      {w, h} = sent_dims(state, request)

      base =
        FermixTestSupport.ComputerUseObservations.stamp(
          %{
            "ok" => true,
            "data" => Base.encode64("png"),
            "mime" => "image/png",
            "width" => w,
            "height" => h,
            # The helper always echoes the rectangle it RESOLVED, in full-display
            # image pixels — the one space a crop can be positioned in.
            "region" => FermixTestSupport.ComputerUseObservations.resolved_region(request)
          },
          request,
          id: image_id(request["region"])
        )

      {:ok, if(request["marks"] == true, do: Map.put(base, "marks", state.marks), else: base)}
    end

    defp respond(state, %{"action" => "elements"} = request),
      do:
        {:ok,
         FermixTestSupport.ComputerUseObservations.stamp(
           %{"elements" => state.elements},
           request,
           id: "obs-elements"
         )}

    # Every mutating reply carries the wire's `receipt` (M42 slice 2 §3), which is
    # what the session's `outcome` is derived from.
    defp respond(_state, request),
      do: {:ok, FermixTestSupport.ComputerUseReceipts.stamp(%{"ok" => true}, request)}

    @impl true
    def stop(_state), do: :ok

    # A check re-capture NAMES the image it re-captures and asks for the whole of
    # it in that image's own pixels, so it comes back at that image's size; every
    # other capture is a rectangle of the display, whose sent size the test maps.
    defp sent_dims(_state, %{"observation_id" => id, "region" => %{"w" => w, "h" => h}})
         when is_binary(id),
         do: {w, h}

    defp sent_dims(state, request), do: Map.fetch!(state.dims, request["region"])

    # One id per rectangle: two different crops are two different images, and a
    # badge belongs to the image it was drawn on.
    defdelegate image_id(region), to: FermixTestSupport.ComputerUseObservations
  end

  @incident_region %{"x" => 23, "y" => 11, "w" => 482, "h" => 341}
  @incident_dims {1355, 959}
  @other_region %{"x" => 600, "y" => 20, "w" => 400, "h" => 300}

  # Mark 1 sits INSIDE the positioned ambiguity rect — the exact point a raw
  # click would be refused for — proving mark resolution bypasses the tripwire.
  @marks [
    %{"id" => 1, "role" => "AXButton", "title" => "Start game", "x" => 200, "y" => 300},
    %{"id" => 2, "role" => "AXLink", "title" => "Chess", "x" => 1100, "y" => 700}
  ]

  defp start_session(opts \\ []) do
    dims =
      Keyword.get(opts, :dims, %{
        nil => {1366, 384},
        @incident_region => @incident_dims,
        @other_region => {1124, 843}
      })

    driver_opts = [
      test_pid: self(),
      dims: dims,
      marks: Keyword.get(opts, :marks, @marks),
      elements: Keyword.get(opts, :elements, [])
    ]

    start_supervised!(
      {Session,
       [
         config: Config.normalize(enabled: true),
         driver: {MarksDriver, driver_opts},
         origin: :interactive,
         session_id: "cua_marks_#{System.unique_integer([:positive])}",
         agent: "main"
       ]}
    )
  end

  defp run(session, params) do
    {:ok, :auto, request} = Session.classify(session, params)
    Session.execute(session, request)
  end

  defp marks_screenshot(session, region \\ @incident_region) do
    run(session, %{"action" => "screenshot", "region" => region, "marks" => true})
  end

  # The image a crop of `region` was returned as — every action aimed in it names
  # this id, a mark included.
  defp image_of(region), do: MarksDriver.image_id(region)

  describe "mark resolution (B3)" do
    test "a mark action resolves to the badge's exact point + region, wire x/y-only" do
      session = start_session()
      {:ok, result} = marks_screenshot(session)

      assert result.summary =~ "mark 1: AXButton \"Start game\" at (200,300)"
      assert result.summary =~ "`mark: <id>`"

      assert {:ok, :auto, request} =
               Session.classify(session, %{
                 "action" => "left_click",
                 "mark" => 2,
                 "observation_id" => image_of(@incident_region)
               })

      assert request["x"] == 1100
      assert request["y"] == 700
      # A mark names its image like any other coordinate, and the helper never
      # sees a mark id: the badge table is resolved here.
      assert request["observation_id"] == image_of(@incident_region)
      refute Map.has_key?(request, "mark"), "the sidecar must never see a mark id"
    end

    test "a resolved mark bypasses the ambiguity tripwire" do
      session = start_session()
      {:ok, _} = marks_screenshot(session)

      # Raw click at mark 1's point is inside the positioned rect — refused…
      assert {:error, {:ambiguous_coordinates, _info}} =
               Session.classify(session, %{
                 "action" => "left_click",
                 "x" => 200,
                 "y" => 300,
                 "observation_id" => image_of(@incident_region)
               })

      # …but the SAME point via its mark id is table-copied, not image-read.
      assert {:ok, :auto, request} =
               Session.classify(session, %{
                 "action" => "left_click",
                 "mark" => 1,
                 "observation_id" => image_of(@incident_region)
               })

      assert {request["x"], request["y"]} == {200, 300}
    end

    test "an unknown mark id is refused with the live count" do
      session = start_session()
      {:ok, _} = marks_screenshot(session)

      assert {:error, {:unknown_mark, 9, 2}} =
               Session.classify(session, %{
                 "action" => "left_click",
                 "mark" => 9,
                 "observation_id" => image_of(@incident_region)
               })
    end

    test "with no marks screenshot taken, a mark action is refused" do
      session = start_session()
      {:ok, _} = run(session, %{"action" => "screenshot"})

      assert {:error, :no_marks} =
               Session.classify(session, %{
                 "action" => "left_click",
                 "mark" => 1,
                 "observation_id" => image_of(@incident_region)
               })
    end

    test "a marks-less screenshot clears the table — the screen it described is gone" do
      session = start_session()
      {:ok, _} = marks_screenshot(session)
      {:ok, _} = run(session, %{"action" => "screenshot", "region" => @incident_region})

      assert {:error, :no_marks} =
               Session.classify(session, %{
                 "action" => "left_click",
                 "mark" => 1,
                 "observation_id" => image_of(@incident_region)
               })
    end

    # Staleness is gone as a concept: a badge belongs to the image it was drawn
    # on, so a later look cannot make it wrong — and naming a DIFFERENT image
    # means naming one that was never badged, which is a plain absence.
    test "a mark belongs to the image it was badged on, not to the latest look" do
      session = start_session(elements: [%{"role" => "AXButton", "x" => 40, "y" => 50}])

      {:ok, _} = marks_screenshot(session)
      {:ok, _} = run(session, %{"action" => "elements", "region" => @other_region})

      # The badged image is still addressable, and its numbers still resolve.
      assert {:ok, :auto, request} =
               Session.classify(session, %{
                 "action" => "left_click",
                 "mark" => 1,
                 "observation_id" => image_of(@incident_region)
               })

      assert {request["x"], request["y"]} == {200, 300}

      # A different image was never badged, so its numbers are a plain absence.
      assert {:error, :no_marks} =
               Session.classify(session, %{
                 "action" => "left_click",
                 "mark" => 1,
                 "observation_id" => "obs-elements"
               })
    end

    test "zero marks is a loud absence in the summary" do
      session = start_session(marks: [])
      {:ok, result} = marks_screenshot(session)

      assert result.summary =~ "0 accessibility marks"
    end
  end

  describe "grounding stamps (B1/B2)" do
    test "every tool capture carries rulers; the crop check adds the executed point" do
      session = start_session()
      {:ok, _} = run(session, %{"action" => "screenshot", "region" => @incident_region})
      assert_receive {:driver_execute, %{"action" => "screenshot", "rulers" => true}}

      {:ok, :auto, click} =
        Session.classify(session, %{
          "action" => "left_click",
          "x" => 1060,
          "y" => 714,
          "observation_id" => image_of(@incident_region)
        })

      {:ok, _} = Session.execute(session, click)

      assert_receive {:driver_execute, %{"action" => "left_click", "rulers" => true}}

      assert_receive {:driver_execute,
                      %{
                        "action" => "screenshot",
                        "rulers" => true,
                        "annotate_point" => %{"x" => 1060, "y" => 714}
                      }}
    end

    test "a drag's check marks the drag DESTINATION" do
      session = start_session()
      {:ok, _} = run(session, %{"action" => "screenshot", "region" => @incident_region})

      {:ok, :auto, drag} =
        Session.classify(session, %{
          "action" => "left_click_drag",
          "from" => %{"x" => 600, "y" => 400},
          "to" => %{"x" => 900, "y" => 500},
          "observation_id" => image_of(@incident_region)
        })

      {:ok, _} = Session.execute(session, drag)

      assert_receive {:driver_execute,
                      %{"action" => "screenshot", "annotate_point" => %{"x" => 900, "y" => 500}}}
    end
  end

  describe "elements activation note (B4)" do
    defmodule AxNoteDriver do
      @behaviour Compux.Driver

      @impl true
      def start(_opts), do: {:ok, %{}}

      @impl true
      def execute(_state, %{"action" => "elements"}),
        do:
          {:ok,
           %{
             "elements" => [],
             "ax_activation" => "AXManualAccessibility activated; 0 element(s) after"
           }}

      def execute(_state, _request),
        do: {:ok, %{"data" => Base.encode64("png"), "mime" => "image/png"}}

      @impl true
      def stop(_state), do: :ok
    end

    test "the activation outcome reaches the model instead of a silent empty list" do
      session =
        start_supervised!(
          {Session,
           [
             config: Config.normalize(enabled: true),
             driver: {AxNoteDriver, []},
             origin: :interactive,
             session_id: "cua_ax_note",
             agent: "main"
           ]}
        )

      {:ok, :auto, request} = Session.classify(session, %{"action" => "elements"})
      {:ok, result} = Session.execute(session, request)

      assert result.summary =~ "no accessibility-backed click targets"
      assert result.summary =~ "AX: AXManualAccessibility activated"
    end
  end
end
