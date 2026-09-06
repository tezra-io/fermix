defmodule FermixCore.Management.Doctor.Remediation do
  @moduledoc """
  What to do about a failed Doctor check, in the daemon's own words
  (M34 native setup §7.3).

  Keyed `<check id>.<status>`, the same key `remediation_code` already carries,
  so the code stays the stable identifier and this table is what turns it into
  something a surface can render. The code is kept and the app is never required
  to understand it: a check with no entry publishes `remediation: nil` and the
  summary is rendered with no action button.

  `action.kind` is the closed set a front-end can act on:

    * `settings_pane` — open the named settings pane
    * `system_settings` — open the named macOS settings pane
    * `job` — start the named job
    * `restart` — restart the engine, which the app owns as `lifecycle.prepare`
      then `lifecycle.commit`
    * `reload` — read the settings file again through `settings.reload`
    * `instructions` — show the named catalogue entry's sheet of commands, which
      is the only kind that can express a removal sequence
    * `none` — there is something to say and nothing to press

  Sentences are daemon-owned English, bounded to the same 256 bytes as a check
  summary, and carry no version numbers.
  """

  @max_bytes 256

  @entries %{
    "restart_pending.warning" => %{
      title: "Restart Fermix to apply your changes",
      body: "Some settings were changed since Fermix started and take effect on the next start.",
      action: %{kind: "restart", target: nil}
    },
    "external_config_change.warning" => %{
      title: "Settings changed outside Fermix",
      body:
        "The settings file was edited by something else, so saving is paused until it is read again.",
      action: %{kind: "reload", target: nil}
    },
    "external_config_change.failed" => %{
      title: "The settings file could not be read",
      body: "Fermix cannot parse the settings file, so it is running on what it read at startup.",
      action: %{kind: "instructions", target: "external_config_change.recovery"}
    },
    "legacy_service_unit.warning" => %{
      title: "Remove the other Fermix service",
      body: "A service installed another way is still registered on this Mac.",
      action: %{kind: "instructions", target: "legacy_service_unit.removal"}
    },
    "secret_acl_restricted.warning" => %{
      title: "Re-save the affected keys",
      body:
        "Some stored keys were written by an older install and cannot be read without a prompt.",
      action: %{kind: "settings_pane", target: "providers"}
    },
    "engine_path_baseline.warning" => %{
      title: "Some command line tools are out of reach",
      body:
        "The background service is missing directories where signing and plugin runtimes live.",
      action: %{kind: "none", target: nil}
    },
    "auth_token_expiry.warning" => %{
      title: "Sign in again",
      body: "A saved sign-in is close to expiring, so turns may start failing soon.",
      action: %{kind: "settings_pane", target: "providers"}
    },
    "auth_token_expiry.failed" => %{
      title: "Sign in again",
      body: "A saved sign-in has expired, so this provider cannot answer.",
      action: %{kind: "settings_pane", target: "providers"}
    }
  }

  @action_kinds ~w(settings_pane system_settings job restart reload instructions none)

  @type entry :: %{String.t() => term()}

  @doc "Every remediation key this table publishes."
  @spec keys() :: [String.t()]
  def keys, do: @entries |> Map.keys() |> Enum.sort()

  @doc "The action kinds a front-end must be able to render."
  @spec action_kinds() :: [String.t()]
  def action_kinds, do: @action_kinds

  @doc """
  The remediation for one check and status, or `nil` when there is none.

  A `nil` answer is a published state, not a gap: `passed`, `skipped`,
  `cancelled` and `not_applicable` name no action, and a check whose failure the
  operator can only read about carries a `none` action rather than an absent
  remediation.
  """
  @spec fetch(String.t(), String.t()) :: entry() | nil
  def fetch(id, status) when is_binary(id) and is_binary(status) do
    case Map.fetch(@entries, "#{id}.#{status}") do
      {:ok, entry} -> render(entry)
      :error -> nil
    end
  end

  defp render(entry) do
    %{
      "title" => bound(entry.title),
      "body" => bound(entry.body),
      "action" => %{"kind" => entry.action.kind, "target" => entry.action.target}
    }
  end

  defp bound(sentence) when byte_size(sentence) <= @max_bytes, do: sentence
  defp bound(sentence), do: binary_part(sentence, 0, @max_bytes)
end
