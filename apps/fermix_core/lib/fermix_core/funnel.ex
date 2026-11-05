defmodule FermixCore.Funnel do
  @moduledoc """
  The Tailscale Funnel mount of one webhook path Fermix serves on loopback
  (M60 §6.5; Always On, "Inbound webhooks without a public IP"): the one
  builder of its command, which the cue setup page, `mix fermix.cues.funnel`
  and the Always On screen print.

  A mount puts one path on the internet at the machine's ts.net name and
  proxies it to the same path on `127.0.0.1:<port>`: Tailscale strips the
  mount point before proxying, so the target carries the path again. Never
  `/`: Funnel publishes the whole of port 443 for whatever `tailscale serve`
  has there, so Fermix mounts only its webhook paths.

  The paths are WhatsApp's (`whatsapp_path/0`, on the web listener: Meta
  checks it with GET and posts with POST, and one mount carries both) and
  each cue webhook source's (`Cues.Webhook.path/2`, on the cue door). Pure:
  nothing here runs `tailscale`.
  """

  @whatsapp_path "/webhook/whatsapp"

  @doc "The path the web listener serves WhatsApp's webhook on."
  @spec whatsapp_path() :: String.t()
  def whatsapp_path, do: @whatsapp_path

  @doc """
  The `tailscale` arguments that mount `path` on Funnel, proxied to the same
  path on `127.0.0.1:port`. `path` is absolute and never `/`.
  """
  @spec mount_args(String.t(), :inet.port_number()) :: [String.t()]
  def mount_args("/" <> rest = path, port) when rest != "" and port in 1..65_535,
    do: ["funnel", "--bg", "--set-path=" <> path, "http://127.0.0.1:#{port}" <> path]

  @doc "The command that mounts `path` on Funnel (`mount_args/2`), as an owner types it."
  @spec mount_command(String.t(), :inet.port_number()) :: String.t()
  def mount_command(path, port), do: path |> mount_args(port) |> command()

  @doc "One `tailscale` command, written from its arguments."
  @spec command([String.t()]) :: String.t()
  def command(args) when is_list(args), do: Enum.join(["tailscale" | args], " ")
end
