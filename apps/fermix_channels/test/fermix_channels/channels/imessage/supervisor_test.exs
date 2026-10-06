defmodule FermixChannels.Channels.IMessage.SupervisorTest do
  @moduledoc """
  `IMessage.Supervisor` (MILESTONE_54 §5): the Port first, the Listener after
  it, `:rest_for_one`; a protocol mismatch fails the start loud with that
  class; the executable and the home come from injected core seams.
  """
  use ExUnit.Case, async: false

  alias FermixChannels.Channels.IMessage
  alias FermixChannels.Channels.IMessage.Listener
  alias FermixChannels.Channels.IMessage.Port, as: HelperPort
  alias FermixTestSupport.SafeRm

  @script """
  #!/bin/sh
  home="$3"
  version=1
  if [ -f "$home/protocol_version" ]; then
    read version < "$home/protocol_version"
  fi
  while IFS= read -r line; do
    id=${line#*\\"id\\":}
    id=${id%%,*}
    method=${line#*\\"method\\":\\"}
    method=${method%%\\"*}
    case "$method" in
      initialize)
        printf '{"id":%s,"result":{"protocol_version":%s,"helper_version":"0.0.0-test","macos_version":"27.0","bundle_id":"io.tezra.fermix.messages","db_generation":{"inode":9,"birth_time":"2026-09-01T00:00:00Z"}}}\\n' "$id" "$version" ;;
      probe)
        printf '{"id":%s,"result":{"helper_version":"0.0.0-fake","full_disk_access":"granted","db":"readable","automation":"granted","messages_running":true,"signed_in":true,"user_session":true,"policy":"confirmed","self_aliases":[]}}\\n' "$id" ;;
      policy.get)
        printf '{"id":%s,"result":{"posture":"dedicated_account","owner_handle":"+15551234567","handles":["+15551234567"],"confirmed_at":"2026-10-01T09:30:00Z"}}\\n' "$id" ;;
      watch.subscribe)
        printf '{"id":%s,"result":{"started_at_rowid":500,"replay_skipped":0}}\\n' "$id" ;;
      shutdown)
        printf '{"id":%s,"result":{}}\\n' "$id"
        exit 0 ;;
      *)
        printf '{"id":%s,"result":{}}\\n' "$id" ;;
    esac
  done
  exit 0
  """

  defmodule Installed do
    @moduledoc false
    def binary_path, do: {:ok, Process.get(:imessage_test_executable)}
  end

  defmodule NotInstalled do
    @moduledoc false
    def binary_path, do: {:error, :not_installed}
  end

  setup do
    home = SafeRm.make_tmp_dir!("imessage-supervisor")
    executable = Path.join(home, "fermix-messages")
    File.write!(executable, @script)
    File.chmod!(executable, 0o755)
    on_exit(fn -> SafeRm.rm_rf!(home) end)

    unique = System.unique_integer([:positive])

    opts = [
      name: :"imessage_sup_#{unique}",
      port_name: :"imessage_sup_port_#{unique}",
      listener_name: :"imessage_sup_listener_#{unique}",
      executable: executable,
      home: home,
      recipients: %{owner: "+15551234567", handles: ["+15551234567"]}
    ]

    %{home: home, executable: executable, opts: opts}
  end

  test "starts the Port, then a Listener that subscribes through it", %{opts: opts} do
    sup = start_supervised!({IMessage.Supervisor, opts})

    assert [{Listener, _listener, :worker, _}, {HelperPort, _port, :worker, _}] =
             Supervisor.which_children(sup)

    assert_eventually(fn -> Listener.status(opts[:listener_name]).phase == :live end)
    assert Listener.status(opts[:listener_name]).cursor == 500
    assert %{status: :up} = HelperPort.status(opts[:port_name])
  end

  test "a helper on another protocol version fails the start with that class", ctx do
    File.write!(Path.join(ctx.home, "protocol_version"), "2\n")
    Process.flag(:trap_exit, true)

    assert {:error, reason} = IMessage.Supervisor.start_link(ctx.opts)
    assert inspect(reason) =~ "helper_protocol_mismatch"
  end

  test "the executable is resolved through the installer seam", ctx do
    Process.put(:imessage_test_executable, ctx.executable)
    opts = ctx.opts |> Keyword.delete(:executable) |> Keyword.put(:installer, Installed)

    # Started from this process, because the installer seam answers from it.
    {:ok, sup} = IMessage.Supervisor.start_link(opts)
    assert_eventually(fn -> Listener.status(opts[:listener_name]).phase == :live end)
    :ok = Supervisor.stop(sup)

    missing = ctx.opts |> Keyword.delete(:executable) |> Keyword.put(:installer, NotInstalled)
    assert IMessage.Supervisor.start_link(missing) == {:error, {:helper_missing, :not_installed}}
  end

  test "without injected recipients the channel's config must name its owner", ctx do
    previous = Application.get_env(:fermix_channels, :imessage)
    Application.put_env(:fermix_channels, :imessage, enabled: true)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:fermix_channels, :imessage)
        config -> Application.put_env(:fermix_channels, :imessage, config)
      end
    end)

    opts = Keyword.delete(ctx.opts, :recipients)
    assert IMessage.Supervisor.start_link(opts) == {:error, :owner_not_configured}
  end

  defp assert_eventually(fun, attempts \\ 400)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(5)
      assert_eventually(fun, attempts - 1)
    end
  end
end
