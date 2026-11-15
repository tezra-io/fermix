defmodule FermixChannels.Desktop.InvokeCopyTest do
  # M97 §6.1, §6.2: what the server's model reads of an invocation. The
  # sentences the server's `Invocation` and the computer's `Admission` put in
  # an outcome's message are each module's own, behind one function
  # (`sentences/0`), and are held to the copy rules `Management.CopyTest`
  # holds a management sentence to. A sweep of each module's source finds
  # any sentence written outside that function.
  use ExUnit.Case, async: true

  alias FermixChannels.Desktop.Invoke.Admission
  alias FermixCore.Computers.Invocation
  alias FermixCore.Management.Copy

  @sources %{
    Invocation =>
      Path.expand("../../../../fermix_core/lib/fermix_core/computers/invocation.ex", __DIR__),
    Admission => Path.expand("../../../lib/fermix_channels/desktop/invoke/admission.ex", __DIR__)
  }
  # The bound the wire puts on an answer's message (`Mobile.PeerEvents`).
  @max_message_bytes 512

  for {module, _source} <- @sources do
    test "every sentence #{inspect(module)} says obeys the copy rules" do
      sentences = unquote(module).sentences()

      assert length(sentences) > 5
      assert Enum.uniq(sentences) == sentences

      for text <- sentences do
        assert Copy.violations(text, :prose, ["studio Mac"]) == [], text
        assert Copy.summary_violations(text) == [], text
        assert String.ends_with?(text, "."), text
        assert byte_size(text) <= @max_message_bytes, text
      end
    end
  end

  test "no sentence is written outside each module's one function" do
    for {module, source} <- @sources do
      loose = source |> File.read!() |> loose_sentences()
      assert loose == [], "#{inspect(module)} writes #{inspect(loose)} outside sentence/1"
    end
  end

  # The sweep itself: a sentence written in place is found.
  test "the sweep finds a sentence written in place" do
    source = """
    defmodule Sample do
      @moduledoc "A module that says things."
      def said, do: {:failed, "It did not go."}
      def named(name), do: "\#{name} is away."
      defp sentence(:kept), do: "This one is kept."
      def logged, do: Logger.warning("this is logged.")
    end
    """

    assert Enum.sort(loose_sentences(source)) == ["It did not go.", "x is away."]
  end

  # Every literal, its interpolations rendered `x`, that reads as a
  # sentence (a space, and a full stop at its end), outside the docs, the
  # logs, a raise and the `sentence/1` clauses.
  defp loose_sentences(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    {_ast, found} = Macro.prewalk(ast, [], &loose/2)
    Enum.reverse(found)
  end

  defp loose({:@, _meta, [{doc, _doc_meta, _args}]}, acc)
       when doc in [:moduledoc, :doc, :typedoc],
       do: {nil, acc}

  defp loose({:defp, _meta, [{:sentence, _call_meta, _args} | _body]}, acc), do: {nil, acc}

  defp loose({{:., _meta, [{:__aliases__, _alias_meta, [:Logger]}, _fun]}, _m, _a}, acc),
    do: {nil, acc}

  defp loose({:raise, _meta, _args}, acc), do: {nil, acc}

  defp loose({:<<>>, _meta, parts}, acc) do
    text = Enum.map_join(parts, &rendered/1)
    {nil, keep(text, acc)}
  end

  defp loose(text, acc) when is_binary(text), do: {text, keep(text, acc)}
  defp loose(node, acc), do: {node, acc}

  defp rendered(part) when is_binary(part), do: part
  defp rendered(_interpolation), do: "x"

  defp keep(text, acc) do
    if String.contains?(text, " ") and String.ends_with?(text, "."), do: [text | acc], else: acc
  end
end
