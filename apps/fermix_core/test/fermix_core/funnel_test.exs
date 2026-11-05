defmodule FermixCore.FunnelTest do
  # The one builder of a Tailscale Funnel mount's command, which the cue setup
  # page, `mix fermix.cues.funnel` and the Always On screen print.
  use ExUnit.Case, async: true

  alias FermixCore.Cues.Webhook
  alias FermixCore.Funnel

  test "a mount puts one path on Funnel, proxied to the same path on loopback" do
    path = Webhook.path("gh-hooks", "R4nd0m-path_secret0123")

    assert Funnel.mount_args(path, 4032) == [
             "funnel",
             "--bg",
             "--set-path=" <> path,
             "http://127.0.0.1:4032" <> path
           ]

    assert Funnel.mount_command(path, 4032) ==
             "tailscale funnel --bg --set-path=#{path} http://127.0.0.1:4032#{path}"
  end

  test "WhatsApp's mount is its webhook path on the web listener, one mount for GET and POST" do
    assert Funnel.whatsapp_path() == "/webhook/whatsapp"

    assert Funnel.mount_command(Funnel.whatsapp_path(), 4030) ==
             "tailscale funnel --bg --set-path=/webhook/whatsapp " <>
               "http://127.0.0.1:4030/webhook/whatsapp"
  end

  test "any tailscale command is written the one way" do
    assert Funnel.command(["funnel", "--https=443", "--set-path=/webhook/whatsapp", "off"]) ==
             "tailscale funnel --https=443 --set-path=/webhook/whatsapp off"
  end

  # Funnel publishes the whole of port 443 for whatever `tailscale serve` has
  # there, so the root, a relative path and a port outside the bounds are
  # refused before any command is written.
  test "never the root, a relative path or a port outside the bounds" do
    for {path, port} <-
          [{"/", 4030}, {"webhook/whatsapp", 4030}, {"", 4030}] ++
            [{"/webhook/whatsapp", 0}, {"/webhook/whatsapp", 65_536}] do
      assert_raise FunctionClauseError, fn -> Funnel.mount_args(path, port) end
    end
  end
end
