defmodule FermixCore.ComputerUse.AddressingTest do
  @moduledoc """
  Coordinates are pixels in the image you name (M42 slice 3).

  This replaces the coordinate-space guard, whose job was to notice that the model
  had forgotten to copy a `region` rectangle onto its follow-up click. Observed
  live (2026-07-25, chess on a 3840x1080 display): the agent zoomed to a 600x380
  crop, then clicked without the region — the pointer landed ~2.3x off and the move
  never happened. Observed again a day later, from the other side: the check image
  a mutating action returned was the FULL display while the session labelled it a
  magnified crop, so the model read coordinates off a mislabelled image.

  Both are gone as a class. Every reply that hands back coordinates names the image
  they were read in, every action names the image its coordinates came from, and
  the helper holds the transform it made that image with. What is pinned here is
  the Fermix half: the addressing refusal before any driver call, the check taken
  in the image the action was aimed in, and the text that names the image beside
  the picture it describes.
  """

  use ExUnit.Case, async: true

  alias FermixCore.ComputerUse.Config
  alias FermixCore.ComputerUse.Session
  alias FermixTestSupport.ComputerUseObservations

  # Mirrors compux: a reply that hands back coordinates mints an observation, and
  # a mutating reply carries a receipt. One id per requested rectangle, so two
  # different crops are two different images.
  defmodule ImageDriver do
    @behaviour Compux.Driver

    @impl true
    def start(opts) do
      {:ok,
       %{
         test_pid: Keyword.fetch!(opts, :test_pid),
         elements: Keyword.get(opts, :elements, []),
         cursor: Keyword.get(opts, :cursor)
       }}
    end

    @impl true
    def execute(state, request) do
      send(state.test_pid, {:driver_execute, request})
      respond(state, request)
    end

    # A mutating action asking for an image check comes back AS that image: the
    # view it acted in, re-captured by the helper on the action's own frame and
    # minting an id of its own. Its rectangle is the one the named image was a crop
    # of, because that is the view it re-captured.
    defp respond(state, %{"action" => action, "check" => "image"} = request)
         when action in ~w(left_click right_click double_click left_click_drag scroll) do
      region = checked_region(request)
      {w, h} = check_dims(region)

      base =
        %{
          "ok" => true,
          "data" => Base.encode64("png"),
          "mime" => "image/png",
          "width" => w,
          "height" => h,
          "region" => region,
          "observation_id" => check_id(request["observation_id"]),
          "observation_kind" => "image",
          "captured_at_monotonic_ns" => 1_000
        }
        |> FermixTestSupport.ComputerUseReceipts.stamp(request)

      {:ok, if(state.cursor, do: Map.put(base, "cursor", state.cursor), else: base)}
    end

    defp respond(_state, %{"action" => action} = request)
         when action in ~w(left_click right_click double_click left_click_drag scroll) do
      {:ok, FermixTestSupport.ComputerUseReceipts.stamp(%{"ok" => true}, request)}
    end

    defp respond(state, %{"action" => action} = request)
         when action in ~w(screenshot wait_for_change) do
      {w, h} = sent_dims(request)

      base =
        ComputerUseObservations.stamp(
          %{
            "ok" => true,
            "data" => Base.encode64("png"),
            "mime" => "image/png",
            "width" => w,
            "height" => h,
            # The helper always echoes the rectangle it RESOLVED, in full-display
            # image pixels — the one space a crop can be positioned in.
            "region" => ComputerUseObservations.resolved_region(request)
          },
          request,
          id: image_id(request["region"])
        )

      {:ok, if(state.cursor, do: Map.put(base, "cursor", state.cursor), else: base)}
    end

    defp respond(state, %{"action" => "elements"} = request),
      do:
        {:ok,
         ComputerUseObservations.stamp(%{"elements" => state.elements}, request,
           id: "obs-elements"
         )}

    # `inspect` answers with the element under the point and carries NO pixels: it
    # reads coordinates rather than producing them, so it mints nothing.
    defp respond(_state, %{"action" => "inspect"}),
      do: {:ok, %{"found" => true, "role" => "AXButton", "title" => "Play"}}

    defp respond(_state, %{"action" => "windows"} = request) do
      {:ok,
       ComputerUseObservations.stamp(
         %{
           "windows" => [
             %{
               "app" => "Google Chrome",
               "title" => "lichess.org",
               "focused" => true,
               "region" => %{"x" => 120, "y" => 30, "w" => 560, "h" => 340}
             }
           ]
         },
         request,
         id: "obs-windows"
       )}
    end

    defp respond(_state, %{"action" => "idle_ms"}),
      do: {:ok, %{"ok" => true, "idle_ms" => 10_000}}

    defp respond(_state, request),
      do: {:ok, FermixTestSupport.ComputerUseReceipts.stamp(%{"ok" => true}, request)}

    @impl true
    def stop(_state), do: :ok

    # A view named as an observation is re-read from its id, which encodes the
    # rectangle it was a crop of; the full display sends 1366x384 and a crop is
    # magnified to 1200x760.
    defp sent_dims(%{"observation_id" => id, "region" => %{"w" => w, "h" => h}})
         when is_binary(id),
         do: {w, h}

    defp sent_dims(%{"region" => region}) when is_map(region), do: {1200, 760}
    defp sent_dims(_request), do: {1366, 384}

    # The check re-captures the view the action was aimed in, so it echoes THAT
    # rectangle: the crop's own for a crop, the whole display's otherwise.
    defp checked_region(%{"observation_id" => id}), do: ComputerUseObservations.region_of(id)

    defp check_dims(nil), do: {1366, 384}
    defp check_dims(_region), do: {1200, 760}

    defp check_id(id), do: "#{id}-check"

    defdelegate image_id(region), to: ComputerUseObservations
  end

  defmodule EmptyWindowsDriver do
    @behaviour Compux.Driver

    @impl true
    def start(_opts), do: {:ok, %{}}

    @impl true
    def execute(_state, _request), do: {:ok, %{"windows" => []}}

    @impl true
    def stop(_state), do: :ok
  end

  # Looking works; the capture an action's own check needs does not. The helper
  # then answers the ACTION with a refusal whose receipt says the input already
  # went out and which carries no check at all — the input landed, the look did
  # not, and both halves are on one frame.
  defmodule FailingCheckDriver do
    @behaviour Compux.Driver

    @impl true
    def start(_opts), do: {:ok, %{}}

    @impl true
    def execute(_state, %{"action" => "screenshot"} = request) do
      {:ok,
       ComputerUseObservations.stamp(
         %{
           "data" => Base.encode64("png"),
           "mime" => "image/png",
           "width" => 1200,
           "height" => 760,
           "region" => ComputerUseObservations.resolved_region(request)
         },
         request
       )}
    end

    def execute(_state, %{"check" => "image"}) do
      {:error,
       {:action_failed,
        %{
          "error" => "capture_failed",
          "receipt" => FermixTestSupport.ComputerUseReceipts.receipt(:sent, check: nil)
        }}}
    end

    def execute(_state, request),
      do: {:ok, FermixTestSupport.ComputerUseReceipts.stamp(%{"ok" => true}, request)}

    @impl true
    def stop(_state), do: :ok
  end

  @region %{"x" => 0, "y" => 0, "w" => 600, "h" => 380}
  @crop ImageDriver.image_id(@region)
  @full ImageDriver.image_id(nil)

  defp start_session(opts \\ []) do
    driver_opts = [
      test_pid: self(),
      elements: Keyword.get(opts, :elements, []),
      cursor: Keyword.get(opts, :cursor)
    ]

    start_supervised!(
      {Session,
       [
         config: Config.normalize(enabled: true),
         driver: {ImageDriver, driver_opts},
         origin: :interactive,
         session_id: "cua_addressing_#{System.unique_integer([:positive])}",
         agent: "main"
       ]}
    )
  end

  defp run(session, params) do
    {:ok, :auto, request} = Session.classify(session, params)
    Session.execute(session, request)
  end

  describe "an action names the image its coordinates came from" do
    test "every pointer action without an observation_id is refused before any driver call" do
      session = start_session()
      {:ok, _} = run(session, %{"action" => "screenshot"})

      for action <- ~w(left_click right_click double_click mouse_move inspect) do
        assert {:error, :observation_required} =
                 Session.classify(session, %{"action" => action, "x" => 10, "y" => 10}),
               "#{action} must name the image its coordinates came from"
      end

      assert {:error, :observation_required} =
               Session.classify(session, %{
                 "action" => "left_click_drag",
                 "from" => %{"x" => 10, "y" => 10},
                 "to" => %{"x" => 20, "y" => 20}
               })

      assert {:error, :observation_required} =
               Session.classify(session, %{
                 "action" => "scroll",
                 "x" => 10,
                 "y" => 10,
                 "direction" => "down",
                 "amount" => 3
               })

      refute_received {:driver_execute, %{"action" => "left_click"}}
    end

    test "the same action WITH one reaches the helper, carrying the id and no region" do
      session = start_session()
      {:ok, _} = run(session, %{"action" => "screenshot"})

      assert {:ok, :auto, request} =
               Session.classify(session, %{
                 "action" => "left_click",
                 "observation_id" => @full,
                 "x" => 180,
                 "y" => 150
               })

      assert request["observation_id"] == @full
      refute Map.has_key?(request, "region"), "a pointer action carries no rectangle"
    end

    # The helper holds the transform and re-reads the display's geometry before
    # every pointer action, so it is the authority on which ids still resolve. This
    # side refuses only the question it can answer without asking: whether an image
    # was named at all.
    test "an id this side does not hold is still sent — the helper answers for it" do
      session = start_session()
      {:ok, _} = run(session, %{"action" => "screenshot"})

      assert {:ok, :auto, request} =
               Session.classify(session, %{
                 "action" => "left_click",
                 "observation_id" => "obs-from-a-dead-helper",
                 "x" => 1,
                 "y" => 2
               })

      assert request["observation_id"] == "obs-from-a-dead-helper"
    end

    test "keyboard actions are never addressed — they carry no coordinates" do
      session = start_session()
      {:ok, _} = run(session, %{"action" => "screenshot", "region" => @region})

      assert {:ok, :auto, _} = Session.classify(session, %{"action" => "type", "text" => "e4"})
      assert {:ok, :auto, _} = Session.classify(session, %{"action" => "key", "chord" => "enter"})
    end

    # A crop and the full screen are two images at once: both stay addressable, so
    # the model may aim in whichever it is actually reading rather than being
    # refused for having looked at something else since.
    test "a later look does not un-address an earlier image" do
      session = start_session()
      {:ok, _} = run(session, %{"action" => "screenshot", "region" => @region})
      {:ok, _} = run(session, %{"action" => "screenshot"})

      for id <- [@crop, @full] do
        assert {:ok, :auto, _} =
                 Session.classify(session, %{
                   "action" => "left_click",
                   "observation_id" => id,
                   "x" => 900,
                   "y" => 400
                 })
      end
    end
  end

  describe "the check is taken in the image the action was aimed in" do
    test "an action aimed in a crop is checked by a re-capture of that crop" do
      session = start_session()
      {:ok, _} = run(session, %{"action" => "screenshot", "region" => @region})
      assert_receive {:driver_execute, %{"action" => "screenshot"}}

      {:ok, :auto, click} =
        Session.classify(session, %{
          "action" => "left_click",
          "observation_id" => @crop,
          "x" => 900,
          "y" => 400
        })

      {:ok, result} = Session.execute(session, click)

      # One call. The helper holds the transform it made that image with, so the
      # check is the same crop of the same screen without a second request and
      # without this side re-deriving a screen rectangle.
      assert_receive {:driver_execute, %{"action" => "left_click", "check" => "image"}}
      refute_receive {:driver_execute, %{"action" => "screenshot"}}, 50

      assert %{data: "png"} = result.image
      assert result.summary =~ "Coordinates are pixels in this exact image"
    end

    test "an action aimed in a full-screen image is checked in the full screen" do
      session = start_session()
      {:ok, _} = run(session, %{"action" => "screenshot"})
      assert_receive {:driver_execute, %{"action" => "screenshot"}}

      {:ok, :auto, click} =
        Session.classify(session, %{
          "action" => "left_click",
          "observation_id" => @full,
          "x" => 900,
          "y" => 300
        })

      {:ok, result} = Session.execute(session, click)

      assert_receive {:driver_execute, %{"action" => "left_click", "check" => "image"}}
      refute_receive {:driver_execute, %{"action" => "screenshot"}}, 50
      assert result.summary =~ "1366x384"
    end

    # The check image is the one the model now reads, so it is the one the model's
    # next action names — and it inherits the crop's rectangle, so the wrong-grid
    # tripwire keeps judging later points against the rectangle the model could
    # still be reading coordinates on.
    test "the check mints the image the next action names, inheriting the crop" do
      session = start_session()
      {:ok, _} = run(session, %{"action" => "screenshot", "region" => @region})

      {:ok, :auto, click} =
        Session.classify(session, %{
          "action" => "left_click",
          "observation_id" => @crop,
          "x" => 900,
          "y" => 400
        })

      {:ok, result} = Session.execute(session, click)
      check_id = "#{@crop}-check"

      assert result.summary =~ "Image #{check_id}"

      assert {:ok, :auto, _} =
               Session.classify(session, %{
                 "action" => "left_click",
                 "observation_id" => check_id,
                 "x" => 900,
                 "y" => 400
               })

      # Inherited: a point inside the crop's own rectangle is still ambiguous.
      assert {:error, {:ambiguous_coordinates, _}} =
               Session.classify(session, %{
                 "action" => "left_click",
                 "observation_id" => check_id,
                 "x" => 100,
                 "y" => 100
               })
    end

    # The click DID land; reporting an error would make the model retry it (a
    # double click on the real desktop). Report it done, say the check is missing,
    # and leave every image the model can still name where it was.
    test "a failed check reports the action done and unverified, addressing unchanged" do
      session =
        start_supervised!(
          {Session,
           [
             config: Config.normalize(enabled: true),
             driver: {FailingCheckDriver, []},
             origin: :interactive,
             session_id: "cua_check_fail",
             agent: "main"
           ]}
        )

      {:ok, _} = run(session, %{"action" => "screenshot", "region" => @region})

      {:ok, :auto, click} =
        Session.classify(session, %{
          "action" => "left_click",
          "observation_id" => ComputerUseObservations.id(),
          "x" => 900,
          "y" => 400
        })

      assert {:ok, result} = Session.execute(session, click)
      assert result.image == nil
      assert result.outcome == :performed_unverified
      assert result.summary =~ "check capture failed"
      assert result.summary =~ "the action itself was sent"
      # What failed is the LOOK. Saying the action failed buys a second real click.
      refute result.summary =~ "action failed"
      # No image came back, so no text may claim the model is looking at one.
      refute result.summary =~ "Coordinates are pixels in this exact image"

      assert {:ok, :auto, _} =
               Session.classify(session, %{
                 "action" => "left_click",
                 "observation_id" => ComputerUseObservations.id(),
                 "x" => 900,
                 "y" => 400
               })
    end
  end

  describe "the text names the image beside the picture it describes" do
    test "a screenshot leads with its id, its size and the one rule" do
      session = start_session()

      {:ok, result} = run(session, %{"action" => "screenshot", "region" => @region})

      assert result.summary =~
               "Image #{@crop}, 1200x760 (display 0). Coordinates are pixels in this exact " <>
                 "image: pass observation_id \"#{@crop}\" with any click, move, drag, scroll " <>
                 "or inspect."
    end

    # The helper's screenshot reply carries no `display` key, so the number has to
    # come from the request that asked for the capture. Reading it off the response
    # announced every image on every display as display 0.
    test "the display announced is the one the capture was taken on" do
      session = start_session()

      {:ok, result} = run(session, %{"action" => "screenshot", "display" => 1})

      assert result.summary =~ "(display 1)."
      refute result.summary =~ "(display 0)"
    end

    test "an elements listing names the image its points were read in" do
      session = start_session(elements: [%{"role" => "AXButton", "x" => 180, "y" => 150}])

      {:ok, result} = run(session, %{"action" => "elements", "region" => @region})

      assert result.summary =~
               "List obs-elements. The coordinates below are pixels in the image this list " <>
                 "was read from: pass observation_id \"obs-elements\" with any click, move, " <>
                 "drag, scroll or inspect."

      assert result.summary =~ "AXButton"
    end

    test "a windows listing does the same, and its regions are copied verbatim" do
      session = start_session()

      {:ok, result} = run(session, %{"action" => "windows"})

      assert result.summary =~ "List obs-windows."
      assert result.summary =~ ~s(pass observation_id "obs-windows")
      assert result.summary =~ "Google Chrome"
      assert result.summary =~ "[focused]"
      assert result.summary =~ ~s(region {"x": 120, "y": 30, "w": 560, "h": 340})
      assert result.image == nil, "a window listing carries no pixels"
    end

    # An empty desktop and a missing screen-recording grant look identical from
    # here, so the text must not assert "empty".
    test "an empty window listing names the likely cause" do
      session =
        start_supervised!(
          {Session,
           [
             config: Config.normalize(enabled: true),
             driver: {EmptyWindowsDriver, []},
             origin: :interactive,
             session_id: "cua_no_windows",
             agent: "main"
           ]}
        )

      {:ok, result} = run(session, %{"action" => "windows"})

      assert result.summary =~ "permission"
    end

    # `inspect` reads coordinates rather than producing them, so it mints nothing
    # and leaves the image the model is aiming in exactly where it was.
    test "an inspect result names no image of its own" do
      session = start_session()
      {:ok, _} = run(session, %{"action" => "screenshot", "region" => @region})

      {:ok, result} =
        run(session, %{"action" => "inspect", "observation_id" => @crop, "x" => 900, "y" => 400})

      assert result.image == nil
      assert result.summary =~ "AXButton"
      refute result.summary =~ "Coordinates are pixels"
    end
  end

  # Since the pointer warp, a click's check cursor lands on target even when macOS
  # is silently DROPPING the button events (Accessibility not granted): capture
  # works, input does not, and every action "verifies delivered". The probe reads
  # the grant state without prompting; a refused mutating action is one loud, typed
  # error instead of a whole run of no-ops.
  describe "input-control gate" do
    defmodule NoInputDriver do
      @behaviour Compux.Driver

      @impl true
      def start(_opts), do: {:ok, %{}}

      @impl true
      def execute(_state, %{"action" => "probe"}),
        do: {:ok, %{"ok" => true, "screen_capture" => true, "input_control" => false}}

      def execute(_state, request),
        do:
          {:ok,
           ComputerUseObservations.stamp(
             %{"data" => Base.encode64("png"), "mime" => "image/png"},
             request
           )}

      @impl true
      def stop(_state), do: :ok
    end

    setup do
      session =
        start_supervised!(
          {Session,
           [
             config: Config.normalize(enabled: true),
             driver: {NoInputDriver, []},
             origin: :interactive,
             session_id: "cua_no_input",
             agent: "main"
           ]}
        )

      %{session: session}
    end

    test "mutating actions are refused with the recovery named", %{session: session} do
      assert {:error, {:refused, :input_control_denied}} =
               Session.classify(session, %{
                 "action" => "left_click",
                 "observation_id" => ComputerUseObservations.id(),
                 "x" => 10,
                 "y" => 10
               })
    end

    test "looking still works without the input grant", %{session: session} do
      assert {:ok, _result} = run(session, %{"action" => "screenshot"})
    end
  end

  # A click's check screenshot reports where the pointer ACTUALLY is, and the OS
  # puts the mouse-button events at that same point — so cursor != aimed-at means
  # the aim is NOT confirmed. Observed live 2026-07-26: 4 of 7 clicks landed at the
  # PREVIOUS click's point and every one of them reported success. The evidence is
  # reported; the verdict is not, because a human moving the mouse after a click
  # that DID land leaves exactly the same trace, and "it did nothing" buys a double
  # submit.
  describe "click delivery" do
    defp click_with_cursor(cursor, click_at) do
      session = start_session(cursor: cursor)
      {:ok, _} = run(session, %{"action" => "screenshot", "region" => @region})

      {:ok, :auto, click} =
        Session.classify(
          session,
          Map.merge(%{"action" => "left_click", "observation_id" => @crop}, click_at)
        )

      {:ok, result} = Session.execute(session, click)
      result
    end

    test "a click whose pointer reached the target is reported plainly" do
      result = click_with_cursor(%{"x" => 900, "y" => 400}, %{"x" => 900, "y" => 400})

      refute result.summary =~ "NOT confirmed"
      assert result.summary =~ "Cursor at (900,400)."
      assert result.outcome == :performed
    end

    # Retina round-trip: a crop pixel quantizes to an integer logical point and the
    # cursor read multiplies back, so a perfectly delivered click can read back off
    # by a pixel or two on a scale-factor-2 display. Exact equality turned ~3 of 4
    # zoomed clicks into a false "NOT delivered" loop of REAL clicks.
    test "a cursor within the rounding tolerance still counts as delivered" do
      result = click_with_cursor(%{"x" => 901, "y" => 399}, %{"x" => 900, "y" => 400})

      refute result.summary =~ "NOT confirmed"
    end

    test "a genuine miss outside the tolerance is still reported" do
      result = click_with_cursor(%{"x" => 904, "y" => 400}, %{"x" => 900, "y" => 400})

      assert result.summary =~ "Aim NOT confirmed at (900,400)"
      assert result.summary =~ "in the image named above"
      assert result.summary =~ "Cursor at (904,400)."
    end

    # The receipt reports the evidence; it must never turn that evidence into a
    # verdict on the input. "This action did nothing, re-send it" is an instruction
    # to double-submit whatever DID land.
    test "the aim notice never claims a dispatched action did nothing" do
      result = click_with_cursor(%{"x" => 377, "y" => 472}, %{"x" => 900, "y" => 400})

      refute result.summary =~ "did nothing"
      refute result.summary =~ "never reached"
      assert result.summary =~ "Read this image"
      assert result.summary =~ "only if it shows the effect is missing"
      assert result.outcome == :performed
    end

    # Drags carry from/to instead of x/y; their delivery evidence is the pointer
    # resting at the drag's END point.
    test "a drag whose pointer never reached the destination is reported" do
      session = start_session(cursor: %{"x" => 20, "y" => 20})
      {:ok, _} = run(session, %{"action" => "screenshot", "region" => @region})

      {:ok, :auto, drag} =
        Session.classify(session, %{
          "action" => "left_click_drag",
          "observation_id" => @crop,
          "from" => %{"x" => 700, "y" => 500},
          "to" => %{"x" => 900, "y" => 600}
        })

      {:ok, result} = Session.execute(session, drag)

      assert result.summary =~ "Aim NOT confirmed at (900,600)"
    end

    test "a check that reports no cursor cannot confirm the aim, so it says so" do
      result = click_with_cursor(nil, %{"x" => 900, "y" => 400})

      assert result.summary =~ "Aim NOT confirmed at (900,400)"
    end
  end
end
