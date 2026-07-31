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

  # Mirrors compux's v5 screenshot payload for the incident display: dims +
  # region echo, plus a canned mark table when `marks: true` rides the request.
  defmodule MarksDriver do
    @behaviour Compux.Driver

    @full_region %{"x" => 0, "y" => 0, "w" => 1366, "h" => 384}

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
      {w, h} = Map.fetch!(state.dims, request["region"])

      base = %{
        "ok" => true,
        "data" => Base.encode64("png"),
        "mime" => "image/png",
        "width" => w,
        "height" => h,
        "region" => request["region"] || @full_region
      }

      {:ok, if(request["marks"] == true, do: Map.put(base, "marks", state.marks), else: base)}
    end

    defp respond(state, %{"action" => "elements"}), do: {:ok, %{"elements" => state.elements}}
    defp respond(_state, _request), do: {:ok, %{"ok" => true}}

    @impl true
    def stop(_state), do: :ok
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

  describe "mark resolution (B3)" do
    test "a mark action resolves to the badge's exact point + region, wire x/y-only" do
      session = start_session()
      {:ok, result} = marks_screenshot(session)

      assert result.summary =~ "mark 1: AXButton \"Start game\" at (200,300)"
      assert result.summary =~ "`mark: <id>`"

      assert {:ok, :auto, request} =
               Session.classify(session, %{"action" => "left_click", "mark" => 2})

      assert request["x"] == 1100
      assert request["y"] == 700
      assert request["region"] == @incident_region
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
                 "region" => @incident_region
               })

      # …but the SAME point via its mark id is table-copied, not image-read.
      assert {:ok, :auto, request} =
               Session.classify(session, %{"action" => "left_click", "mark" => 1})

      assert {request["x"], request["y"]} == {200, 300}
    end

    test "an unknown mark id is refused with the live count" do
      session = start_session()
      {:ok, _} = marks_screenshot(session)

      assert {:error, {:unknown_mark, 9, 2}} =
               Session.classify(session, %{"action" => "left_click", "mark" => 9})
    end

    test "with no marks screenshot taken, a mark action is refused" do
      session = start_session()
      {:ok, _} = run(session, %{"action" => "screenshot"})

      assert {:error, :no_marks} =
               Session.classify(session, %{"action" => "left_click", "mark" => 1})
    end

    test "a marks-less screenshot clears the table — the screen it described is gone" do
      session = start_session()
      {:ok, _} = marks_screenshot(session)
      {:ok, _} = run(session, %{"action" => "screenshot", "region" => @incident_region})

      assert {:error, :no_marks} =
               Session.classify(session, %{"action" => "left_click", "mark" => 1})
    end

    test "marks from a view the model has left are stale" do
      session =
        start_session(elements: [%{"role" => "AXButton", "x" => 40, "y" => 50}])

      {:ok, _} = marks_screenshot(session)
      # Usable elements on a DIFFERENT region move the view; the badges describe
      # a crop the model is no longer reading.
      {:ok, _} = run(session, %{"action" => "elements", "region" => @other_region})

      assert {:error, {:stale_marks, @incident_region}} =
               Session.classify(session, %{"action" => "left_click", "mark" => 1})
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
          "region" => @incident_region
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
          "region" => @incident_region
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
