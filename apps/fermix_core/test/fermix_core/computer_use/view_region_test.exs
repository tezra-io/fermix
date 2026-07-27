defmodule FermixCore.ComputerUse.ViewRegionTest do
  @moduledoc """
  The coordinate-space guard: after a `region` screenshot the model is reading a
  MAGNIFIED crop, so a follow-up click must carry the same region or its x,y are
  read in full-screen space and land somewhere else.

  Observed live (2026-07-25, chess on a 3840x1080 display): the agent zoomed to a
  600x380 crop, then clicked without the region — the pointer landed ~2.3x off and
  the move never happened. These pin the fix.

  Second live incident (2026-07-26, same display): the check image a mutating
  action returns is deliberately the FULL display (compux `post/2`), but the
  session labeled it a MAGNIFIED CROP and kept the crop as the view. The model
  read coordinates off a mislabeled full-screen image, its zoom regions drifted
  off the window (an `inspect` resolved to the desktop), and no move ever
  landed. The label and the tracked view must describe the RESPONSE, never echo
  the request.

  Same day, after honest labels: the full-screen check proved USELESS on that
  display (the board is ~100px tall in it), so the model re-zoomed after every
  single click — correct, but doubling its actions. Hence `crop_check/3`: a
  zoomed mutating action skips compux's full-screen check (`screenshot_after:
  false`) and is answered by a SAME-region screenshot instead, so a request
  carrying a region always yields crop-space content and verification costs no
  extra round trip.
  """

  use ExUnit.Case, async: true

  alias FermixCore.ComputerUse.Config
  alias FermixCore.ComputerUse.Session

  defmodule ImageDriver do
    @behaviour Compux.Driver

    @impl true
    def start(opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}

    @impl true
    def execute(%{test_pid: pid}, request) do
      send(pid, {:driver_execute, request})

      case request["action"] do
        # Mirror compux: with `screenshot_after: false` a mutating action
        # returns a bare ack — the session takes its own crop check.
        action when action in ~w(left_click right_click double_click left_click_drag scroll) ->
          if request["screenshot_after"] == false,
            do: {:ok, %{"ok" => true}},
            else: {:ok, %{"data" => Base.encode64("png"), "mime" => "image/png"}}

        # Only pixel-returning actions move the view; these must not.
        "elements" ->
          {:ok, %{"elements" => []}}

        "windows" ->
          {:ok,
           %{
             "windows" => [
               %{
                 "app" => "Google Chrome",
                 "title" => "lichess.org",
                 "focused" => true,
                 "region" => %{"x" => 120, "y" => 30, "w" => 560, "h" => 340}
               }
             ]
           }}

        "idle_ms" ->
          {:ok, %{"ok" => true, "idle_ms" => 10_000}}

        _other ->
          {:ok, %{"data" => Base.encode64("png"), "mime" => "image/png"}}
      end
    end

    @impl true
    def stop(_state), do: :ok
  end

  # A driver whose screenshots report a FIXED cursor position, so a click's own check
  # can be made to disagree with where the click aimed — the live non-delivery
  # signature (compux's mouse-button events derive their destination from a live
  # cursor read, so an unapplied pointer move sends the click to the previous point).
  defmodule CursorDriver do
    @behaviour Compux.Driver

    @impl true
    def start(opts), do: {:ok, %{cursor: Keyword.fetch!(opts, :cursor)}}

    @impl true
    def execute(%{cursor: cursor}, %{"action" => "screenshot"}) do
      base = %{"data" => Base.encode64("png"), "mime" => "image/png"}
      {:ok, if(cursor, do: Map.put(base, "cursor", cursor), else: base)}
    end

    def execute(_state, _request), do: {:ok, %{"ok" => true}}

    @impl true
    def stop(_state), do: :ok
  end

  defmodule EmptyWindowsDriver do
    @behaviour Compux.Driver

    @impl true
    def start(opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}

    @impl true
    def execute(_state, _request), do: {:ok, %{"windows" => []}}

    @impl true
    def stop(_state), do: :ok
  end

  # Screenshots succeed a bounded number of times, then fail — how the crop
  # check's own capture failure is exercised. Backed by an Agent so the budget
  # survives the driver's stateless execute/2.
  defmodule FailingCheckDriver do
    @behaviour Compux.Driver

    @impl true
    def start(opts) do
      {:ok, %{shots: Keyword.fetch!(opts, :shots)}}
    end

    @impl true
    def execute(%{shots: shots}, %{"action" => "screenshot"}) do
      if Agent.get_and_update(shots, &{&1, &1 - 1}) > 0,
        do: {:ok, %{"data" => Base.encode64("png"), "mime" => "image/png"}},
        else: {:error, :capture_failed}
    end

    def execute(_state, _request), do: {:ok, %{"ok" => true}}

    @impl true
    def stop(_state), do: :ok
  end

  defp start_session do
    start_supervised!(
      {Session,
       [
         config: Config.normalize(enabled: true),
         driver: {ImageDriver, [test_pid: self()]},
         origin: :interactive,
         session_id: "cua_view_region",
         agent: "main"
       ]}
    )
  end

  defp screenshot(session, params) do
    {:ok, :auto, request} = Session.classify(session, params)
    Session.execute(session, request)
  end

  @region %{"x" => 0, "y" => 0, "w" => 600, "h" => 380}

  test "a bare click after a full screenshot is allowed" do
    session = start_session()
    {:ok, _} = screenshot(session, %{"action" => "screenshot"})

    assert {:ok, :auto, _request} =
             Session.classify(session, %{"action" => "left_click", "x" => 180, "y" => 150})
  end

  test "a bare click after a MAGNIFIED crop is refused, naming the region to resend" do
    session = start_session()
    {:ok, _} = screenshot(session, %{"action" => "screenshot", "region" => @region})

    assert {:error, {:region_mismatch, @region}} =
             Session.classify(session, %{"action" => "left_click", "x" => 180, "y" => 150})
  end

  test "the same click WITH the region is allowed" do
    session = start_session()
    {:ok, _} = screenshot(session, %{"action" => "screenshot", "region" => @region})

    assert {:ok, :auto, request} =
             Session.classify(session, %{
               "action" => "left_click",
               "x" => 180,
               "y" => 150,
               "region" => @region
             })

    assert request["region"] == @region
  end

  test "a fresh full screenshot clears the crop and restores full-screen clicking" do
    session = start_session()
    {:ok, _} = screenshot(session, %{"action" => "screenshot", "region" => @region})
    {:ok, _} = screenshot(session, %{"action" => "screenshot"})

    assert {:ok, :auto, _request} =
             Session.classify(session, %{"action" => "left_click", "x" => 180, "y" => 150})
  end

  test "every pointer action is guarded, not just left_click" do
    session = start_session()
    {:ok, _} = screenshot(session, %{"action" => "screenshot", "region" => @region})

    for action <- ~w(left_click right_click double_click mouse_move) do
      assert {:error, {:region_mismatch, @region}} =
               Session.classify(session, %{"action" => action, "x" => 10, "y" => 10}),
             "#{action} must be guarded"
    end

    assert {:error, {:region_mismatch, @region}} =
             Session.classify(session, %{
               "action" => "left_click_drag",
               "from" => %{"x" => 10, "y" => 10},
               "to" => %{"x" => 20, "y" => 20}
             })
  end

  test "keyboard actions are never guarded — they carry no coordinates" do
    session = start_session()
    {:ok, _} = screenshot(session, %{"action" => "screenshot", "region" => @region})

    assert {:ok, :auto, _} = Session.classify(session, %{"action" => "type", "text" => "e4"})
    assert {:ok, :auto, _} = Session.classify(session, %{"action" => "key", "chord" => "enter"})
  end

  # `elements` returns no pixels, so it must not clear a crop the model is still
  # reading coordinates from.
  test "a non-image action does not move the view" do
    session = start_session()
    {:ok, _} = screenshot(session, %{"action" => "screenshot", "region" => @region})
    {:ok, _} = screenshot(session, %{"action" => "elements"})

    assert {:error, {:region_mismatch, @region}} =
             Session.classify(session, %{"action" => "left_click", "x" => 180, "y" => 150})
  end

  # A zoomed click is verified in the space it acted in: the session skips
  # compux's full-screen check and takes a SAME-region screenshot as the check,
  # so the model sees the result of its click magnified — no re-zoom round trip.
  test "a zoomed click is checked by a screenshot of the SAME crop" do
    session = start_session()
    {:ok, _} = screenshot(session, %{"action" => "screenshot", "region" => @region})

    {:ok, :auto, click} =
      Session.classify(session, %{
        "action" => "left_click",
        "x" => 180,
        "y" => 150,
        "region" => @region
      })

    {:ok, result} = Session.execute(session, click)

    assert_receive {:driver_execute, %{"action" => "left_click", "screenshot_after" => false}}
    assert_receive {:driver_execute, %{"action" => "screenshot", "region" => @region}}
    assert %{data: "png"} = result.image
    assert result.summary =~ "MAGNIFIED CROP"
    assert result.summary =~ "SAME region"
  end

  test "after a zoomed click the crop is still the view" do
    session = start_session()
    {:ok, _} = screenshot(session, %{"action" => "screenshot", "region" => @region})

    {:ok, :auto, click} =
      Session.classify(session, %{
        "action" => "left_click",
        "x" => 180,
        "y" => 150,
        "region" => @region
      })

    {:ok, _} = Session.execute(session, click)

    assert {:error, {:region_mismatch, @region}} =
             Session.classify(session, %{"action" => "left_click", "x" => 900, "y" => 400})

    assert {:ok, :auto, _} =
             Session.classify(session, %{
               "action" => "left_click",
               "x" => 200,
               "y" => 220,
               "region" => @region
             })
  end

  test "a bare click keeps the full-screen check and needs no crop check" do
    session = start_session()
    {:ok, _} = screenshot(session, %{"action" => "screenshot"})

    {:ok, :auto, click} =
      Session.classify(session, %{"action" => "left_click", "x" => 180, "y" => 150})

    {:ok, result} = Session.execute(session, click)

    assert_receive {:driver_execute, %{"action" => "left_click", "screenshot_after" => true}}
    refute_receive {:driver_execute, %{"action" => "screenshot", "region" => _}}, 50
    refute result.summary =~ "MAGNIFIED CROP"

    assert {:ok, :auto, _} =
             Session.classify(session, %{"action" => "left_click", "x" => 900, "y" => 300})
  end

  # The click DID land; reporting an error would make the model retry it (a
  # double click on the real desktop). Report it done, say the check is missing,
  # and leave the view where it was — the model still looks at its last crop.
  test "a failed check capture reports the click done and unverified, keeping the view" do
    shots = start_supervised!({Agent, fn -> 1 end})

    session =
      start_supervised!(
        {Session,
         [
           config: Config.normalize(enabled: true),
           driver: {FailingCheckDriver, [shots: shots]},
           origin: :interactive,
           session_id: "cua_check_fail",
           agent: "main"
         ]}
      )

    {:ok, _} = screenshot(session, %{"action" => "screenshot", "region" => @region})

    {:ok, :auto, click} =
      Session.classify(session, %{
        "action" => "left_click",
        "x" => 180,
        "y" => 150,
        "region" => @region
      })

    assert {:ok, result} = Session.execute(session, click)
    assert result.image == nil
    assert result.summary =~ "check capture failed"
    assert result.summary =~ "SAME region"

    assert {:error, {:region_mismatch, @region}} =
             Session.classify(session, %{"action" => "left_click", "x" => 900, "y" => 400})
  end

  # A click's check screenshot reports where the pointer ACTUALLY is, and the OS puts
  # the mouse-button events at that same point — so cursor != aimed-at is proof the
  # click was not delivered where asked. Observed live 2026-07-26: 4 of 7 clicks landed
  # at the PREVIOUS click's point and every one of them reported success, which sent
  # the model re-zooming and re-aiming at coordinates that were already correct.
  describe "click delivery" do
    defp click_with_cursor(cursor, click_at) do
      session =
        start_supervised!(
          {Session,
           [
             config: Config.normalize(enabled: true),
             driver: {CursorDriver, [cursor: cursor]},
             origin: :interactive,
             session_id: "cua_delivery_#{System.unique_integer([:positive])}",
             agent: "main"
           ]}
        )

      {:ok, _} = screenshot(session, %{"action" => "screenshot", "region" => @region})

      {:ok, :auto, click} =
        Session.classify(
          session,
          Map.merge(%{"action" => "left_click", "region" => @region}, click_at)
        )

      {:ok, result} = Session.execute(session, click)
      result
    end

    test "a click whose pointer reached the target is reported plainly" do
      result = click_with_cursor(%{"x" => 180, "y" => 150}, %{"x" => 180, "y" => 150})

      refute result.summary =~ "NOT delivered"
      assert result.summary =~ "Cursor at (180,150)"
    end

    test "a click the OS put somewhere else is reported as NOT delivered" do
      result = click_with_cursor(%{"x" => 377, "y" => 472}, %{"x" => 169, "y" => 245})

      assert result.summary =~ "NOT delivered at (169,245)"
      assert result.summary =~ "SAME region"
      # The true pointer position stays visible — it is the evidence.
      assert result.summary =~ "Cursor at (377,472)"
    end

    test "a check that reports no cursor cannot prove delivery, so it says so" do
      result = click_with_cursor(nil, %{"x" => 169, "y" => 245})

      assert result.summary =~ "NOT delivered at (169,245)"
    end
  end

  test "a magnified screenshot tells the model which space it is reading" do
    session = start_session()

    {:ok, result} = screenshot(session, %{"action" => "screenshot", "region" => @region})

    assert result.summary =~ "MAGNIFIED CROP"
    assert result.summary =~ "w:600"
    assert result.summary =~ "SAME region"
  end

  test "a full screenshot carries no magnified notice" do
    session = start_session()

    {:ok, result} = screenshot(session, %{"action" => "screenshot"})

    refute result.summary =~ "MAGNIFIED CROP"
  end

  describe "windows (compux v4)" do
    test "each window comes back with a region the model can copy verbatim" do
      session = start_session()

      {:ok, result} = screenshot(session, %{"action" => "windows"})

      assert result.summary =~ "Google Chrome"
      assert result.summary =~ "[focused]"
      assert result.summary =~ ~s(region {"x": 120, "y": 30, "w": 560, "h": 340})
      # The region is only useful if it rides the click too — say so.
      assert result.summary =~ "SAME region"
      assert result.image == nil, "a window listing carries no pixels"
    end

    # An empty desktop and a missing screen-recording grant look identical from
    # here (macOS withholds window titles from an unpermitted process, and the
    # enumeration drops what it cannot name), so the text must not assert "empty".
    test "an empty listing names the likely cause instead of claiming an empty desktop" do
      session =
        start_supervised!(
          {Session,
           [
             config: Config.normalize(enabled: true),
             driver: {EmptyWindowsDriver, [test_pid: self()]},
             origin: :interactive,
             session_id: "cua_no_windows",
             agent: "main"
           ]}
        )

      {:ok, result} = screenshot(session, %{"action" => "windows"})

      assert result.summary =~ "permission"
    end

    # It returns metadata, not pixels, so it must not become the view a later click
    # is measured against.
    test "listing windows does not move the view" do
      session = start_session()
      {:ok, _} = screenshot(session, %{"action" => "screenshot", "region" => @region})
      {:ok, _} = screenshot(session, %{"action" => "windows"})

      assert {:error, {:region_mismatch, @region}} =
               Session.classify(session, %{"action" => "left_click", "x" => 10, "y" => 10})
    end
  end
end
