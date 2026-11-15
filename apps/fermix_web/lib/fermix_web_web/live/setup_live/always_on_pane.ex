defmodule FermixWebWeb.SetupLive.AlwaysOnPane do
  @moduledoc """
  Draws the Always On tab from its state (`SetupLive.AlwaysOn`) in the
  groups the apps draw (the Always On pane, §3): the status card (the
  sentence, the one secondary sentence `detail.note`, the step in hand with
  the engine's count beside it while bytes move, the review's blocks, then
  the main action and the alternatives as one row of buttons, the error line,
  and the step the pressed action opened: a dialog with the confirm, one part
  per line, and what the action needs); then what to run now, the code of
  the owner's server (the engine's sentence, the command and the code each on
  one line with its Copy, and the optional Tailscale step folded under its
  label) or the Tailscale Funnel mounts the server needs (each folded under
  its label, with the tailnet's one step and the docs page under them); then
  Details (`detail.lines`, facts only, and where the backup settings show,
  whether the recovery passphrase is set with Change beside it); and Learn
  more, the summary's `help`, at the foot.

  Every word is the engine's (the summary's, with `Management.Copy`'s action
  labels) but a field's label and the page's own Back, Copy, Done, Details and
  Learn more.
  """

  use FermixWebWeb, :html

  @card "rounded-box border border-base-300 bg-base-100/80 p-5 shadow-sm"
  @mono "min-w-0 flex-1 overflow-x-auto whitespace-nowrap rounded-box bg-base-200 px-3 py-2 " <>
          "font-mono text-xs"
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
      <.own_code :if={@always_on.code && @always_on.code.command} code={@always_on.code} />
      <.computer_code
        :if={@always_on.code && !@always_on.code.command}
        code={@always_on.code}
      />
      <.webhooks
        :if={@always_on.summary && @always_on.summary["detail"]["webhooks"]}
        webhooks={@always_on.summary["detail"]["webhooks"]}
      />
      <.details
        :if={@always_on.summary}
        detail={@always_on.summary["detail"] || %{}}
        acting={@always_on.acting}
      />
      <.help :if={@always_on.summary} url={@always_on.summary["help"]} />
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

  # -- the status card -----------------------------------------------------------

  attr :always_on, :map, required: true

  defp card(assigns) do
    summary = assigns.always_on.summary
    detail = summary["detail"] || %{}

    assigns =
      assign(assigns,
        summary: summary,
        detail: detail,
        acting: assigns.always_on.acting,
        buttons: List.wrap(summary["action"]) ++ (detail["alternatives"] || []),
        card: @card
      )

    ~H"""
    <section id="always-on-status" class={@card}>
      <p id="always-on-sentence" class="text-sm font-medium leading-6">{@summary["sentence"]}</p>
      <p :if={@detail["note"]} id="always-on-note" class="mt-1 text-sm text-base-content/70">
        {@detail["note"]}
      </p>
      <p
        :if={@detail["progress"]}
        id="always-on-progress"
        class="mt-2 flex items-center gap-2 text-sm text-base-content/70"
      >
        <span class="loading loading-spinner loading-xs" />
        <span>{@detail["progress"]}</span>
        <span :if={@detail["transfer"]} id="always-on-transfer">
          {@detail["transfer"]["label"]}
        </span>
      </p>
      <.readiness items={@detail["readiness"] || []} />
      <div :if={@buttons != []} id="always-on-buttons" class="mt-4 flex flex-wrap items-center gap-2">
        <.primary :if={@summary["action"]} action={@summary["action"]} acting={@acting} />
        <.alternative
          :for={action <- @detail["alternatives"] || []}
          action={action}
          acting={@acting}
        />
      </div>
      <.error :if={!@always_on.open} error={@always_on.error} />
      <.step :if={@always_on.open} always_on={@always_on} />
    </section>
    """
  end

  attr :items, :list, required: true

  defp readiness(%{items: []} = assigns), do: ~H""

  # The blocks of the review, in the warning colour (R5: never hidden).
  defp readiness(assigns) do
    ~H"""
    <ul id="always-on-readiness" class="mt-3 space-y-1 text-sm">
      <li :for={item <- @items} class="flex items-start gap-2">
        <.icon name="hero-x-circle" class="mt-0.5 size-4 shrink-0 text-error" />
        <span>{item["sentence"]}</span>
      </li>
    </ul>
    """
  end

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

  # Update is the sentence alone, since this page installs nothing.
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

  # Every alternative is drawn the same way, after the main action (R3);
  # Update, which this page cannot take, is its label alone.
  defp alternative(%{action: %{"id" => "update"}} = assigns) do
    ~H"""
    <span class="text-sm text-base-content/70">{@action["label"]}</span>
    """
  end

  defp alternative(assigns) do
    ~H"""
    <.press action={@action} acting={@acting} class="btn btn-sm btn-outline" />
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
        again?: "new_recovery_passphrase" in open["needs"],
        digits?: "sas" in open["needs"]
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
        <%!-- One part per line: the confirm's line breaks are drawn as they are. --%>
        <p
          :if={@open["confirm"]}
          id="always-on-step-confirm"
          class="mt-2 whitespace-pre-line text-sm leading-6"
          phx-no-format
        >{@open["confirm"]}</p>
        <form
          id={"always-on-step-form-#{@always_on.form_gen}"}
          phx-submit="always_on_submit"
          class="mt-4 space-y-3"
          autocomplete="off"
        >
          <.passphrase :if={@passphrase?} again?={@again?} />
          <.digits :if={@digits?} />
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

  # The six digits the computer that asks to join shows (M97 §7.5): no
  # secret, so they are typed in the open.
  defp digits(assigns) do
    ~H"""
    <label class="block">
      <span class="text-sm font-medium">The six digits the new computer shows</span>
      <input
        id="always-on-step-digits"
        type="text"
        name="always_on_step[sas]"
        value=""
        inputmode="numeric"
        autocomplete="off"
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

  # -- Details and help ----------------------------------------------------------

  attr :detail, :map, required: true
  attr :acting, :string, default: nil

  # Facts only (R8), and where the backup settings show, whether the
  # recovery passphrase is set, with Change.
  defp details(assigns) do
    assigns =
      assign(assigns,
        lines: assigns.detail["lines"] || [],
        backup: assigns.detail["backup"],
        card: @card
      )

    ~H"""
    <details
      :if={@lines != [] or @backup}
      id="always-on-details"
      class={@card}
      phx-mounted={JS.ignore_attributes("open")}
    >
      <summary class="cursor-pointer text-sm font-medium">Details</summary>
      <dl
        :if={@lines != []}
        class="mt-3 grid grid-cols-[auto_minmax(0,1fr)] gap-x-4 gap-y-1 text-sm"
      >
        <div :for={line <- @lines} class="contents">
          <dt class="text-base-content/60">{line["label"]}</dt>
          <dd class="min-w-0 break-words">{line["value"]}</dd>
        </div>
      </dl>
      <.backup :if={@backup} backup={@backup} acting={@acting} />
    </details>
    """
  end

  attr :backup, :map, required: true
  attr :acting, :string, default: nil

  defp backup(assigns) do
    ~H"""
    <div id="always-on-backup" class="mt-3 border-t border-base-300 pt-3">
      <div class="flex flex-wrap items-center gap-3 text-sm">
        <p id="always-on-backup-line">
          <span class="text-base-content/60">{@backup["passphrase"]["label"]}</span>
          <span>{@backup["passphrase"]["value"]}</span>
        </p>
        <.press action={@backup["change"]} acting={@acting} class="btn btn-xs btn-outline" />
      </div>
      <p class="mt-1 text-xs text-base-content/60">{@backup["passphrase"]["footer"]}</p>
      <p :if={@backup["s3"]} class="mt-1 text-xs text-base-content/60">{@backup["s3"]}</p>
    </div>
    """
  end

  attr :url, :string, default: nil

  # One help link per screen, to the docs page at the screen's anchor (R7).
  defp help(%{url: nil} = assigns), do: ~H""

  defp help(assigns) do
    ~H"""
    <p>
      <a
        id="always-on-help"
        href={@url}
        target="_blank"
        rel="noopener noreferrer"
        class="link link-hover text-sm"
      >
        Learn more
      </a>
    </p>
    """
  end

  # -- what to run now: the webhooks, the codes ----------------------------------

  attr :webhooks, :map, required: true

  # The Funnel mounts to run on the server, each folded under its label with
  # its command, its Copy and where the sender is pointed, under the engine's
  # sentence, then the tailnet's one step and the page that holds the rest.
  defp webhooks(assigns) do
    assigns =
      assign(assigns,
        mounts: Enum.with_index(assigns.webhooks["mounts"]),
        mono: @mono,
        card: @card
      )

    ~H"""
    <section id="always-on-webhooks" class={@card}>
      <p class="text-sm">{@webhooks["sentence"]}</p>
      <details :for={{mount, i} <- @mounts} class="mt-3">
        <summary class="cursor-pointer text-sm font-medium">{mount["label"]}</summary>
        <div class="mt-2 flex items-start gap-2">
          <pre id={"always-on-mount-#{i}"} class={@mono}>{mount["command"]}</pre>
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
        <p id={"always-on-mount-note-#{i}"} class="mt-1 text-sm text-base-content/70">
          {mount["note"]}
        </p>
      </details>
      <p
        :for={note <- @webhooks["notes"]}
        id="always-on-webhooks-note"
        class="mt-3 text-sm text-base-content/70"
      >
        {note}
      </p>
      <a
        id="always-on-webhooks-help"
        href={@webhooks["url"]}
        target="_blank"
        rel="noopener noreferrer"
        class="link link-hover mt-1 inline-block text-sm"
      >
        Learn more
      </a>
    </section>
    """
  end

  attr :code, :map, required: true

  # Add a computer's code (M97 §3.1): shown once, for the new computer.
  defp computer_code(assigns) do
    assigns = assign(assigns, card: @card, mono: @mono)

    ~H"""
    <section id="always-on-code" class={@card}>
      <p class="text-sm">
        On the new computer, connect to a Fermix that already runs and paste this code:
      </p>
      <div class="mt-2 flex items-start gap-2">
        <code id="always-on-code-text" class={@mono}>{@code.code}</code>
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

  attr :code, :map, required: true

  # The owner's server's code (the Always On pane's §3.2, D10): the engine's
  # sentence, the command and the code each on one line with its Copy, and
  # the optional Tailscale step folded under its label.
  defp own_code(assigns) do
    assigns = assign(assigns, card: @card, mono: @mono)

    ~H"""
    <section id="always-on-code" class={@card}>
      <p id="always-on-code-sentence" class="text-sm">{@code.sentence}</p>
      <div class="mt-2 flex items-start gap-2">
        <pre id="always-on-code-command" class={@mono}>{@code.command}</pre>
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
      <div class="mt-2 flex items-start gap-2">
        <code id="always-on-code-text" class={@mono}>{@code.code}</code>
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
      <details id="always-on-tailscale" class="mt-3">
        <summary class="cursor-pointer text-sm font-medium">{@code.tailscale["label"]}</summary>
        <p class="mt-2 text-sm">{@code.tailscale["sentence"]}</p>
        <div class="mt-2 flex items-start gap-2">
          <pre id="always-on-tailscale-command" class={@mono}>{@code.tailscale["command"]}</pre>
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
        <a
          href={@code.tailscale["url"]}
          target="_blank"
          rel="noopener noreferrer"
          class="link link-hover mt-1 inline-block text-sm"
        >
          Learn more
        </a>
      </details>
      <button type="button" class="btn btn-ghost btn-sm mt-3" phx-click="always_on_done">
        Done
      </button>
    </section>
    """
  end
end
