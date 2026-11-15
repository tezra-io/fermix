defmodule FermixWebWeb.SetupLive.AccessoriesPane do
  @moduledoc """
  Draws what the StackChan section offers on a local Mac primary with
  StackChan on (`SetupLive.Accessories`), from `accessories.status` as it
  last answered: the USB devices with the actions each publishes and, on the
  one being paired, the attempt with its code; the paired robots with their
  connection, power, call and diagnostics; and the voice device.

  Every sentence is the daemon's, the eFuse note before Matches included
  (`Management.Accessories.efuse_sentence/0`), and every button is an action
  a port or a robot publishes. The page's own words are the labels, as the
  Mac app's Pet words them, and the questions Release, Forget and Revoke ask
  in place before they act. A robot attached on a port is drawn once, as the
  robot.
  """

  use FermixWebWeb, :html

  alias FermixWebWeb.SetupLive.PhonePairing

  @port_labels %{
    "pair" => "Pair",
    "pair_cancel" => "Cancel pairing",
    "retry" => "Try again",
    "release" => "Release for firmware update…",
    "reconnect" => "Reconnect"
  }
  # `select` is the voice device's own row; checks and Calibrate head stay in
  # the Mac app's Pet.
  @robot_labels %{
    "start_call" => "Start test call",
    "pair" => "Pair",
    "retry" => "Try again",
    "reconnect" => "Reconnect",
    "release" => "Release for firmware update…",
    "forget" => "Forget…",
    "revoke" => "Revoke…"
  }
  @power_labels %{
    "usb" => "Powered by USB",
    "battery" => "On battery",
    "low" => "Power is low",
    "critical" => "Power is critically low"
  }
  # The robot's eight counters, in the order the contract lists them.
  @diag_labels [
    {"uptime_s", "Running for"},
    {"frames_rx", "Frames received"},
    {"frames_tx", "Frames sent"},
    {"crc_errors", "CRC errors"},
    {"resync_bytes", "Bytes skipped to resync"},
    {"pcm_seq_gaps", "Audio sequence gaps"},
    {"mic_overflows", "Microphone overflows"},
    {"spk_underflows", "Speaker underflows"}
  ]
  @bodies %{
    release:
      "Fermix lets go of its USB port so the installer can use it. It stays released until " <>
        "you reconnect it.",
    forget:
      "The robot erases its pairing, and a call on it ends. To use it again, pair it again.",
    revoke:
      "This Mac stops trusting the robot without telling it, so its next connection is " <>
        "refused. Use this for a robot that is lost or not plugged in."
  }
  @answers %{release: "Release", forget: "Forget", revoke: "Revoke"}

  attr :accessories, :map, required: true
  attr :efuse_sentence, :string, required: true

  @doc "The USB devices, the paired robots and the voice device."
  def manage(assigns) do
    status = assigns.accessories.status
    robots = status["accessories"]
    ids = MapSet.new(robots, & &1["accessory_id"])

    assigns =
      assign(assigns,
        status: status,
        robots: robots,
        ports: Enum.reject(status["ports"], &robot_port?(&1, ids)),
        name: assigns.accessories.name || kind_name(status["kinds"]),
        # A choice that is not this Mac (one that cannot be read included) is
        # shown with its sentence, so This Mac can be chosen again.
        choose_device?: robots != [] or status["voice_device"]["device"] != "desktop"
      )

    ~H"""
    <div id="accessories-manage" class="space-y-5">
      <div
        :if={@ports != [] or @status["ports_sentence"]}
        id="accessories-ports"
        class="space-y-2"
      >
        <p class="text-sm font-medium">USB devices</p>
        <p :if={@status["ports_sentence"]} class="text-sm text-base-content/70">
          {@status["ports_sentence"]}
        </p>
        <.port
          :for={port <- @ports}
          port={port}
          pairing={@status["pairing"]}
          name={@name}
          accessories={@accessories}
          efuse_sentence={@efuse_sentence}
        />
      </div>

      <div :if={@robots != []} id="accessories-robots" class="space-y-2">
        <p class="text-sm font-medium">Paired robots</p>
        <.robot
          :for={row <- @robots}
          row={row}
          call={call_on(@status["call"], row)}
          accessories={@accessories}
        />
      </div>

      <.voice_device
        :if={@choose_device?}
        voice_device={@status["voice_device"]}
        robots={@robots}
        refusal={@accessories.refusal}
      />
    </div>
    """
  end

  defp robot_port?(port, ids),
    do: port["status"] == "attached" and MapSet.member?(ids, port["accessory_id"])

  defp kind_name([%{"name" => name} | _rest]) when is_binary(name), do: name
  defp kind_name(_kinds), do: ""

  defp call_on(%{"accessory_id" => id} = call, %{"accessory_id" => id}), do: call
  defp call_on(_call, _row), do: nil

  # -- a USB device ------------------------------------------------------------

  attr :port, :map, required: true
  attr :pairing, :map, default: nil
  attr :name, :string, required: true
  attr :accessories, :map, required: true
  attr :efuse_sentence, :string, required: true

  defp port(assigns) do
    assigns = assign(assigns, asked?: asked?(assigns.accessories.asking, assigns.port["path"]))

    ~H"""
    <div data-path={@port["path"]} class="space-y-2 rounded-field border border-base-300 p-3">
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <p class="text-sm font-medium">USB device</p>
          <p class="truncate text-xs text-base-content/60">{device_line(@port)}</p>
        </div>
        <span
          :if={@port["retrying"] or @port["status"] == "attaching"}
          class="loading loading-spinner loading-xs"
          aria-hidden="true"
        />
      </div>
      <p class="text-sm">{@port["sentence"]}</p>
      <.pairing
        :if={@pairing && @pairing["path"] == @port["path"]}
        pairing={@pairing}
        port={@port}
        efuse_sentence={@efuse_sentence}
      />
      <.name_form :if={"pair_begin" in @port["actions"]} port={@port} name={@name} />
      <.confirm :if={@asked?} asking={@accessories.asking} />
      <div :if={not @asked?} class="flex flex-wrap justify-end gap-2">
        <.port_action :for={action <- @port["actions"]} action={action} port={@port} />
      </div>
      <.refusal refusal={@accessories.refusal} where={@port["path"]} />
    </div>
    """
  end

  # The device node's own name, and the USB serial string where it has one.
  defp device_line(%{"path" => path, "serial" => serial}) when is_binary(serial),
    do: "#{Path.basename(path)} · #{serial}"

  defp device_line(%{"path" => path}), do: Path.basename(path)

  attr :action, :string, required: true
  attr :port, :map, required: true

  # The install guide is the link the daemon publishes; a name and Pair
  # StackChan are the form above; `update_fermix` is the sentence's to say.
  defp port_action(%{action: "open_install_guide"} = assigns) do
    ~H"""
    <a
      :if={@port["install_guide"]}
      href={@port["install_guide"]}
      target="_blank"
      rel="noopener noreferrer"
      class="btn btn-sm"
    >
      Open install guide
    </a>
    """
  end

  defp port_action(%{action: action} = assigns) when is_map_key(@port_labels, action) do
    assigns = assign(assigns, label: Map.fetch!(@port_labels, action))

    ~H"""
    <button
      type="button"
      class="btn btn-sm"
      phx-click="accessories_port"
      phx-value-action={@action}
      phx-value-path={@port["path"]}
    >
      {@label}
    </button>
    """
  end

  defp port_action(assigns), do: ~H""

  attr :port, :map, required: true
  attr :name, :string, required: true

  defp name_form(assigns) do
    ~H"""
    <form
      id="accessories-pair-form"
      phx-submit="accessories_pair_begin"
      phx-change="accessories_name"
      class="space-y-1"
    >
      <input type="hidden" name="path" value={@port["path"]} />
      <label class="block text-sm" for="accessories-robot-name">Robot name</label>
      <div class="flex gap-2">
        <input
          id="accessories-robot-name"
          type="text"
          name="name"
          value={@name}
          maxlength="64"
          class="input input-sm input-bordered w-full"
        />
        <button type="submit" class="btn btn-sm btn-primary">Pair StackChan</button>
      </div>
    </form>
    """
  end

  # -- the attempt ---------------------------------------------------------------

  attr :pairing, :map, required: true
  attr :port, :map, required: true
  attr :efuse_sentence, :string, required: true

  # The port's own sentence already says an open attempt's step; the attempt
  # adds its code and the owner's answer, and how it ended or that it is done.
  # Neither answer is the default.
  defp pairing(assigns) do
    pairing = assigns.pairing

    assigns =
      assign(assigns,
        sentence: if(pairing["sentence"] != assigns.port["sentence"], do: pairing["sentence"]),
        code:
          if(pairing["phase"] in ["offered", "revealed"] and is_binary(pairing["code"]),
            do: pairing["code"]
          )
      )

    ~H"""
    <div id="accessories-pairing" class="space-y-2">
      <p :if={@sentence} class="text-sm">{@sentence}</p>
      <div :if={@code} class="space-y-2">
        <p
          id="accessories-code"
          class="text-center font-mono text-4xl font-semibold tracking-widest tabular-nums"
          aria-label={PhonePairing.spoken(@code, "Pairing code")}
        >
          {PhonePairing.grouped(@code)}
        </p>
        <p :if={@pairing["round"] > 1} class="text-center text-xs text-base-content/70">
          New code, try {@pairing["round"]} of {@pairing["max_rounds"]}
        </p>
        <p :if={@pairing["owner_confirmed"]} class="text-sm">
          Confirm the code on your robot too.
        </p>
        <div :if={not @pairing["owner_confirmed"]} class="space-y-2">
          <p id="accessories-efuse-note" class="text-xs text-base-content/70">
            {@efuse_sentence}
          </p>
          <div class="flex justify-end gap-2">
            <button
              type="button"
              class="btn btn-sm"
              phx-click="accessories_decide"
              phx-value-matches="false"
            >
              Doesn't match
            </button>
            <button
              type="button"
              class="btn btn-sm"
              phx-click="accessories_decide"
              phx-value-matches="true"
            >
              Matches
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # -- a paired robot --------------------------------------------------------------

  attr :row, :map, required: true
  attr :call, :map, default: nil
  attr :accessories, :map, required: true

  defp robot(assigns) do
    row = assigns.row

    assigns =
      assign(assigns,
        asked?: asked?(assigns.accessories.asking, row["accessory_id"]),
        power: power_line(row)
      )

    ~H"""
    <div
      data-accessory={@row["accessory_id"]}
      class="space-y-2 rounded-field border border-base-300 p-3"
    >
      <div class="min-w-0">
        <p class="truncate text-sm font-medium">{@row["name"]}</p>
        <p class="font-mono text-xs text-base-content/60" aria-label={"Robot ID " <> @row["short_id"]}>
          {@row["short_id"]}
        </p>
      </div>
      <p class="text-sm">{@row["sentence"]}</p>
      <p :if={@power} class="text-xs text-base-content/70">{@power}</p>
      <.call :if={@call} call={@call} id={@row["accessory_id"]} />
      <p :if={!@call && @row["last_call"]} class="text-xs text-base-content/70">
        {@row["last_call"]["sentence"]}
      </p>
      <.diagnostics :if={@row["diag"]} diag={@row["diag"]} />
      <.confirm :if={@asked?} asking={@accessories.asking} />
      <div :if={not @asked?} class="flex flex-wrap justify-end gap-2">
        <.robot_action :for={action <- @row["actions"]} action={action} row={@row} />
      </div>
      <.refusal refusal={@accessories.refusal} where={@row["accessory_id"]} />
    </div>
    """
  end

  attr :action, :string, required: true
  attr :row, :map, required: true

  defp robot_action(%{action: action} = assigns) when is_map_key(@robot_labels, action) do
    assigns = assign(assigns, label: Map.fetch!(@robot_labels, action))

    ~H"""
    <button
      type="button"
      class="btn btn-sm"
      phx-click="accessories_robot"
      phx-value-action={@action}
      phx-value-id={@row["accessory_id"]}
      phx-value-path={@row["path"]}
    >
      {@label}
    </button>
    """
  end

  defp robot_action(assigns), do: ~H""

  # The battery where the robot has one, and its power as it reports it.
  defp power_line(%{"state" => %{} = state, "capabilities" => caps}) do
    words =
      Enum.reject([battery(state, "battery" in caps), @power_labels[state["power"]]], &is_nil/1)

    if words == [], do: nil, else: Enum.join(words, " · ")
  end

  defp power_line(_row), do: nil

  defp battery(%{"battery" => percent}, true) when is_integer(percent), do: "Battery #{percent}%"
  defp battery(_state, true), do: "No battery reading"
  defp battery(_state, false), do: nil

  attr :call, :map, required: true
  attr :id, :string, required: true

  # The robot's call, by the voice it started with; one that is ending has
  # nothing left to end.
  defp call(assigns) do
    ~H"""
    <div class="space-y-1 rounded-field bg-base-200 p-3">
      <p class="text-sm font-medium">
        In a call
        <span class="font-normal text-base-content/70">
          · {@call["engine_label"]} · {@call["voice"]}
        </span>
      </p>
      <p :if={@call["phase_sentence"]} class="text-xs text-base-content/70">
        {@call["phase_sentence"]}
      </p>
      <div :if={@call["phase"] != "ending"} class="flex justify-end">
        <button
          type="button"
          class="btn btn-sm"
          phx-click="accessories_robot"
          phx-value-action="end_call"
          phx-value-id={@id}
        >
          End call
        </button>
      </div>
    </div>
    """
  end

  attr :diag, :map, required: true

  defp diagnostics(assigns) do
    assigns = assign(assigns, labels: @diag_labels)

    ~H"""
    <details class="text-xs">
      <summary class="cursor-pointer text-base-content/70">Diagnostics</summary>
      <p class="mt-1 text-base-content/60">
        The robot's own counters since it started, as it last reported them.
      </p>
      <dl class="mt-1 grid grid-cols-[1fr_auto] gap-x-4 gap-y-0.5">
        <div :for={{key, label} <- @labels} class="contents">
          <dt>{label}</dt>
          <dd class="text-right tabular-nums">{counter(key, @diag[key])}</dd>
        </div>
      </dl>
    </details>
    """
  end

  defp counter("uptime_s", seconds) when is_integer(seconds), do: duration(seconds)
  defp counter(_key, value) when is_integer(value), do: Integer.to_string(value)

  defp duration(seconds) do
    hours = div(seconds, 3_600)
    minutes = seconds |> rem(3_600) |> div(60)

    cond do
      hours > 0 -> "#{hours} h #{minutes} min"
      minutes > 0 -> "#{minutes} min #{rem(seconds, 60)} s"
      true -> "#{seconds} s"
    end
  end

  # -- the voice device ------------------------------------------------------------

  attr :voice_device, :map, required: true
  attr :robots, :list, required: true
  attr :refusal, :any, required: true

  # This Mac or a paired robot, changeable only while no call runs or
  # settles; the daemon's sentence says why it cannot change, or what an
  # unreadable choice needs.
  defp voice_device(assigns) do
    ~H"""
    <div id="accessories-voice-device" class="space-y-2">
      <p class="text-sm font-medium">Voice device</p>
      <div class="flex flex-wrap gap-2">
        <.device_choice
          device="desktop"
          label="This Mac"
          voice_device={@voice_device}
        />
        <.device_choice
          :for={row <- @robots}
          device={"accessory:" <> row["accessory_id"]}
          label={row["name"]}
          voice_device={@voice_device}
        />
      </div>
      <p :if={@voice_device["sentence"]} class="text-xs text-warning">
        {@voice_device["sentence"]}
      </p>
      <.refusal refusal={@refusal} where="voice_device" />
    </div>
    """
  end

  attr :device, :string, required: true
  attr :label, :string, required: true
  attr :voice_device, :map, required: true

  defp device_choice(assigns) do
    assigns = assign(assigns, chosen?: assigns.voice_device["device"] == assigns.device)

    ~H"""
    <button
      type="button"
      class={["btn btn-sm", @chosen? && "btn-active"]}
      aria-pressed={to_string(@chosen?)}
      disabled={not @voice_device["changeable"]}
      phx-click="accessories_voice_device"
      phx-value-device={@device}
    >
      {@label}
    </button>
    """
  end

  # -- asking first, and refusals ------------------------------------------------------

  attr :asking, :map, required: true

  defp confirm(assigns) do
    assigns =
      assign(assigns,
        question: question(assigns.asking),
        body: Map.fetch!(@bodies, assigns.asking.kind),
        answer: Map.fetch!(@answers, assigns.asking.kind)
      )

    ~H"""
    <div data-confirm class="space-y-2 rounded-field bg-base-200 p-3">
      <p class="text-sm font-medium">{@question}</p>
      <p class="text-xs text-base-content/70">{@body}</p>
      <div class="flex justify-end gap-2">
        <button type="button" class="btn btn-sm" phx-click="accessories_withdraw">Cancel</button>
        <button type="button" class="btn btn-sm btn-error" phx-click="accessories_confirm">
          {@answer}
        </button>
      </div>
    </div>
    """
  end

  defp question(%{kind: :release, name: nil}),
    do: "Release this USB device for a firmware update?"

  defp question(%{kind: :release, name: name}), do: "Release #{name} for a firmware update?"
  defp question(%{kind: :forget, name: name}), do: "Forget #{name || "this robot"}?"
  defp question(%{kind: :revoke, name: name}), do: "Revoke #{name || "this robot"}?"

  defp asked?(%{where: where}, where), do: true
  defp asked?(_asking, _where), do: false

  attr :refusal, :any, required: true
  attr :where, :string, required: true

  defp refusal(assigns) do
    assigns = assign(assigns, sentence: refused(assigns.refusal, assigns.where))

    ~H"""
    <p :if={@sentence} data-refusal class="text-xs text-error">{@sentence}</p>
    """
  end

  defp refused({where, sentence}, where), do: sentence
  defp refused(_refusal, _where), do: nil
end
