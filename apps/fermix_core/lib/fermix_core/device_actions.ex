defmodule FermixCore.DeviceActions do
  @moduledoc """
  The owner's desktops that run actions for the primary's agent (M75 §11, B11).

  A desktop is an engine in the device role that keeps a session to the
  primary (`devices.toml` row kind `desktop`). The primary's `device_action`
  tool asks one of them to do one bounded thing and waits for its correlated
  result; the desktop decides for itself whether it may.

  `fermix_core` must not compile-depend on `fermix_channels`, where the
  sessions, the in-flight invocations and the attachment pipeline live, so the
  implementation is injected by module through `config :fermix_core,
  :device_actions`: the pattern `:jobs` `delivery_channels` and
  `:harness_continuation_dispatcher` use. `nil` is no implementation, which is
  no desktop at all.

  An implementation answers two questions:

    * `desktops/0`: every desktop row this primary holds, each with its name,
      whether the primary lets it run actions (`executor`) and whether its
      session is up now (`connected`). Nothing is queued for a desktop that is
      not connected (B11).
    * `invoke/4`: run one action on one connected desktop and wait for how it
      ended. A result the connection lost is reconciled from the desktop's
      receipt; one the desktop holds no receipt for is `:uncertain`, and is
      never sent again.
  """

  @typedoc "A desktop row, as `desktops/0` lists it."
  @type desktop :: %{
          device_id: String.t(),
          name: String.t(),
          executor: boolean(),
          connected: boolean()
        }

  @typedoc "How the desktop said an action ended."
  @type status :: :ok | :refused | :failed

  @typedoc """
  How one invocation ended:

    * `:result`: the desktop's own answer, its result JSON decoded (`result`),
      and for a `read_file` the file as the attachment pipeline rendered it
      (`attachment`, `nil` for every other action);
    * `:reconciled`: its result was lost with the connection, and the
      desktop's receipt says how it ended and when (`finished_at`, RFC 3339);
    * `:uncertain`: no result arrived and the desktop holds no receipt for it,
      so whether it ran is unknown (`reason`: `:no_receipt` when the desktop
      answered without one, `:disconnected` when it was not connected to ask).
  """
  @type outcome ::
          %{
            required(:kind) => :result,
            required(:status) => status(),
            required(:result) => map(),
            required(:attachment) => FermixCore.Attachments.t() | nil
          }
          | %{kind: :reconciled, status: status(), finished_at: String.t()}
          | %{kind: :uncertain, reason: :no_receipt | :disconnected}

  @typedoc """
  Why nothing was sent: the desktop is not connected, or already has as many
  actions in flight as it may (`{:busy, max}`). `{:attachment, reason}` is a
  `read_file` whose bytes arrived but could not be rendered for the model.
  """
  @type error :: :not_connected | {:busy, pos_integer()} | {:attachment, term()}

  @typedoc """
  `deadline_s` (1 to 600) bounds how long the desktop may take to start it and
  the primary waits; `correlation_id` is the asking turn's session id, carried
  to the desktop and back.
  """
  @type invoke_opt :: {:deadline_s, 1..600} | {:correlation_id, String.t()}

  @doc "Every desktop row this primary holds; `[]` when none or the phone channel is off."
  @callback desktops() :: [desktop()]

  @doc "Runs `action` with `args` on the connected desktop `device_id` and waits for how it ended."
  @callback invoke(device_id :: String.t(), action :: String.t(), args :: map(), [invoke_opt()]) ::
              {:ok, outcome()} | {:error, error()}

  @doc "The configured implementation, or `nil` when none is."
  @spec impl() :: module() | nil
  def impl, do: Application.get_env(:fermix_core, :device_actions)
end
