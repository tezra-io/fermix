defmodule FermixCore.Capabilities.MCP.AnubisStarterTest do
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.MCP.AnubisStarter

  # Anubis keys its per-client ETS cache (`Anubis.Client.Cache`, the tool
  # validator table) by `client_info["name"]` and creates that table protected,
  # owned by whichever client process touches it first. A second stdio client
  # advertising the same name then crashes on the first `tools/list` reply
  # (`:ets.delete_all_objects/1` with insufficient access rights), which is how
  # the tesla helper failed discovery every 31 s beside the obsidian child.
  # The identity Fermix advertises must therefore be unique per server.
  describe "child_specs_for/2 stdio" do
    test "every server gets its own client identity, derived from the server name" do
      tesla = client_info_for("tesla")
      obsidian = client_info_for("obsidian")

      assert tesla["name"] == "fermix-tesla"
      assert obsidian["name"] == "fermix-obsidian"
      refute tesla["name"] == obsidian["name"]
      assert is_binary(tesla["version"]) and tesla["version"] != ""
    end
  end

  defp client_info_for(server_name) do
    %{children: [spec]} =
      AnubisStarter.Default.child_specs_for(
        %{name: server_name, command: "/bin/true", args: [], env: %{}, cwd: "/"},
        %{}
      )

    %{start: {_client_module, :start_link, [opts]}} = spec
    Keyword.fetch!(opts, :client_info)
  end
end
