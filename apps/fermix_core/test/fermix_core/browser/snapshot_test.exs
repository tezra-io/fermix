defmodule FermixCore.Browser.SnapshotTest do
  use ExUnit.Case, async: true

  alias FermixCore.Browser.Config
  alias FermixCore.Browser.Snapshot

  defp opts(overrides \\ %{}) do
    {:ok, base} = Config.snapshot_options(%{})
    Map.merge(base, overrides)
  end

  test "renders bounded accessibility snapshot with boundary markers and refs" do
    nodes = [
      %{
        "nodeId" => "1",
        "role" => %{"value" => "RootWebArea"},
        "name" => %{"value" => "Home"},
        "childIds" => ["2", "3"]
      },
      %{"nodeId" => "2", "role" => %{"value" => "heading"}, "name" => %{"value" => "Dashboard"}},
      %{
        "nodeId" => "3",
        "backendDOMNodeId" => 42,
        "role" => %{"value" => "button"},
        "name" => %{"value" => "Launch"},
        "properties" => [%{"name" => "disabled", "value" => %{"value" => false}}]
      }
    ]

    assert {:ok, result} = Snapshot.render(nodes, opts())
    assert result.text =~ "<browser_page_content>"
    assert result.text =~ "@button_1 [button] \"Launch\""
    assert result.truncated == false
    assert [%{ref: "button_1", backend_node_id: 42}] = result.refs
  end

  test "truncates on character boundaries and keeps the closing marker (valid UTF-8)" do
    # A multibyte name longer than the cap forces truncation mid-content.
    long_name = String.duplicate("é", 50)

    nodes = [
      %{
        "nodeId" => "1",
        "role" => %{"value" => "RootWebArea"},
        "name" => %{"value" => long_name},
        "childIds" => []
      }
    ]

    assert {:ok, result} = Snapshot.render(nodes, opts(%{max_chars: 20, interactive: false}))
    assert result.truncated == true
    # Must not split a codepoint — Jason.encode! raises on invalid UTF-8.
    assert is_binary(Jason.encode!(result.text))
    assert String.valid?(result.text)
    # Boundary wrapper is applied after truncation, so the closing tag survives.
    assert result.text =~ "</browser_page_content>"
  end

  test "reaches a form field nested under wrapper divs past the raw depth cap" do
    # Root > 6 generic wrappers > textbox. With raw-depth counting and the
    # default cap of 5 the textbox is pruned; with emitted-depth counting the
    # transparent wrappers don't consume the budget, so it still gets a ref.
    wrappers =
      Enum.map(1..6, fn n ->
        %{"nodeId" => "g#{n}", "role" => %{"value" => "generic"}, "childIds" => ["g#{n + 1}"]}
      end)

    # last wrapper points at the input
    wrappers =
      List.replace_at(wrappers, 5, %{
        "nodeId" => "g6",
        "role" => %{"value" => "generic"},
        "childIds" => ["input"]
      })

    nodes =
      [
        %{
          "nodeId" => "root",
          "role" => %{"value" => "RootWebArea"},
          "name" => %{"value" => "Login"},
          "childIds" => ["g1"]
        }
      ] ++
        wrappers ++
        [
          %{
            "nodeId" => "input",
            "backendDOMNodeId" => 7,
            "role" => %{"value" => "textbox"},
            "name" => %{"value" => "Username"}
          }
        ]

    assert {:ok, result} = Snapshot.render(nodes, opts())
    assert [%{ref: "textbox_1", role: "textbox", backend_node_id: 7}] = result.refs
    assert result.text =~ "@textbox_1 [textbox] \"Username\""
  end

  test "mints a ref for an editable node whose role is not a known interactive role" do
    nodes = [
      %{"nodeId" => "root", "role" => %{"value" => "RootWebArea"}, "childIds" => ["e"]},
      %{
        "nodeId" => "e",
        "backendDOMNodeId" => 11,
        "role" => %{"value" => "generic"},
        "name" => %{"value" => "Body"},
        "properties" => [%{"name" => "editable", "value" => %{"value" => "plaintext"}}]
      }
    ]

    assert {:ok, result} = Snapshot.render(nodes, opts())
    assert [%{ref: "generic_1", backend_node_id: 11}] = result.refs
  end

  test "depth and max_children bound the walk" do
    nodes =
      [%{"nodeId" => "0", "role" => %{"value" => "RootWebArea"}, "childIds" => ["1", "2", "3"]}] ++
        Enum.map(1..3, fn id ->
          %{
            "nodeId" => "#{id}",
            "role" => %{"value" => "heading"},
            "name" => %{"value" => "H#{id}"}
          }
        end)

    assert {:ok, result} = Snapshot.render(nodes, opts(%{max_children: 1, interactive: false}))
    # Only the first child is walked.
    assert result.text =~ "H1"
    refute result.text =~ "H2"
  end
end
