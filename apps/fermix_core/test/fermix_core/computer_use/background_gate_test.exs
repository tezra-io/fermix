defmodule FermixCore.ComputerUse.BackgroundGateTest do
  @moduledoc """
  The whole-surface invariant for the experimental bound-window flag (M42 slice 5
  §4).

  A flag that gates four things is gated four times, and the fourth is the one
  somebody forgets: the action enum, the parameter beside it, the tool's own
  words and the runtime steering. So this file does not name them one by one. It
  loops over `ComputerUse.Background`'s lists — the SAME lists every consumer
  reads — across every surface the model or the operator can see, and asserts
  that with the flag off none of them is anywhere. A token or a sentence added to
  that module later joins this invariant by construction; one added anywhere else
  fails it, because the consumer that reveals it reads from there too.

  It also pins the second gate. The flag is the operator's answer; whether the
  installed helper can carry a bound window is the helper's, and a helper that
  cannot is never degraded into display-level work behind the model's back.
  """

  use ExUnit.Case, async: false

  alias Compux.Protocol
  alias Fermix.CLI.Doctor.Checks
  alias FermixCore.ComputerUse.Background
  alias FermixCore.ComputerUse.Capabilities
  alias FermixCore.ComputerUse.Config
  alias FermixCore.ComputerUse.Session
  alias FermixCore.Management.Settings
  alias FermixCore.Prompt.RuntimeSections
  alias FermixCore.Tools.ComputerUse
  alias FermixTestSupport.ComputerUseObservations
  alias FermixTestSupport.ComputerUseReceipts

  # This file asserts a DEFAULT, so it establishes that default itself rather
  # than inheriting whatever a sibling left behind, and puts back exactly what it
  # found (the umbrella runs every child app in one VM).
  setup do
    previous = Application.get_env(:fermix_core, :computer_use, [])
    on_exit(fn -> Application.put_env(:fermix_core, :computer_use, previous) end)
    :ok
  end

  defp put_background(background?) do
    Application.put_env(:fermix_core, :computer_use, enabled: true, background: background?)
  end

  # Every surface a model or an operator reads, as one string each, so the loops
  # below are over the flag's own list and not over a list of places.
  defp model_facing do
    [
      {"the tool description", ComputerUse.description()},
      {"when_to_use", ComputerUse.when_to_use()},
      {"the static schema", Jason.encode!(ComputerUse.parameters())},
      {"the per-turn schema", Jason.encode!(ComputerUse.dynamic_parameters(%{}))},
      {"the failure modes", Jason.encode!(ComputerUse.failure_modes())},
      {"the runtime steering", RuntimeSections.build([])}
    ]
  end

  defp computer_use_rows do
    {:ok, view} = Settings.get("computer_use")
    view["rows"]
  end

  # A driver that answers every action with the helper code the test names, so a
  # refusal SENTENCE can be read off the real path rather than off a private
  # function.
  defmodule RefusingDriver do
    @behaviour Compux.Driver

    @impl true
    def start(opts), do: {:ok, %{code: Keyword.fetch!(opts, :code)}}

    @impl true
    def execute(_state, %{"action" => "probe"}), do: {:ok, %{"input_control" => true}}
    def execute(_state, %{"action" => "hello"}), do: {:ok, %{"capabilities" => %{}}}
    def execute(_state, %{"action" => "idle_ms"}), do: {:ok, %{"ok" => true, "idle_ms" => 10_000}}

    def execute(%{code: code}, _request) do
      {:error,
       {:action_failed,
        %{"error" => code, "detail" => nil, "receipt" => ComputerUseReceipts.receipt(:not_sent)}}}
    end

    @impl true
    def stop(_state), do: :ok
  end

  # A helper that can carry a bound window, and one that cannot, in the two ways
  # it can fail to: no target support at all, and no on-screen indicator.
  defmodule TargetDriver do
    @behaviour Compux.Driver

    @impl true
    def start(opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid), hello: opts[:hello]}}

    @impl true
    def execute(%{hello: hello}, %{"action" => "hello"}), do: {:ok, hello}

    @impl true
    def execute(%{test_pid: pid} = state, request) do
      send(pid, {:driver_execute, request})
      {:ok, response(state, request)}
    end

    @impl true
    def stop(_state), do: :ok

    defp response(_state, %{"action" => "idle_ms"}), do: %{"ok" => true, "idle_ms" => 10_000}

    defp response(_state, request) do
      %{"ok" => true, "data" => Base.encode64("png"), "mime" => "image/png"}
      |> ComputerUseObservations.stamp(request)
      |> ComputerUseReceipts.stamp(request)
    end
  end

  defp hello(capabilities) do
    %{"protocol_version" => Protocol.protocol_version(), "capabilities" => capabilities}
  end

  defp assert_generic(sentence, where) do
    for token <- Background.tokens() do
      refute sentence =~ token, "#{where} carries `#{token}` with the flag off"
    end

    for phrase <- Background.marker_phrases() do
      refute String.downcase(sentence) =~ String.downcase(phrase),
             "#{where} says \"#{phrase}\" with the flag off"
    end
  end

  defp start_refusing_session(code) do
    start_supervised!(
      {Session,
       [
         config: Config.current(),
         driver: {RefusingDriver, [code: code]},
         origin: :interactive,
         session_id: "cua_refuse_#{System.unique_integer([:positive])}"
       ]},
      id: {:refusing_session, System.unique_integer([:positive])}
    )
  end

  defp start_session(hello) do
    start_supervised!(
      {Session,
       [
         config: Config.current(),
         driver: {TargetDriver, [test_pid: self(), hello: hello]},
         origin: :interactive,
         session_id: "cua_gate_#{System.unique_integer([:positive])}"
       ]},
      id: {:gate_session, System.unique_integer([:positive])}
    )
  end

  describe "with the flag off, nothing of this surface exists" do
    setup do
      put_background(false)
      :ok
    end

    test "no token the flag can add appears on any surface the model reads" do
      for {where, text} <- model_facing(), token <- Background.tokens() do
        refute text =~ token,
               "#{where} carries `#{token}`, which only the bound-window flag may reveal"
      end
    end

    test "no phrase this surface is written in appears on any surface the model reads" do
      for {where, text} <- model_facing(), phrase <- Background.marker_phrases() do
        refute String.downcase(text) =~ String.downcase(phrase),
               "#{where} says \"#{phrase}\" while the bound-window flag is off"
      end
    end

    test "the action enum is exactly the library's actions minus the ones the flag adds" do
      offered = ComputerUse.parameters()["properties"]["action"]["enum"]

      assert offered == Enum.reject(Protocol.actions(), &(&1 in Background.actions()))
      assert ComputerUse.dynamic_parameters(%{})["properties"]["action"]["enum"] == offered
    end

    test "the schema offers no property the flag adds" do
      properties = Map.keys(ComputerUse.parameters()["properties"])

      for parameter <- Background.parameters() do
        refute parameter in properties, "the schema offers `#{parameter}` with the flag off"
      end
    end

    test "a session refuses the actions with a sentence, rather than binding anything" do
      session = start_session(hello(%{"targets" => true, "indicator" => "present"}))

      for action <- Background.actions() do
        assert {:error, :background_disabled} =
                 Session.classify(session, %{"action" => action, "window_id" => 1}),
               "#{action} ran while the operator had not switched the surface on"
      end

      # The session's one-time input-control probe is start-up, not an action.
      assert_received {:driver_execute, %{"action" => "probe"}}
      refute_received {:driver_execute, _request}
    end

    test "a mutating action is not refused for want of a window" do
      session = start_session(hello(%{}))

      assert {:ok, :auto, request} =
               Session.classify(session, %{
                 "action" => "left_click",
                 "observation_id" => ComputerUseObservations.id(),
                 "x" => 1,
                 "y" => 2
               })

      refute Map.has_key?(request, "target_id"), "a request carries a target with the flag off"
    end

    # The sentences are the fourth surface, and the one a review found leaking: a
    # model that invented `select_target` was answered by a paragraph explaining
    # window binding. Read off the REAL path — the tool's own result — so a
    # sentence added later to either refusal route joins this invariant.
    test "no refusal sentence for an action the flag adds teaches what it would have done" do
      session = start_session(hello(%{}))
      context = %{computer_use_session: session, computer_use_config: Config.current()}

      for action <- Background.actions() do
        assert {:ok, %{success: false, error: sentence}} =
                 ComputerUse.execute(%{"action" => action, "window_id" => 1}, context)

        assert_generic(sentence, "the refusal for #{action}")
      end
    end

    test "no sentence for a bound-window helper code teaches what it would have done" do
      for code <- Background.codes() do
        session = start_refusing_session(code)
        context = %{computer_use_session: session, computer_use_config: Config.current()}

        assert {:ok, %{success: false, error: sentence}} =
                 ComputerUse.execute(
                   %{
                     "action" => "left_click",
                     "observation_id" => ComputerUseObservations.id(),
                     "x" => 1,
                     "y" => 2
                   },
                   context
                 )

        assert_generic(sentence, "the sentence for #{code}")
      end
    end

    test "the settings row publishes the flag as off, and doctor claims nothing is active" do
      assert %{"key" => "computer_use_background", "value" => false} =
               Enum.find(computer_use_rows(), &(&1["key"] == "computer_use_background"))

      assert %{status: :ok, detail: detail} =
               Checks.computer_use_background({:ok, %{state: :off}})

      assert detail =~ "off"
      refute detail =~ "on;"
    end
  end

  describe "with the flag on and a helper that cannot carry it" do
    setup do
      put_background(true)
      :ok
    end

    test "a helper with no target support refuses the surface and names why" do
      session = start_session(hello(%{"indicator" => "present"}))

      assert {:error, {:background_unavailable, :no_targets}} =
               Session.classify(session, %{"action" => "select_target", "window_id" => 1})

      assert %{status: :warn, detail: detail} =
               Checks.computer_use_background(
                 {:ok, %{state: :read, capabilities: Capabilities.from_identity(hello(%{}))}}
               )

      assert detail =~ "cannot bind a window"
    end

    test "a helper whose indicator is missing refuses the surface and names why" do
      session = start_session(hello(%{"targets" => true, "indicator" => "missing"}))

      assert {:error, {:background_unavailable, :indicator_missing}} =
               Session.classify(session, %{"action" => "select_target", "window_id" => 1})

      capabilities =
        Capabilities.from_identity(hello(%{"targets" => true, "indicator" => "missing"}))

      assert %{status: :warn, detail: detail} =
               Checks.computer_use_background({:ok, %{state: :read, capabilities: capabilities}})

      assert detail =~ "no on-screen indicator"
    end

    test "an incapable helper does not start requiring a window either" do
      session = start_session(hello(%{}))

      assert {:ok, :auto, request} =
               Session.classify(session, %{
                 "action" => "left_click",
                 "observation_id" => ComputerUseObservations.id(),
                 "x" => 1,
                 "y" => 2
               })

      refute Map.has_key?(request, "target_id")
    end
  end
end
