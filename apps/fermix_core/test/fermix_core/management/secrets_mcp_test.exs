defmodule FermixCore.Management.SecretsMcpTest do
  @moduledoc """
  `secret.set` and `secret.clear` for the `mcp:` family (M74 E6).

  The family is open like `env:`: an id means something only for a server
  that exists and declares that name. A value is not in the server's spec, so
  the properties worth proving are the ones a reload cannot provide: the last
  missing value of an enabled server starts it, and nothing else does.

  Every store here is the stub, every case runs against its own home, and the
  MCP supervisor is a recorder: no case starts a server.
  """

  use ExUnit.Case, async: false

  alias FermixCore.Capabilities.MCP.Secrets, as: McpSecrets
  alias FermixCore.Management.Secrets
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.RestartState
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.SecretWriterStub

  # Stands in for `McpSupervisor`: reports each start and stop to the calling
  # process, which is the test's, because `secret.set` and `secret.clear` run
  # in it.
  defmodule RecordingSupervisor do
    @moduledoc false

    def restart_server(source_id, spec) do
      send(self(), {:restart_server, source_id, spec.name})
      {:ok, self()}
    end

    def stop_server(source_id) do
      send(self(), {:stop_server, source_id})
      :ok
    end
  end

  @config """
  [mcp.servers.files]
  command = "npx"
  env_secrets = ["GITHUB_TOKEN", "API_KEY"]

  [mcp.servers.notes]
  command = "node"
  enabled = false
  env_secrets = ["NOTES_KEY"]

  [mcp.servers.linear]
  transport = "http"
  url = "https://mcp.linear.app/mcp"
  auth = "header"
  header_secrets = ["Authorization"]
  key_header = "Authorization"
  oauth_client_id = "fermix-client"
  """

  @opts [mcp_supervisor: RecordingSupervisor]

  setup do
    home = System.get_env("FERMIX_HOME")

    core =
      Map.new(
        [:secret_writer, :profile, :mcp_servers],
        &{&1, Application.get_env(:fermix_core, &1)}
      )

    Application.put_env(:fermix_core, :secret_writer, SecretWriterStub)
    Application.delete_env(:fermix_core, :profile)
    SecretWriterStub.reset()

    tmp = SafeRm.make_tmp_dir!("management_secrets_mcp_home")
    System.put_env("FERMIX_HOME", tmp)
    File.write!(Path.join(tmp, "config.toml"), @config)
    :ok = ConfigStore.apply_mcp_config()
    :ok = RestartState.record_persisted_baseline()

    on_exit(fn ->
      Enum.each(core, fn {key, value} -> restore(key, value) end)
      SecretWriterStub.reset()

      case home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      SafeRm.rm_rf!(tmp)
      :ok = RestartState.record_persisted_baseline()
    end)

    %{home: tmp}
  end

  describe "storing a value" do
    test "the value reaches the store under its id, and the answer is env:'s shape", %{home: home} do
      assert {:ok, view} = Secrets.set("mcp:files/env/GITHUB_TOKEN", "ghp_live", @opts)

      assert view["id"] == "mcp:files/env/GITHUB_TOKEN"
      assert view["present"] == true
      assert view["environment_override"] == nil
      assert answer_shape(view) == answer_shape(fixture_result("secret_set_external_env"))

      assert McpSecrets.fetch("files", {:env, "GITHUB_TOKEN"}) == {:ok, "ghp_live"}
      refute File.read!(Path.join(home, "config.toml")) =~ "ghp_live"
    end

    test "the last missing value of an enabled server starts it, and not before" do
      assert {:ok, _view} = Secrets.set("mcp:files/env/GITHUB_TOKEN", "t", @opts)
      refute_received {:restart_server, _source_id, _name}

      assert {:ok, _view} = Secrets.set("mcp:files/env/API_KEY", "k", @opts)
      assert_received {:restart_server, {:operator, "files"}, "files"}
    end

    # A running server holds the value it started with, so a new one restarts it.
    test "a new value for a server that has them all restarts it" do
      assert {:ok, _view} = Secrets.set("mcp:files/env/GITHUB_TOKEN", "t", @opts)
      assert {:ok, _view} = Secrets.set("mcp:files/env/API_KEY", "k", @opts)
      assert_received {:restart_server, {:operator, "files"}, "files"}

      assert {:ok, _view} = Secrets.set("mcp:files/env/API_KEY", "rotated", @opts)
      assert_received {:restart_server, {:operator, "files"}, "files"}
    end

    # An http server runs on the remote rail (M74 E4), so its last missing
    # value starts it like a stdio server's; a disabled one stays stopped.
    test "a disabled server is not started; an http server starts with its last value" do
      assert {:ok, _view} = Secrets.set("mcp:notes/env/NOTES_KEY", "n", @opts)
      refute_received {:restart_server, _source_id, _name}

      assert {:ok, _view} = Secrets.set("mcp:linear/header/Authorization", "Bearer lin", @opts)
      refute_received {:restart_server, _source_id, _name}

      assert {:ok, _view} = Secrets.set("mcp:linear/client_secret", "s", @opts)
      assert_received {:restart_server, {:operator, "linear"}, "linear"}
      assert McpSecrets.fetch("linear", {:header, "Authorization"}) == {:ok, "lin"}
    end
  end

  describe "refusals" do
    test "an id outside the grammar, an unknown server and an undeclared name, by field" do
      for {id, sentence} <- [
            {"mcp:files/env/1BAD", ~r/mcp:<server>\/env\/<NAME>/},
            {"mcp:absent/env/GITHUB_TOKEN", ~r/no MCP server by that name/},
            {"mcp:files/env/OTHER", ~r/does not declare that secret/},
            {"mcp:files/client_secret", ~r/does not declare that secret/}
          ] do
        assert {:error, {:invalid_params, "id", text}} = Secrets.set(id, "v", @opts)
        assert text =~ sentence
        assert {:error, {:invalid_params, "id", _text}} = Secrets.clear(id, @opts)
      end

      refute_received {:restart_server, _source_id, _name}
    end

    # The id grammar holds only names the rules allow, so a server named before
    # them stores no secret; the answer says how to get one that can.
    test "a server named before the rules is told to be added again under a lowercase name", %{
      home: home
    } do
      path = Path.join(home, "config.toml")

      File.write!(
        path,
        File.read!(path) <>
          "\n[mcp.servers.GitHub]\ncommand = \"npx\"\n" <>
          "env_secrets = [\"GITHUB_TOKEN\"]\n"
      )

      :ok = ConfigStore.apply_mcp_config()
      :ok = RestartState.record_persisted_baseline()

      for result <- [
            Secrets.set("mcp:GitHub/env/GITHUB_TOKEN", "v", @opts),
            Secrets.clear("mcp:GitHub/env/GITHUB_TOKEN")
          ] do
        assert {:error, {:invalid_params, "id", sentence}} = result
        assert sentence =~ "Remove the server and add it again under a lowercase name."
      end

      refute_received {:restart_server, _source_id, _name}
    end

    test "an empty value, or a Bearer scheme with nothing after it, is refused by field" do
      assert {:error, {:invalid_params, "value", _}} =
               Secrets.set("mcp:files/env/GITHUB_TOKEN", "", @opts)

      assert {:error, {:invalid_params, "value", "A secret cannot be empty."}} =
               Secrets.set("mcp:linear/header/Authorization", "Bearer ", @opts)
    end

    test "a write refused for an outside edit stores nothing", %{home: home} do
      path = Path.join(home, "config.toml")

      File.write!(
        path,
        File.read!(path) <> "\n[fermix_core.personalization]\nuser_name = \"Ada\"\n"
      )

      assert {:error, {:external_change, _sections}} =
               Secrets.set("mcp:files/env/GITHUB_TOKEN", "t", @opts)

      assert McpSecrets.fetch("files", {:env, "GITHUB_TOKEN"}) == {:error, :missing_secret}
    end
  end

  describe "forgetting a value" do
    test "the item is deleted and the answer says it is gone" do
      assert {:ok, _view} = Secrets.set("mcp:files/env/GITHUB_TOKEN", "t", @opts)

      assert {:ok, view} = Secrets.clear("mcp:files/env/GITHUB_TOKEN", @opts)
      assert view["present"] == false
      assert answer_shape(view) == answer_shape(fixture_result("secret_clear_external_env"))
      assert McpSecrets.fetch("files", {:env, "GITHUB_TOKEN"}) == {:error, :missing_secret}
    end

    # The program keeps the environment it started with, so the value is still
    # in use until the server stops.
    test "a server this build starts is stopped, stdio or http; a disabled one is left alone" do
      assert {:ok, _view} = Secrets.clear("mcp:files/env/API_KEY", @opts)
      assert_received {:stop_server, {:operator, "files"}}

      assert {:ok, _view} = Secrets.clear("mcp:notes/env/NOTES_KEY", @opts)
      refute_received {:stop_server, _source_id}

      assert {:ok, _view} = Secrets.clear("mcp:linear/header/Authorization", @opts)
      assert_received {:stop_server, {:operator, "linear"}}
    end
  end

  defp fixture_result(name) do
    :fermix_core
    |> Application.app_dir("priv/management/fixtures/success.jsonl")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.find(&(&1["name"] == name))
    |> get_in(["response", "result"])
  end

  # The restart reasons are whatever the suite left boot-bound, so the shape
  # compares the keys around them.
  defp answer_shape(answer), do: answer |> put_in(["restart", "reasons"], []) |> shape()

  defp shape(value) when is_map(value), do: Map.new(value, fn {k, v} -> {k, shape(v)} end)
  defp shape([]), do: []
  defp shape([head | _rest]), do: [shape(head)]
  defp shape(_value), do: :scalar

  defp restore(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore(key, value), do: Application.put_env(:fermix_core, key, value)
end
