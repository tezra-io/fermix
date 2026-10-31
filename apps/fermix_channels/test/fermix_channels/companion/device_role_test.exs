defmodule FermixChannels.Companion.DeviceRoleTest do
  # The companion request path is the outermost admission for the Mac app's
  # chat: in the device role a `msg` or `command` is refused there by name,
  # before it is claimed, written to the timeline or ingested, and the client is
  # told the refusal's own sentence.
  use ExUnit.Case, async: true

  alias FermixChannels.Companion.Endpoint
  alias FermixChannels.Companion.Requests

  @device %{role: :device, primary: "aws i-0f3b1c"}
  @sentence "This engine runs in the device role; the primary is aws i-0f3b1c."
  # A line's arrival over the socket on a loaded runner (see ConnectionTest).
  @arrival_ms 10_000

  # Every collaborator past the refusal reports that it was reached.
  defmodule Reached do
    def claim_client_request(_profile, client_id, _type, _payload, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:reached, :claim, client_id})
      {:error, :reached}
    end

    def epoch(test_pid) do
      send(test_pid, {:reached, :coordinator, nil})
      "epoch"
    end

    def ingest(_messages, opts) do
      send(Keyword.fetch!(opts, :agent_server), {:reached, :ingest, nil})
      :ok
    end
  end

  defp request_opts do
    [
      engine_role: @device,
      store: Reached,
      store_opts: [test_pid: self()],
      coordinator: Reached,
      request_coordinator: self(),
      gateway: Reached,
      agent_server: self()
    ]
  end

  defp event(type, client_msg_id) do
    payload = %{"client_msg_id" => client_msg_id, "profile_id" => "main", "text" => "hi"}

    %{
      type: type,
      payload: if(type == "command", do: Map.put(payload, "name", "new"), else: payload)
    }
  end

  describe "Requests.request/3" do
    for type <- ["msg", "command"] do
      @type_name type

      test "refuses a #{type} by name before anything is claimed or run" do
        assert Requests.request(event(@type_name, "c-1"), %{}, request_opts()) ==
                 {:error, {:device_role, @sentence}}

        refute_received {:reached, _what, _id}
      end
    end
  end

  describe "over companion.sock" do
    setup do
      unique = System.unique_integer([:positive])
      registry = :"companion_device_registry_#{unique}"
      connections = :"companion_device_sup_#{unique}"
      # A socket address is short: it lives directly under the temp root.
      socket_path = Path.join(System.tmp_dir!(), "fermix-companion-device-#{unique}.sock")
      on_exit(fn -> FermixTestSupport.SafeRm.rm(socket_path) end)

      start_supervised!({Registry, keys: :duplicate, name: registry})

      start_supervised!(
        Supervisor.child_spec({DynamicSupervisor, name: connections, strategy: :one_for_one},
          id: connections
        )
      )

      start_supervised!(
        {Endpoint,
         name: :"companion_device_endpoint_#{unique}",
         socket_path: socket_path,
         max_clients: 1,
         connection_supervisor: connections,
         connection_opts: [registry: registry, request_opts: request_opts()]}
      )

      %{socket_path: socket_path}
    end

    test "the Mac app is told the device-role sentence for its message", %{socket_path: path} do
      client = connect(path)
      send_line(client, %{"type" => "client_hello", "protocol_version" => 5})
      assert %{"type" => "server_hello"} = recv(client)

      send_line(client, %{
        "type" => "msg",
        "client_msg_id" => "c-9",
        "profile_id" => "main",
        "text" => "hi",
        "attach_ids" => []
      })

      assert recv(client) == %{
               "type" => "error",
               "reason" => "request_failed",
               "message" => @sentence,
               "client_msg_id" => "c-9"
             }

      refute_received {:reached, _what, _id}
    end
  end

  defp connect(path) do
    {:ok, socket} =
      :gen_tcp.connect({:local, String.to_charlist(path)}, 0, [
        :binary,
        active: false,
        packet: :line,
        buffer: 128 * 1_024
      ])

    socket
  end

  defp send_line(socket, map), do: :ok = :gen_tcp.send(socket, Jason.encode!(map) <> "\n")

  defp recv(socket) do
    {:ok, line} = :gen_tcp.recv(socket, 0, @arrival_ms)
    Jason.decode!(line)
  end
end
