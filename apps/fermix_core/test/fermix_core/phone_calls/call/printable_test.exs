defmodule FermixCore.PhoneCalls.Call.PrintableTest do
  # `Printable.reason/1` is the one rule for printing a phone-call process's
  # reason anywhere it outlives the process (a log line, a crash report, a
  # row's failure words): its codes, never a call's words. Every number, name
  # and word here is invented.
  use ExUnit.Case, async: true

  alias FermixCore.PhoneCalls.Call.Printable

  @number "+12125550101"
  @frame {FermixCore.PhoneCalls.Manager, :admit, [%{destination: @number}, %{}],
          [file: ~c"lib/manager.ex", line: 7, error_info: %{cause: @number}]}

  defp refute_words(printed) do
    bytes = :erlang.term_to_binary(printed)
    assert :binary.match(bytes, "5550101") == :nomatch, inspect(printed)
    assert :binary.match(bytes, "Calloway") == :nomatch, inspect(printed)
  end

  describe "reason/1" do
    test "a crash keeps its kind and every frame by arity and place, never its arguments" do
      printed = Printable.reason({:function_clause, [@frame]})

      assert printed ==
               {:function_clause,
                [{FermixCore.PhoneCalls.Manager, :admit, 2, [file: ~c"lib/manager.ex", line: 7]}]}

      refute_words(printed)
    end

    test "an exception is its module" do
      error = %KeyError{key: :goal, term: %{goal: "Book Calloway at " <> @number}}
      assert Printable.reason({error, [@frame]}) |> elem(0) == KeyError
      assert Printable.reason(error) == KeyError
    end

    test "codes survive at every level: atoms and integers, an HTTP status among them" do
      vendor = %{message: "Number " <> @number <> " is not on this call"}

      assert Printable.reason({:rejected, 422, vendor}) == {:rejected, 422, :redacted}

      assert Printable.reason({:unknown, {:http_status, 504, vendor}}) ==
               {:unknown, {:http_status, 504, :redacted}}

      assert Printable.reason({:invalid, :outcome_facts, "agreed with Calloway"}) ==
               {:invalid, :outcome_facts, :redacted}
    end

    test "text, maps and a list that is no stack are words, never printed" do
      for words <- [
            "Calloway " <> @number,
            %{destination: @number},
            [{"Calloway", @number}],
            ~c"+12125550101"
          ] do
        printed = Printable.reason({:refused, words})
        assert printed == {:refused, :redacted}
        refute_words(printed)
      end
    end

    test "an exit from a call keeps its own reason, and the call it was asked is redacted" do
      exit =
        {{:function_clause, [@frame]}, {GenServer, :call, [self(), {:start_call, @number}, 1]}}

      printed = Printable.reason(exit)

      assert {{:function_clause, [{_module, :admit, 2, _place}]}, {GenServer, :call, :redacted}} =
               printed

      refute_words(printed)
    end

    test "nesting is bounded: past the cap a value is redacted, whatever it is" do
      deep = Enum.reduce(1..20, :bottom, fn _level, inner -> {:wrap, inner} end)
      printed = Printable.reason(deep)
      refute printed |> inspect() |> String.contains?(":bottom")
    end
  end

  describe "message/1" do
    test "a process's exit or a task's end the worker handles prints its reason by its codes" do
      reason = {:function_clause, [@frame]}
      ref = make_ref()

      for message <- [{:DOWN, ref, :process, self(), reason}, {:EXIT, self(), reason}] do
        printed = Printable.message(message)
        assert elem(printed, tuple_size(printed) - 1) == Printable.reason(reason)
        refute_words(printed)
      end
    end
  end
end
