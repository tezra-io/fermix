defmodule FermixCore.Browser do
  @moduledoc false

  alias FermixCore.Browser.ChromeLauncher
  alias FermixCore.Browser.Config
  alias FermixCore.Browser.Error
  alias FermixCore.Browser.ProfileManager
  alias FermixCore.Browser.Scope
  alias FermixCore.Temporal.Access

  @actions ~w(doctor status start stop open navigate snapshot tabs focus close screenshot act pdf
              console dialog cookies storage upload download webmcp)
  @profile_actions @actions -- ["doctor", "status"]
  # The `act` kinds — page interactions, reachable only as `act`'s `kind`. Listed
  # here so an unknown action that IS one can say so (see `action/1`); the kinds
  # themselves are validated in `validate_act_args/2`.
  @act_kinds ~w(click fill type submit press hover get wait click_coords fill_form)
  # Requests that CHANGE something — the page, the browser, or a server on the
  # far side of it. `ProfileManager` re-sends a request whose server died, which
  # for these is a second click, a second upload, a second tool call; the list
  # lives here, beside `@actions`, because this is where the action vocabulary
  # is. `cookies`, `storage` and `webmcp` each read by default and write in one
  # form, so they are decided from their arguments in `mutating?/2`.
  @mutating_actions ~w(open navigate act close upload download dialog focus)
  @mutating_act_kinds @act_kinds -- ["get", "wait"]

  @spec actions() :: [String.t()]
  def actions, do: @actions

  @doc """
  Whether running `action` with `args` changes something a re-send would repeat.

  Stamped onto every dispatched request so `ProfileManager` can tell a retry it
  may take (the profile was reaped before the request was delivered) from one it
  may not (the server died with a mutation in flight). A page's own annotations
  never reach this decision — the page is the untrusted party.
  """
  @spec mutating?(String.t(), map()) :: boolean()
  def mutating?(action, args) when is_binary(action) and is_map(args) do
    case action do
      "act" -> Map.get(args, "kind") in @mutating_act_kinds
      "cookies" -> Map.get(args, "kind") == "clear"
      "storage" -> not is_nil(Map.get(args, "value"))
      "webmcp" -> Map.get(args, "op") == "call"
      _other -> action in @mutating_actions
    end
  end

  @doc """
  Tear down the managed browser for a finished conversation (its owner scope),
  so a one-shot turn does not leave a Chrome window alive until the idle TTL.

  The gateway calls this at turn end for one-shot (loopback) channels; remote
  interactive channels keep their browser warm for the next message. A no-op
  when the conversation never started a browser.
  """
  @spec reap_conversation(FermixCore.Agents.ConversationKey.t(), keyword()) :: :ok
  def reap_conversation(conversation_key, opts \\ []) do
    case Scope.owner_key(%{conversation_key: conversation_key}) do
      {:ok, owner} -> ProfileManager.stop_owner(owner, opts)
      {:error, _error} -> :ok
    end
  end

  @spec execute(map(), map()) :: {:ok, String.t()} | {:error, Error.t()}
  def execute(args, context) when is_map(args) and is_map(context) do
    with {:ok, action} <- action(args),
         {:ok, config} <- Config.current(),
         {:ok, owner_key} <- Scope.owner_key(context),
         {:ok, profile, profile_name} <- Config.profile(config, Map.get(args, "profile")),
         :ok <- allowed_turn(profile, context),
         :ok <- validate_args(action, args) do
      dispatch(action, args, context, owner_key, profile_name, profile, config)
    end
  end

  # A granted tab is the person's own browser, signed in as them, so it is used
  # only on a turn they are present for. `Temporal.Access` already answers
  # "attended, top-level, the owner's" for every other surface with that rule;
  # the sentence is this feature's because the next move is.
  defp allowed_turn(%{mode: :attached_tab}, context) do
    if Access.attended_operator_turn?(context) do
      :ok
    else
      {:error,
       Error.new(
         "attached_tab_not_allowed",
         "Your own browser tab is used only on a turn you are present for. Guest, " <>
           "scheduled, background, delegated and coding-continuation runs use the managed " <>
           "browser profile instead."
       )}
    end
  end

  defp allowed_turn(_profile, _context), do: :ok

  defp dispatch("doctor", _args, _context, _owner, _profile_name, _profile, config) do
    {:ok, encode(%{"ok" => true, "chrome" => chrome_diagnostics(config)})}
  end

  defp dispatch("status", _args, _context, owner, profile_name, _profile, _config) do
    {:ok, encode(ProfileManager.status(owner, profile_name))}
  end

  defp dispatch(action, args, context, owner, profile_name, profile, config)
       when action in @profile_actions do
    request = %{
      action: action,
      args: args,
      context: context,
      mutating: mutating?(action, args)
    }

    case ProfileManager.dispatch(owner, profile_name, profile, config, request) do
      {:ok, result} -> {:ok, encode(result)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp action(%{"action" => action}) when action in @actions, do: {:ok, action}

  # Name the call that works, not just the mistake. `wait`/`click`/`fill` are `act`
  # KINDS, and reaching for one as an action is the single most common miss
  # (observed live three times: `action: "wait"` after a click, each time a dead
  # end because the error stopped at "invalid"). Same family as dialog_blocked /
  # stale_ref / no_rendered_box.
  defp action(%{"action" => action}) when action in @act_kinds do
    {:error,
     Error.new(
       "invalid_action",
       "`#{action}` is an `act` kind, not an action. Call it as " <>
         ~s(`"action": "act", "kind": "#{action}"`) <>
         " with that kind's arguments."
     )}
  end

  defp action(%{"action" => action}) when is_binary(action) do
    {:error,
     Error.new(
       "invalid_action",
       "Invalid action: #{action}. Valid actions: #{Enum.join(@actions, ", ")}. " <>
         "Page interactions (click, fill, fill_form, type, submit, press, hover, wait, get, " <>
         "click_coords) go through `act` as its `kind`."
     )}
  end

  defp action(_args),
    do: {:error, Error.new("missing_action", "Missing required parameter: action")}

  defp validate_args(action, args) when action in ["open", "navigate"] do
    require_string(args, "url", action)
  end

  defp validate_args("act", %{"kind" => kind} = args) when is_binary(kind) do
    validate_act_args(kind, args)
  end

  defp validate_args("act", _args), do: {:error, Error.new("missing_arg", "act requires kind")}

  defp validate_args("upload", args) do
    with :ok <- require_string(args, "ref", "upload") do
      require_string(args, "path", "upload")
    end
  end

  defp validate_args("webmcp", args), do: validate_webmcp_args(args)

  defp validate_args(_action, _args), do: :ok

  # The two ops and what each one reads, in the shape `@wait_modes` uses below:
  # an argument-starved call is told which op it meant and what that op needs,
  # rather than stopping at "invalid".
  @webmcp_ops %{
    "list" => "no extra argument",
    "call" => "`name` (the tool to run) and optionally `input` (a JSON object of its arguments)"
  }

  defp validate_webmcp_args(%{"op" => "list"}), do: :ok

  defp validate_webmcp_args(%{"op" => "call"} = args) do
    with :ok <- require_string(args, "name", "webmcp op=call"),
         :ok <- validate_webmcp_name(Map.fetch!(args, "name")) do
      validate_webmcp_input(Map.get(args, "input"))
    end
  end

  defp validate_webmcp_args(_args) do
    {:error,
     Error.new(
       "missing_arg",
       "webmcp requires `op` — one of " <>
         Enum.map_join(@webmcp_ops, "; ", fn {op, arg} -> "#{op} with #{arg}" end) <> "."
     )}
  end

  defp validate_webmcp_name(name) do
    max = Config.webmcp_limits().name_chars

    if String.length(name) <= max,
      do: :ok,
      else: {:error, Error.new("invalid_arg", "webmcp `name` is at most #{max} characters")}
  end

  # `input` is the one model-supplied value that reaches the page. It is bounded
  # here, before any browser work, so an oversize argument costs nothing.
  defp validate_webmcp_input(nil), do: :ok

  defp validate_webmcp_input(input) when is_map(input) do
    max = Config.webmcp_limits().input_bytes

    if byte_size(Jason.encode!(input)) <= max do
      :ok
    else
      {:error,
       Error.new(
         "invalid_arg",
         "webmcp `input` must encode to at most #{max} bytes; send the tool a smaller argument"
       )}
    end
  end

  defp validate_webmcp_input(_input) do
    {:error,
     Error.new("invalid_arg", "webmcp `input` must be an object of the tool's named arguments")}
  end

  # Wait modes and the argument each one reads. There is deliberately NO
  # plain-pause mode: "load" matches instantly on an already-complete page, so
  # offering it as a pause would teach a no-op.
  @wait_modes %{
    "text" => "`text` (the substring to wait for in the page text)",
    "url" => "`text` (the substring to wait for in the url)",
    "element" => "`ref` or `selector` (the element to wait for)",
    "load" => "no extra argument"
  }

  defp validate_act_args(kind, args) when kind in ["click", "hover", "submit"] do
    require_string(args, "ref", kind)
  end

  defp validate_act_args(kind, args) when kind in ["fill", "type"] do
    with :ok <- require_string(args, "ref", kind) do
      require_string(args, "text", kind)
    end
  end

  # One snapshot, several fields, one call. The shape is checked here so a
  # malformed list costs nothing; the refs themselves are checked against the
  # tab's live ref map in the server, before the first keystroke.
  defp validate_act_args("fill_form", %{"fields" => fields}) when is_list(fields) do
    validate_form_fields(fields)
  end

  defp validate_act_args("fill_form", _args),
    do: {:error, Error.new("missing_arg", fill_form_shape())}

  defp validate_act_args("click_coords", args) do
    if is_number(args["x"]) and is_number(args["y"]),
      do: :ok,
      else: {:error, Error.new("missing_arg", "click_coords requires x and y")}
  end

  defp validate_act_args("press", args), do: require_string(args, "key", "press")

  # Validated HERE so a starved wait gets a teaching error instead of dying deep
  # in the runtime as the misleading "Unsupported wait_until value" (the exact
  # path three live sessions hit right after being funneled to `act wait`).
  defp validate_act_args("wait", %{"wait_until" => mode} = args)
       when is_map_key(@wait_modes, mode) do
    case mode do
      "text" -> require_string(args, "text", "wait_until=text")
      "url" -> require_string(args, "text", "wait_until=url")
      "element" -> require_element_target(args)
      "load" -> :ok
    end
  end

  defp validate_act_args("wait", _args) do
    {:error,
     Error.new(
       "missing_arg",
       "wait requires `wait_until` — one of " <>
         Enum.map_join(@wait_modes, "; ", fn {mode, arg} -> "#{mode} with #{arg}" end) <>
         ". There is no plain-pause mode: to pause, wait FOR the thing you expect to change."
     )}
  end

  # `rect` reads the geometry of a selector match; without the selector there is
  # nothing to measure.
  defp validate_act_args("get", %{"field" => "rect"} = args),
    do: require_string(args, "selector", "get field=rect")

  defp validate_act_args("get", _args), do: :ok

  defp validate_act_args(kind, _args),
    do: {:error, Error.new("invalid_action", "Invalid act kind: #{kind}")}

  defp validate_form_fields([]), do: {:error, Error.new("missing_arg", fill_form_shape())}

  defp validate_form_fields(fields) do
    max = Config.act_limits().form_fields

    if length(fields) > max do
      {:error,
       Error.new(
         "invalid_arg",
         "fill_form takes at most #{max} fields, and this call sent #{length(fields)}. " <>
           "Fill the rest in a second call."
       )}
    else
      fields |> Enum.with_index(1) |> Enum.reduce_while(:ok, &validate_form_field/2)
    end
  end

  defp validate_form_field({%{"ref" => ref, "text" => text}, _position}, :ok)
       when is_binary(ref) and ref != "" and is_binary(text),
       do: {:cont, :ok}

  defp validate_form_field({_field, position}, :ok) do
    {:halt,
     {:error,
      Error.new(
        "invalid_arg",
        "fill_form field #{position} must be an object with `ref` (an element ref from the " <>
          "latest snapshot) and `text` (the string to put in it, possibly empty)."
      )}}
  end

  defp fill_form_shape do
    "fill_form requires `fields`: a non-empty list of objects with `ref` and `text`, at most " <>
      "#{Config.act_limits().form_fields} of them. They are the fields of ONE form, taken from " <>
      "ONE snapshot, filled in order."
  end

  defp require_element_target(args) do
    if is_binary(args["ref"]) or is_binary(args["selector"]),
      do: :ok,
      else: {:error, Error.new("missing_arg", "wait_until=element requires `ref` or `selector`")}
  end

  defp require_string(args, key, action) do
    case Map.get(args, key) do
      value when is_binary(value) and value != "" -> :ok
      _other -> {:error, Error.new("missing_arg", "#{action} requires #{key}")}
    end
  end

  defp chrome_diagnostics(config) do
    case ChromeLauncher.find_executable(config, nil) do
      {:ok, path} -> %{"ok" => true, "path" => path}
      {:error, %Error{} = error} -> %{"ok" => false, "error" => Error.to_map(error)}
    end
  end

  defp encode(result), do: Jason.encode!(result)
end
