defmodule FermixCore.Native.Notifications.ComputersTest do
  @moduledoc """
  Notifications on the owner's computers (M99 §10.1), as an Always On
  server's primary shows them: who is asked, what each computer's answer is
  as the reminder rail reads it, and how the answers combine. The computers
  are the home's list as `Computers.fetch/1` joins it from seams, and each
  call is answered by the test; the real link is in FermixChannels'
  two-engine tests.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias FermixCore.Computers.Capabilities.Notifications, as: Capability
  alias FermixCore.Computers.Origin
  alias FermixCore.Computers.Outcome
  alias FermixCore.Delivery.Error
  alias FermixCore.Native.Notifications
  alias FermixCore.Native.Notifications.Computers

  @notification %{
    title: "Tea",
    body: "Tea, today at 16:05.",
    sound: true,
    reminder_id: "rem_1",
    key: "temporal:rem_1"
  }
  @receipt %{at: ~U[2031-06-08 12:00:00.000Z], target: "reminder rem_1"}
  @turn %{session_id: "main-31", computer_use_origin: :interactive, source_trust: :operator}

  defp row(name, connected?) do
    id = "dev-" <> String.replace(String.downcase(name), " ", "-")

    %{
      device_id: id,
      name: name,
      platform: "macos",
      last_seen: ~U[2031-06-08 11:00:00Z],
      backups: nil,
      connected: connected?,
      since: if(connected?, do: ~U[2031-06-08 11:00:00Z])
    }
  end

  # The home's computers, joined by `Computers.fetch/1` from these rows.
  defp home(rows) do
    live =
      for %{connected: true} = row <- rows,
          into: %{},
          do:
            {row.device_id,
             %{offers: [%{id: "files", state: :on}], path: :direct, standing: :current}}

    [role: :primary, rows: fn -> {:ok, rows} end, live: live, records: %{}, version: "0.18.0"]
  end

  # Each computer answers as `answers` says, by its name; the test hears every
  # call it was made.
  defp calls(answers) do
    test = self()

    fn computer, module, op, args, context, opts ->
      send(test, {:called, computer.name, module, op, args, context, opts})

      case Map.fetch!(answers, computer.name) do
        fun when is_function(fun, 0) -> fun.()
        answer -> answer
      end
    end
  end

  defp opts(rows, answers),
    do: [computers: home(rows), call: calls(answers), call_opts: [epoch: 3]]

  defp shown(word \\ "now"), do: {:ok, %Outcome{status: :ok, result: %{"shown" => word}}}

  defp failed(reason, words),
    do:
      {:error,
       %Outcome{status: :failed, message: words, result: %{"reason" => reason}, receipt: @receipt}}

  defp refused(refusal, words, receipt \\ @receipt),
    do: {:error, %{Outcome.refused(refusal, words) | receipt: receipt}}

  defp post(rows, answers), do: Computers.post(@notification, opts(rows, answers))

  describe "post/2: who is asked" do
    test "every connected computer, each once, with the reminder's key and its own request" do
      rows = [row("studio Mac", true), row("loft Linux", true), row("attic Mac", false)]

      assert {:ok, "temporal:rem_1"} =
               post(rows, %{"studio Mac" => shown(), "loft Linux" => shown("before")})

      assert_received {:called, "loft Linux", Capability, "post", args, context, opts}
      assert_received {:called, "studio Mac", Capability, "post", ^args, ^context, ^opts}
      refute_received {:called, "attic Mac", _module, _op, _args, _context, _opts}

      assert args == %{
               "key" => "temporal:rem_1",
               "title" => "Tea",
               "body" => "Tea, today at 16:05.",
               "sound" => true,
               "reminder_id" => "rem_1"
             }

      # A reminder's request, no turn's: background, its turn named for it.
      assert context == %{session_id: "reminder-rem_1"}
      assert Origin.of(context) == :background
      assert opts[:deadline_ms] == 15_000
      assert opts[:epoch] == 3
    end

    test "at most sixteen, in the order of their names" do
      rows = for n <- 30..1//-1, do: row("computer #{String.pad_leading("#{n}", 2, "0")}", true)
      answers = Map.new(rows, &{&1.name, shown()})

      assert {:ok, _key} = post(rows, answers)

      asked =
        for _n <- 1..16 do
          assert_received {:called, name, _module, "post", _args, _context, _opts}
          name
        end

      refute_received {:called, _name, _module, _op, _args, _context, _opts}

      assert Enum.sort(asked) ==
               for(n <- 1..16, do: "computer #{String.pad_leading("#{n}", 2, "0")}")
    end

    test "a notification for no reminder names none, and its turn by its key" do
      notification = Map.delete(@notification, :reminder_id)

      assert {:ok, _key} =
               Computers.post(
                 notification,
                 opts([row("studio Mac", true)], %{"studio Mac" => shown()})
               )

      assert_received {:called, "studio Mac", _module, "post", args, context, _opts}
      refute Map.has_key?(args, "reminder_id")
      assert context == %{session_id: "notification-temporal:rem_1"}
    end

    test "with no computer linked it is not offered; with none connected none is reached" do
      assert post([], %{}) == {:error, :not_offered}
      assert post([row("studio Mac", false)], %{}) == {:error, :no_computer}
      refute_received {:called, _name, _module, _op, _args, _context, _opts}
    end

    test "a home whose computers cannot be listed reaches none, and the rail retries" do
      opts = [
        computers: [role: :primary, rows: fn -> {:error, :not_running} end],
        call: calls(%{})
      ]

      assert Computers.post(@notification, opts) == {:error, :no_computer}
      assert Error.retryable?(Notifications.delivery_error(:no_computer))
    end

    test "a notification with no key is refused before any computer is asked" do
      assert {:error, {:failed, _words}} =
               Computers.post(
                 Map.delete(@notification, :key),
                 opts([row("studio Mac", true)], %{})
               )

      refute_received {:called, _name, _module, _op, _args, _context, _opts}
    end
  end

  describe "post/2: one computer's answer, as the rail reads it" do
    # A row per answer: what it is, and whether the rail retries it.
    test "each answer maps to a reason of the closed set" do
      unknown_op = "Fermix on this computer does not know how to do that."

      rows = [
        {failed("no_server", "No desktop notification server is running on this computer."),
         :no_server},
        {failed("not_authorized", "Fermix is not allowed to show notifications."),
         :not_authorized},
        {failed("host_unavailable", "The app could not be reached."), :host_unavailable},
        {failed("failed", "Notify: exit 1"), {:failed, "studio Mac: Notify: exit 1"}},
        {{:error, %Outcome{status: :failed, message: "It stopped before it finished."}},
         {:failed, "studio Mac: It stopped before it finished."}},
        {refused(:off, "Everything Fermix on your server may use is switched off on this Mac."),
         :not_authorized},
        {refused(:stopped_here, "The person at this computer stopped it."), :not_authorized},
        {refused(:unavailable, unknown_op), {:failed, "studio Mac: " <> unknown_op}},
        {refused(:stale_epoch, "This computer has seen a newer copy of its home."),
         {:failed, "studio Mac: This computer has seen a newer copy of its home."}},
        {refused(:busy, "This computer is running as much as it allows right now."), :timeout},
        {refused(:unavailable, "studio Mac is asleep or offline.", nil), :timeout},
        {{:error, %Outcome{status: :timed_out}}, :timeout},
        {{:error, %Outcome{status: :unknown}}, :timeout},
        {{:error, %Outcome{status: :cancelled}}, :timeout},
        {{:error, %Outcome{status: :failed, message: "It failed.", receipt_only: true}},
         :timeout},
        {fn -> raise "the call broke" end, :timeout}
      ]

      for {answer, reason} <- rows do
        assert post([row("studio Mac", true)], %{"studio Mac" => answer}) == {:error, reason},
               inspect(answer)
      end

      assert post([row("studio Mac", true)], %{
               "studio Mac" => {:ok, %Outcome{status: :ok, receipt_only: true}}
             }) ==
               {:ok, "temporal:rem_1"}
    end

    test "the busy, the away and the lost are retried; a computer that said no is not" do
      for reason <- [:timeout, :no_server, :host_unavailable, :no_computer],
          do: assert(Error.retryable?(Notifications.delivery_error(reason)), inspect(reason))

      for reason <- [:not_authorized, :not_offered, {:failed, "studio Mac: no"}],
          do: refute(Error.retryable?(Notifications.delivery_error(reason)), inspect(reason))
    end
  end

  defp off,
    do: refused(:off, "Everything Fermix on your server may use is switched off on this Mac.")

  defp unknown_op,
    do: refused(:unavailable, "Fermix on this computer does not know how to do that.")

  describe "post/2: the answers together" do
    test "shown on one computer is delivered, whatever the others said" do
      rows = [row("attic Mac", true), row("loft Linux", true), row("studio Mac", true)]

      assert post(rows, %{
               "attic Mac" => off(),
               "loft Linux" => shown(),
               "studio Mac" => unknown_op()
             }) ==
               {:ok, "temporal:rem_1"}
    end

    test "otherwise one that could not be reached has the rail try again" do
      rows = [row("attic Mac", true), row("loft Linux", true)]
      busy = refused(:busy, "This computer is running as much as it allows right now.")

      assert post(rows, %{"attic Mac" => off(), "loft Linux" => busy}) == {:error, :timeout}
    end

    test "otherwise the first computer's reason, in name order" do
      rows = [row("loft Linux", true), row("attic Mac", true)]

      assert post(rows, %{"attic Mac" => off(), "loft Linux" => unknown_op()}) ==
               {:error, :not_authorized}
    end
  end

  describe "ready/2" do
    @ready {:ok, %Outcome{status: :ok, result: %{"ready" => true}}}
    @not_ready {:ok,
                %Outcome{
                  status: :ok,
                  result: %{
                    "ready" => false,
                    "sentence" =>
                      "Fermix is not allowed to show notifications on your Mac; next time you " <>
                        "are at it, open System Settings > Notifications > Fermix"
                  }
                }}

    defp ready(rows, answers), do: Computers.ready(@turn, opts(rows, answers))

    test "refused with no computer linked, or when the computers cannot be listed" do
      assert ready([], %{}) == {:error, "no computer is linked to your server"}

      opts = [
        computers: [role: :primary, rows: fn -> {:error, :not_running} end],
        call: calls(%{})
      ]

      assert Computers.ready(@turn, opts) == {:error, "your computers could not be listed now"}
    end

    test "accepted when none is connected, asking nothing: one may be awake when it is due" do
      assert ready([row("studio Mac", false)], %{}) == :ok
      refute_received {:called, _name, _module, _op, _args, _context, _opts}
    end

    test "each connected computer is asked ready, with the turn that stores the reminder" do
      rows = [row("studio Mac", true), row("loft Linux", true)]
      assert ready(rows, %{"studio Mac" => @not_ready, "loft Linux" => @ready}) == :ok

      assert_received {:called, "loft Linux", Capability, "ready", %{}, @turn, opts}
      assert opts[:deadline_ms] == 10_000
      assert_received {:called, "studio Mac", Capability, "ready", %{}, @turn, _opts}
    end

    test "refused only when every one says it cannot, in the first one's clause" do
      rows = [row("studio Mac", true), row("loft Linux", true)]

      assert {:error, clause} = ready(rows, %{"studio Mac" => @not_ready, "loft Linux" => off()})

      assert clause ==
               "loft Linux answers that everything Fermix on your server may use is switched " <>
                 "off on this Mac"

      assert {:error, "studio Mac answers that Fermix is not allowed" <> _rest} =
               ready([row("studio Mac", true)], %{"studio Mac" => @not_ready})

      assert {:error,
              "studio Mac answers that Fermix on this computer does not know how to do that"} =
               ready([row("studio Mac", true)], %{"studio Mac" => unknown_op()})
    end

    test "one that could not be asked has not said it cannot" do
      rows = [row("studio Mac", true), row("loft Linux", true)]
      timed_out = {:error, %Outcome{status: :timed_out}}

      assert ready(rows, %{"studio Mac" => @not_ready, "loft Linux" => timed_out}) == :ok
    end

    test "each refusal is a clause the registry embeds" do
      clauses = [
        elem(ready([], %{}), 1),
        elem(ready([row("studio Mac", true)], %{"studio Mac" => off()}), 1)
      ]

      for clause <- clauses do
        refute String.ends_with?(clause, ".")
        first = String.first(clause)
        assert first == String.downcase(first) or String.starts_with?(clause, "Fermix")
      end
    end
  end
end
