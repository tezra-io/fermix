defmodule FermixWebWeb.SetupLive.Accessories do
  @moduledoc """
  The browser setup's StackChan section (M91 E3; the Mac design's *Browser
  setup*): an optional block under the Realtime tab's voice settings with the
  switch that allows a StackChan connection, the daemon's own sentence for
  where it stands, the voice the next call takes, and Set up in Fermix, which
  opens the Mac app's Pet destination where pairing happens. The browser pairs
  nothing and holds no secret: the link carries no credential.

  It calls what the management methods call, in the page's own process:
  `FermixCore.Management.Accessories` for the status and
  `FermixCore.Management.Settings` for the `accessories` section, whose write
  starts or stops the accessory link at once. The switch is its own setter,
  never part of the voice form's unsaved draft. Off a local Mac primary the
  section says so and offers neither the switch nor the link.

  Seams, under `config :fermix_web, :accessories`: `management` (options for
  `Accessories`) and `settings` (options for `Settings`).
  """

  use FermixWebWeb, :html

  alias FermixCore.Management.Accessories, as: ManagementAccessories
  alias FermixCore.Management.Settings, as: ManagementSettings

  @section "accessories"
  @switch "accessories_enabled"
  # The Mac app's Pet destination; the route parser takes no extra path.
  @pet_url "fermix://pet"

  @doc "The section's state before anything is read."
  @spec initial() :: map()
  def initial, do: %{status: nil, notice: nil}

  @doc "Reads the accessory status for the section."
  @spec load(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def load(socket) do
    {:ok, status} = ManagementAccessories.status(management_opts())
    assign(socket, :accessories, %{socket.assigns.accessories | status: status})
  end

  @doc """
  One `accessories_*` event: the switch. Answers the socket and the settings
  write's result, so the page refreshes its report; a write the daemon
  refused, or a link that did not follow the switch, is said under it.
  """
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {Phoenix.LiveView.Socket.t(), map() | nil}
  def handle_event("accessories_switch", %{"enabled" => value}, socket)
      when value in ["true", "false"] do
    case ManagementSettings.apply(@section, %{@switch => value == "true"}, settings_opts()) do
      {:ok, result} -> {socket |> notice(side_effect(result)) |> load(), result}
      {:error, refusal} -> {socket |> notice(refusal_sentence(refusal)) |> load(), nil}
    end
  end

  defp side_effect(%{"side_effects" => [sentence | _rest]}), do: sentence
  defp side_effect(_result), do: nil

  defp refusal_sentence({:invalid_params, _field, sentence}), do: sentence

  defp refusal_sentence({:external_change, _sections}),
    do: "The settings file changed outside Fermix."

  defp refusal_sentence({:config_unreadable, sentence}), do: sentence

  defp refusal_sentence({:unknown_section, _section}),
    do: "StackChan setup needs a local Mac primary."

  defp notice(socket, sentence),
    do: assign(socket, :accessories, %{socket.assigns.accessories | notice: sentence})

  defp management_opts, do: Keyword.get(seams(), :management, [])
  defp settings_opts, do: Keyword.get(seams(), :settings, [])
  defp seams, do: Application.get_env(:fermix_web, :accessories, [])

  attr :accessories, :map, required: true

  @doc "The section, below the voice form."
  def panel(%{accessories: %{status: nil}} = assigns), do: ~H""

  def panel(assigns) do
    status = assigns.accessories.status

    assigns =
      assign(assigns,
        status: status,
        local?: status["state"] != "needs_local_primary",
        on?: status["enabled"],
        ready?: status["state"] == "on",
        # A robot left chosen when StackChan was turned off, or a choice that
        # cannot be read: the Mac's own voice does not work until the owner
        # chooses again, which the daemon's sentences say.
        mac_voice?: status["voice_device"]["device"] == "desktop",
        unreadable_sentence:
          if(status["voice_device"]["device"] == "unreadable",
            do: status["voice_device"]["sentence"]
          ),
        pet_url: @pet_url
      )

    ~H"""
    <section id="accessories" class="mt-10 rounded-box border border-base-300 p-5 space-y-4">
      <div class="flex items-center justify-between gap-4">
        <div>
          <h3 class="text-base font-semibold">
            StackChan <span class="badge badge-ghost badge-sm ml-1">Optional</span>
          </h3>
          <p class="text-sm text-base-content/70">
            Talk through your robot's microphone and speaker. Your voice model and call limits stay the same.
          </p>
        </div>
        <form :if={@local?} id="accessories-switch" phx-submit="accessories_switch">
          <input type="hidden" name="enabled" value={to_string(not @on?)} />
          <button type="submit" class={["btn btn-sm", @on? && "btn-primary"]}>
            {if @on?, do: "On", else: "Off"}
          </button>
        </form>
      </div>

      <p id="accessories-sentence" class="text-sm">{@status["sentence"]}</p>
      <p
        :if={@unreadable_sentence}
        id="accessories-voice-device-sentence"
        class="text-sm text-warning"
      >
        {@unreadable_sentence}
      </p>
      <p :if={@accessories.notice} id="accessories-notice" class="text-sm text-warning">
        {@accessories.notice}
      </p>

      <div :if={@local?} class="text-sm space-y-1">
        <p>
          <span class="text-base-content/70">Voice for the next call</span>
          <span id="accessories-voice" class="ml-2 font-medium">
            {@status["voice"]["engine_label"]} · {@status["voice"]["voice"]}
          </span>
        </p>
        <p :if={not @status["voice"]["ready"]} id="accessories-voice-sentence" class="text-warning">
          {@status["voice"]["sentence"]}
        </p>
      </div>

      <div :if={@local?} class="flex items-center gap-3">
        <a
          :if={@ready?}
          id="accessories-setup-link"
          href={@pet_url}
          class="btn btn-sm btn-outline"
        >
          Set up in Fermix
        </a>
        <span :if={@on? or @mac_voice?} class="text-sm text-base-content/70">
          {if @on?,
            do: "Connect and pair your robot from Pet in the Mac app.",
            else: "StackChan is off by default. Your Mac voice still works."}
        </span>
      </div>
    </section>
    """
  end
end
