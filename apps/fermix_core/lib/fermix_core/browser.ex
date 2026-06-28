defmodule FermixCore.Browser do
  @moduledoc false

  alias FermixCore.Browser.ChromeLauncher
  alias FermixCore.Browser.Config
  alias FermixCore.Browser.Error
  alias FermixCore.Browser.ProfileManager
  alias FermixCore.Browser.Scope

  @actions ~w(doctor status start stop open navigate snapshot tabs focus close screenshot act pdf
              console dialog cookies storage upload download)
  @profile_actions @actions -- ["doctor", "status"]

  @spec actions() :: [String.t()]
  def actions, do: @actions

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
         :ok <- validate_args(action, args) do
      dispatch(action, args, context, owner_key, profile_name, profile, config)
    end
  end

  defp dispatch("doctor", _args, _context, _owner, _profile_name, _profile, config) do
    {:ok, encode(%{"ok" => true, "chrome" => chrome_diagnostics(config)})}
  end

  defp dispatch("status", _args, _context, owner, profile_name, _profile, _config) do
    {:ok, encode(ProfileManager.status(owner, profile_name))}
  end

  defp dispatch(action, args, context, owner, profile_name, profile, config)
       when action in @profile_actions do
    request = %{action: action, args: args, context: context}

    case ProfileManager.dispatch(owner, profile_name, profile, config, request) do
      {:ok, result} -> {:ok, encode(result)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp action(%{"action" => action}) when action in @actions, do: {:ok, action}

  defp action(%{"action" => action}) when is_binary(action) do
    {:error, Error.new("invalid_action", "Invalid action: #{action}")}
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

  defp validate_args(_action, _args), do: :ok

  defp validate_act_args(kind, args) when kind in ["click", "hover", "submit"] do
    require_string(args, "ref", kind)
  end

  defp validate_act_args(kind, args) when kind in ["fill", "type"] do
    with :ok <- require_string(args, "ref", kind) do
      require_string(args, "text", kind)
    end
  end

  defp validate_act_args("click_coords", args) do
    if is_number(args["x"]) and is_number(args["y"]),
      do: :ok,
      else: {:error, Error.new("missing_arg", "click_coords requires x and y")}
  end

  defp validate_act_args(kind, _args)
       when kind in ["press", "wait", "get"],
       do: :ok

  defp validate_act_args(kind, _args),
    do: {:error, Error.new("invalid_action", "Invalid act kind: #{kind}")}

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
