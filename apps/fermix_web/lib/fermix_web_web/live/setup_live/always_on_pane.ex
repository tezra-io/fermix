defmodule FermixWebWeb.SetupLive.AlwaysOnPane do
  @moduledoc """
  Draws the Always On tab from its state (`SetupLive.AlwaysOn`): the summary
  card (the sentence, the step in hand, the one action, the error line and
  the alternatives), the step the pressed action opened (the token screen of
  each provider with the token field, the choice of size and place, or a
  dialog with the confirm sentence and the recovery passphrase), Details from
  `detail.lines`, and the code of a server of the owner's own.

  Every word is the engine's (the summary's, `home.provision.options`' with
  each offer's `label` and `price`, and `Management.Copy`'s action labels)
  but a field's label and the page's own Back, Change, Copy, Done and
  Details.
  """

  use FermixWebWeb, :html

  alias FermixCore.Management.Copy
  alias FermixWebWeb.SetupLive.AlwaysOn

  @card "rounded-box border border-base-300 bg-base-100/80 p-5 shadow-sm"
  # The steps that delete or stop something, drawn as such.
  @destructive ~w(cancel delete_server start_again)

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

  defp notes(detail), do: Enum.filter([detail["note"], detail["billing"]], &is_binary/1)

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

  # Learn more and Open the console are links; Update is the sentence alone,
  # since this page installs nothing.
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

  defp step(%{always_on: %{open: %{"needs" => ["token"]}}} = assigns), do: token_step(assigns)
  defp step(%{always_on: %{open: %{"needs" => ["choice"]}}} = assigns), do: choice_step(assigns)
  defp step(assigns), do: dialog_step(assigns)

  defp token_step(assigns) do
    providers = AlwaysOn.providers(assigns.always_on)
    assigns = assign(assigns, providers: providers, open: assigns.always_on.open)

    ~H"""
    <div id="always-on-step" class="mt-4 space-y-4 border-t border-base-300 pt-4">
      <form
        id={"always-on-step-form-#{@always_on.form_gen}"}
        phx-submit="always_on_submit"
        class="space-y-4"
        autocomplete="off"
      >
        <.provider_screen
          :for={{provider, index} <- Enum.with_index(@providers)}
          provider={provider}
          pick?={length(@providers) > 1}
          checked?={index == 0}
        />
        <label class="block max-w-md">
          <span class="text-sm font-medium">
            {Enum.map_join(@providers, " / ", & &1["token_label"])}
          </span>
          <input
            type="password"
            name="always_on_step[token]"
            value=""
            autocomplete="off"
            spellcheck="false"
            class="input input-sm input-bordered mt-1 w-full font-mono"
          />
        </label>
        <.step_end always_on={@always_on} />
      </form>
    </div>
    """
  end

  attr :provider, :map, required: true
  attr :pick?, :boolean, required: true
  attr :checked?, :boolean, required: true

  defp provider_screen(assigns) do
    ~H"""
    <fieldset class="rounded-box border border-base-300 p-4">
      <label :if={@pick?} class="mb-2 flex items-center gap-2">
        <input
          type="radio"
          name="always_on_step[provider]"
          value={@provider["id"]}
          checked={@checked?}
          class="radio radio-sm"
        />
        <span class="text-sm font-medium">{@provider["name"]}</span>
      </label>
      <p class="text-sm">{@provider["sentence"]}</p>
      <ol class="mt-2 list-decimal space-y-1 pl-5 text-sm marker:text-primary">
        <li :for={said <- @provider["steps"] || []}>{said}</li>
      </ol>
      <div class="mt-3 flex flex-wrap gap-x-4 gap-y-1 text-sm">
        <a href={@provider["console_url"]} target="_blank" rel="noopener noreferrer" class="link">
          {Copy.summary_label(:open_console, %{provider: @provider["name"]})}
        </a>
        <a href={@provider["docs_url"]} target="_blank" rel="noopener noreferrer" class="link">
          {Copy.summary_label(:learn_more, %{})}
        </a>
      </div>
    </fieldset>
    """
  end

  defp choice_step(assigns) do
    assigns = assign(assigns, options: assigns.always_on.options, open: assigns.always_on.open)

    ~H"""
    <div id="always-on-step" class="mt-4 space-y-3 border-t border-base-300 pt-4">
      <p :if={@options == :reading} class="text-sm text-base-content/60">
        <span class="loading loading-spinner loading-sm" />
      </p>
      <form
        :if={is_map(@options)}
        id={"always-on-step-form-#{@always_on.form_gen}"}
        phx-submit="always_on_submit"
        class="space-y-3"
      >
        <p class="text-sm font-medium">{@options["sentence"]}</p>
        <p :if={@open["confirm"]} class="text-sm text-base-content/70">{@open["confirm"]}</p>
        <details
          id="always-on-offers"
          class="rounded-box border border-base-300"
          phx-mounted={JS.ignore_attributes("open")}
        >
          <summary class="cursor-pointer px-3 py-2 text-sm">Change</summary>
          <div class="space-y-3 px-3 pb-3">
            <fieldset
              :for={{location, city, offers} <- by_city(@options)}
              data-location={location}
              class="space-y-1"
            >
              <legend class="text-xs font-semibold text-base-content/60">{city}</legend>
              <.offer :for={offer <- offers} offer={offer} options={@options} />
            </fieldset>
          </div>
        </details>
        <.step_end always_on={@always_on} />
      </form>
      <div :if={!is_map(@options)}>
        <.error error={@always_on.error} />
        <button type="button" class="btn btn-ghost btn-sm mt-2" phx-click="always_on_back">
          Back
        </button>
      </div>
    </div>
    """
  end

  attr :offer, :map, required: true
  attr :options, :map, required: true

  defp offer(assigns) do
    ~H"""
    <label class="flex items-start gap-2 text-sm">
      <input
        type="radio"
        name="always_on_step[choice]"
        value={@offer["location"] <> "/" <> @offer["type"]}
        checked={recommended?(@offer, @options)}
        class="radio radio-sm mt-0.5"
      />
      <span class="min-w-0">
        <span class="block font-medium" data-offer="label">{@offer["label"]}</span>
        <span class="block text-xs text-base-content/70" data-offer="price">{@offer["price"]}</span>
      </span>
    </label>
    """
  end

  # The offers in each place, in the order the provider recommends its places.
  defp by_city(%{"locations" => locations, "offers" => offers}) do
    for %{"id" => id, "city" => city} <- locations,
        here = Enum.filter(offers, &(&1["location"] == id)),
        here != [],
        do: {id, city, here}
  end

  defp recommended?(%{"type" => type, "location" => location}, %{"recommended" => recommended}),
    do: recommended == %{"type" => type, "location" => location}

  defp dialog_step(assigns) do
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
