defmodule FermixWebWeb.SetupLive.AlwaysOnPane do
  @moduledoc """
  Draws the Always On tab from its state (`SetupLive.AlwaysOn`): the summary
  card (the sentence, the step in hand, the one action, the error line and
  the alternatives), the step the pressed action opened (a dialog with the
  confirm sentence and the recovery passphrase), Details from
  `detail.lines`, the Tailscale Funnel mounts the server needs
  (`detail.webhooks`, each command with its own Copy), and the code of the
  owner's server with the optional Tailscale step's command.

  Every word is the engine's (the summary's, with `Management.Copy`'s action
  labels) but a field's label and the page's own Back, Copy, Done and
  Details.
  """

  use FermixWebWeb, :html

  @card "rounded-box border border-base-300 bg-base-100/80 p-5 shadow-sm"
  # The steps that stop something, drawn as such.
  @destructive ~w(cancel)

  attr :always_on, :map, required: true

  @doc "The Always On tab."
  def pane(assigns) do
    ~H"""
    <div id="always-on-pane" class="space-y-6">
      <.title />
      <p :if={!@always_on.summary} class="text-sm text-base-content/60">
        <span class="loading loading-spinner loading-sm" />
      </p>
      <.card :if={@always_on.summary} always_on={@always_on} />
      <.own_code :if={@always_on.code} code={@always_on.code} />
      <.details :if={@always_on.summary} detail={@always_on.summary["detail"] || %{}} />
      <.webhooks
        :if={@always_on.summary && @always_on.summary["detail"]["webhooks"]}
        webhooks={@always_on.summary["detail"]["webhooks"]}
      />
    </div>
    """
  end

  defp title(assigns) do
    ~H"""
    <div class="min-w-0">
      <h2 class="text-2xl font-semibold tracking-normal">Always On</h2>
      <p class="mt-1 text-sm text-base-content/70">
        Fermix on a server you control, so it keeps working with this computer closed.
      </p>
    </div>
    """
  end

  # -- the summary card ----------------------------------------------------------

  attr :always_on, :map, required: true

  defp card(assigns) do
    summary = assigns.always_on.summary
    detail = summary["detail"] || %{}

    assigns =
      assign(assigns,
        summary: summary,
        detail: detail,
        acting: assigns.always_on.acting,
        alternatives: detail["alternatives"] || [],
        card: @card
      )

    ~H"""
    <section id="always-on-status" class={@card}>
      <p id="always-on-sentence" class="text-sm font-medium leading-6">{@summary["sentence"]}</p>
      <p
        :if={@detail["progress"]}
        id="always-on-progress"
        class="mt-2 flex items-center gap-2 text-sm text-base-content/70"
      >
        <span class="loading loading-spinner loading-xs" />
        <span>{@detail["progress"]}</span>
      </p>
      <p :for={said <- notes(@detail)} class="mt-2 text-sm text-base-content/70">{said}</p>
      <.readiness items={@detail["readiness"] || []} />
      <div class="mt-4 flex flex-wrap items-center gap-2">
        <.primary :if={@summary["action"]} action={@summary["action"]} acting={@acting} />
        <.press
          :for={action <- @detail["actions"] || []}
          action={action}
          acting={@acting}
          class="btn btn-sm btn-outline"
        />
      </div>
      <.error :if={!@always_on.open} error={@always_on.error} />
      <div
        :if={@alternatives != []}
        id="always-on-alternatives"
        class="mt-3 flex flex-wrap gap-x-4 gap-y-1 text-sm"
      >
        <.alternative :for={action <- @alternatives} action={action} acting={@acting} />
      </div>
      <.step :if={@always_on.open} always_on={@always_on} />
    </section>
    """
  end

  defp notes(detail), do: Enum.filter([detail["note"]], &is_binary/1)

  attr :items, :list, required: true

  defp readiness(%{items: []} = assigns), do: ~H""

  defp readiness(assigns) do
    ~H"""
    <ul id="always-on-readiness" class="mt-3 space-y-1 text-sm">
      <li :for={item <- @items} class="flex items-start gap-2">
        <.icon
          name={if item["status"] == "block", do: "hero-x-circle", else: "hero-exclamation-triangle"}
          class={["mt-0.5 size-4 shrink-0", item_class(item)]}
        />
        <span>{item["sentence"]}</span>
      </li>
    </ul>
    """
  end

  defp item_class(%{"status" => "block"}), do: "text-error"
  defp item_class(_item), do: "text-warning"

  attr :error, :string, default: nil

  defp error(%{error: nil} = assigns), do: ~H""

  defp error(assigns) do
    ~H"""
    <p id="always-on-error" role="alert" class="mt-3 text-sm text-error">{@error}</p>
    """
  end

  # -- actions -------------------------------------------------------------------

  attr :action, :map, required: true
  attr :acting, :string, default: nil

  # Learn more is a link; Update is the sentence alone, since this page
  # installs nothing.
  defp primary(%{action: %{"url" => url}} = assigns) when is_binary(url) do
    ~H"""
    <a
      id="always-on-action"
      href={@action["url"]}
      target="_blank"
      rel="noopener noreferrer"
      class="btn btn-primary btn-sm"
    >
      {@action["label"]}
    </a>
    """
  end

  defp primary(%{action: %{"id" => "update"}} = assigns), do: ~H""

  defp primary(assigns) do
    ~H"""
    <.press id="always-on-action" action={@action} acting={@acting} class={button_class(@action)} />
    """
  end

  attr :action, :map, required: true
  attr :acting, :string, default: nil
  attr :class, :any, required: true
  attr :id, :string, default: nil

  defp press(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      class={@class}
      phx-click="always_on_press"
      phx-value-id={@action["id"]}
      phx-value-key={@action["key"]}
      disabled={@acting != nil}
    >
      <span :if={@acting == @action["id"]} class="loading loading-spinner loading-xs" />
      {@action["label"]}
    </button>
    """
  end

  attr :action, :map, required: true
  attr :acting, :string, default: nil

  defp alternative(%{action: %{"url" => url}} = assigns) when is_binary(url) do
    ~H"""
    <a href={@action["url"]} target="_blank" rel="noopener noreferrer" class="link link-hover">
      {@action["label"]}
    </a>
    """
  end

  defp alternative(assigns) do
    ~H"""
    <.press action={@action} acting={@acting} class="link link-hover disabled:opacity-50" />
    """
  end

  defp button_class(%{"id" => id}) when id in @destructive, do: "btn btn-sm btn-error"
  defp button_class(_action), do: "btn btn-sm btn-primary"

  # -- the step an action opened -------------------------------------------------

  attr :always_on, :map, required: true

  defp step(assigns) do
    open = assigns.always_on.open

    passphrase? =
      Enum.any?(open["needs"], &(&1 in ~w(recovery_passphrase new_recovery_passphrase)))

    assigns =
      assign(assigns,
        open: open,
        passphrase?: passphrase?,
        again?: "new_recovery_passphrase" in open["needs"]
      )

    ~H"""
    <div
      id="always-on-step"
      class="fixed inset-0 z-50 grid place-items-center bg-base-300/70 p-4 backdrop-blur-sm"
      role="dialog"
      aria-modal="true"
      aria-labelledby="always-on-step-title"
    >
      <div class="w-full max-w-md rounded-box border border-base-300 bg-base-100 p-6 shadow-lg">
        <h3 id="always-on-step-title" class="text-lg font-semibold">{@open["label"]}</h3>
        <p :if={@open["confirm"]} class="mt-2 text-sm leading-6">{@open["confirm"]}</p>
        <form
          id={"always-on-step-form-#{@always_on.form_gen}"}
          phx-submit="always_on_submit"
          class="mt-4 space-y-3"
          autocomplete="off"
        >
          <.passphrase :if={@passphrase?} again?={@again?} />
          <.step_end always_on={@always_on} />
        </form>
      </div>
    </div>
    """
  end

  attr :again?, :boolean, required: true

  defp passphrase(assigns) do
    ~H"""
    <label class="block">
      <span class="text-sm font-medium">Recovery passphrase</span>
      <input
        type="password"
        name="always_on_step[passphrase]"
        value=""
        autocomplete="new-password"
        class="input input-sm input-bordered mt-1 w-full"
      />
    </label>
    <label :if={@again?} class="block">
      <span class="text-sm font-medium">Type it again</span>
      <input
        type="password"
        name="always_on_step[passphrase_again]"
        value=""
        autocomplete="new-password"
        class="input input-sm input-bordered mt-1 w-full"
      />
    </label>
    """
  end

  attr :always_on, :map, required: true

  # The error line, the action under its own label, and Back.
  defp step_end(assigns) do
    ~H"""
    <.error error={@always_on.error} />
    <div class="flex flex-wrap gap-2">
      <button
        type="submit"
        class={button_class(@always_on.open)}
        disabled={@always_on.acting != nil}
      >
        <span :if={@always_on.acting} class="loading loading-spinner loading-xs" />
        {@always_on.open["label"]}
      </button>
      <button
        type="button"
        class="btn btn-ghost btn-sm"
        phx-click="always_on_back"
        disabled={@always_on.acting != nil}
      >
        Back
      </button>
    </div>
    """
  end

  # -- Details and the code ------------------------------------------------------

  attr :detail, :map, required: true

  defp details(assigns) do
    assigns = assign(assigns, lines: assigns.detail["lines"] || [], card: @card)

    ~H"""
    <details
      :if={@lines != [] or @detail["data"]}
      id="always-on-details"
      class={@card}
      phx-mounted={JS.ignore_attributes("open")}
    >
      <summary class="cursor-pointer text-sm font-medium">Details</summary>
      <dl class="mt-3 grid grid-cols-[auto_minmax(0,1fr)] gap-x-4 gap-y-1 text-sm">
        <div :for={line <- @lines} class="contents">
          <dt class="text-base-content/60">{line["label"]}</dt>
          <dd class="min-w-0 break-words">{line["value"]}</dd>
        </div>
      </dl>
      <p :if={@detail["data"]} class="mt-3 text-sm text-base-content/70">{@detail["data"]}</p>
    </details>
    """
  end

  attr :webhooks, :map, required: true

  # The Funnel mounts to run on the server, each with its Copy, under the
  # engine's sentence and above its caveats.
  defp webhooks(assigns) do
    assigns =
      assign(assigns, mounts: Enum.with_index(assigns.webhooks["mounts"]), card: @card)

    ~H"""
    <section id="always-on-webhooks" class={@card}>
      <p class="text-sm">{@webhooks["sentence"]}</p>
      <div :for={{mount, i} <- @mounts} class="mt-3">
        <p class="text-sm font-medium">{mount["label"]}</p>
        <div class="mt-1 flex items-start gap-2">
          <pre
            id={"always-on-mount-#{i}"}
            class="min-w-0 flex-1 overflow-x-auto rounded-box bg-base-200 px-3 py-2 font-mono text-xs"
          >{mount["command"]}</pre>
          <button
            id={"always-on-copy-mount-#{i}"}
            type="button"
            class="btn btn-xs"
            phx-hook="CopyText"
            data-copy-from={"always-on-mount-#{i}"}
          >
            Copy
          </button>
        </div>
      </div>
      <p :for={note <- @webhooks["notes"]} class="mt-3 text-sm text-base-content/70">{note}</p>
    </section>
    """
  end

  attr :code, :map, required: true

  defp own_code(assigns) do
    assigns = assign(assigns, card: @card)

    ~H"""
    <section id="always-on-code" class={@card}>
      <p class="text-sm">On your Linux server, run:</p>
      <div class="mt-2 flex items-start gap-2">
        <pre
          id="always-on-code-command"
          class="min-w-0 flex-1 overflow-x-auto rounded-box bg-base-200 px-3 py-2 font-mono text-xs"
        >{@code.command}</pre>
        <button
          id="always-on-copy-command"
          type="button"
          class="btn btn-xs"
          phx-hook="CopyText"
          data-copy-from="always-on-code-command"
        >
          Copy
        </button>
      </div>
      <div id="always-on-tailscale" class="mt-3">
        <p class="text-sm">{@code.tailscale["sentence"]}</p>
        <div class="mt-2 flex items-start gap-2">
          <pre
            id="always-on-tailscale-command"
            class="min-w-0 flex-1 overflow-x-auto rounded-box bg-base-200 px-3 py-2 font-mono text-xs"
          >{@code.tailscale["command"]}</pre>
          <button
            id="always-on-copy-tailscale"
            type="button"
            class="btn btn-xs"
            phx-hook="CopyText"
            data-copy-from="always-on-tailscale-command"
          >
            Copy
          </button>
        </div>
      </div>
      <p class="mt-3 text-sm">When it asks for the code, paste this one:</p>
      <div class="mt-2 flex items-start gap-2">
        <code
          id="always-on-code-text"
          class="min-w-0 flex-1 break-all rounded-box bg-base-200 px-3 py-2 font-mono text-xs"
        >
          {@code.code}
        </code>
        <button
          id="always-on-copy-code"
          type="button"
          class="btn btn-xs"
          phx-hook="CopyText"
          data-copy-from="always-on-code-text"
        >
          Copy
        </button>
      </div>
      <p class="mt-3 text-sm text-base-content/70">It works once, until {@code.until}.</p>
      <button type="button" class="btn btn-ghost btn-sm mt-3" phx-click="always_on_done">
        Done
      </button>
    </section>
    """
  end
end
