defmodule FermixChannels.Mobile.Push do
  @moduledoc """
  Tells the owner's phones of a row they have not read, or an approval that
  waits for them, phone by phone (M99 §6).

  **Who is pushed.** Each registered phone (one with a `push_token`) that
  `DeviceRegistry` does not list as connected for the profile at that moment:
  a connected phone has the row already, and the phones beside it are still
  pushed. A row the profile has read (its read frontier covers the row) is
  pushed to nobody. Presence and read state are settled before any credential
  is loaded or any push service reached.

  **Which way.** One route per phone, by what it registered; never both, and
  never a second try through the other:
  - a phone holding a Web Push subscription (`push_service` set) goes through
    `WebPush`, in `Push.WebPushLeg`: a row's push lives a day at the push
    service, an approval's as long as the approval waits;
  - a phone holding only a token, whose platform is `ios` or `nil` (a phone
    paired before pairing recorded a platform was an iPhone), goes through
    APNs, its preview encrypted for that phone alone;
  - any other phone, an Android phone holding an older app's token, is
    refused by name with a typed reason in the log: it holds no Web Push
    subscription.

  **The APNs config is the APNs route's alone.** APNs off: iPhones are not
  sent, and Web Push phones still are; `:disabled` means APNs is off and no
  away phone holds a subscription. A config that does not resolve fails each
  away iPhone with the config's reason, said once in the log, and Web Push
  phones are still sent; with no away iPhone to send, it changes no answer.

  **An approval** is announced with no content: through APNs the encrypted
  preview is null, as for an oversized one, and the alert a fixed string;
  through Web Push the message names its kind and carries neither a row number
  nor text.

  At most `max_devices/0` registered phones are traversed. Each phone sent to
  gets one `[:fermix, :channel, :push]` event; `sent` counts the phones of both
  routes, and any phone that failed makes the answer `{:push_failed, failures}`,
  each a device id and a typed reason.
  """

  require Logger

  alias FermixChannels.Mobile.DeviceRegistry
  alias FermixChannels.Mobile.DeviceStore
  alias FermixChannels.Mobile.DeviceStore.Device
  alias FermixChannels.Mobile.Identity
  alias FermixChannels.Mobile.Push.Config
  alias FermixChannels.Mobile.Push.PigeonDispatcher
  alias FermixChannels.Mobile.Push.WebPushLeg
  alias FermixChannels.Mobile.WebPush
  alias FermixChannels.Telemetry
  alias FermixCore.Companion.Timeline
  alias Pigeon.APNS.Notification

  @info "fermix-push-v1"
  @nonce_bytes 12
  @tag_bytes 16
  @max_payload_bytes 4_096
  @max_preview_bytes 1_048_576
  @max_devices 64
  @zero_key <<0::256>>
  # A row's Web Push lives a day at the push service. An approval's lives as
  # long as the approval waits, at most a day: the caller's `ttl_s`, or 300 s,
  # the longest fixed wait (a soul change; a sandbox confirm waits 60 s,
  # `Companion.Output`), since an alert after the approval expired is noise.
  @row_ttl_s 86_400
  @max_ttl_s 86_400
  @approval_ttl_s 300
  # Past `WebPush.send/4`'s own worst case, about 75 s.
  @web_push_timeout_ms 90_000

  @type delivery_status ::
          %{
            status: :disabled | :no_registered_devices | :unconfigured_platform | :sent,
            sent: non_neg_integer()
          }
          | %{status: :suppressed, reason: :connected | :read, sent: 0}

  @doc "Maximum APNs JSON payload size accepted by the v1 contract."
  @spec max_payload_bytes() :: pos_integer()
  def max_payload_bytes, do: @max_payload_bytes

  @doc "Maximum paired-device count traversed by one push delivery."
  @spec max_devices() :: pos_integer()
  def max_devices, do: @max_devices

  @doc "Derive one device push key from the paired X25519 identities."
  @spec derive_key(binary(), binary(), binary()) :: {:ok, binary()} | {:error, term()}
  def derive_key(gateway_private, device_public, salt) do
    with :ok <- binary_size(:gateway_private_key, gateway_private, 32),
         :ok <- binary_size(:device_public_key, device_public, 32),
         :ok <- binary_size(:apns_key_salt, salt, 32),
         {:ok, shared} <- x25519(gateway_private, device_public) do
      prk = :crypto.mac(:hmac, :sha256, salt, shared)
      {:ok, :crypto.mac(:hmac, :sha256, prk, @info <> <<1>>)}
    end
  end

  @doc """
  Build one E2E preview notification for a registered paired device;
  `:approval` in place of the preview builds the content-free approval one.
  """
  @spec build_notification(
          Device.t(),
          binary(),
          String.t(),
          String.t() | :approval,
          String.t(),
          keyword()
        ) ::
          {:ok, Notification.t()} | {:error, term()}
  def build_notification(device, gateway_private, profile_id, preview_text, topic, opts \\ [])

  def build_notification(
        %Device{} = device,
        gateway_private,
        profile_id,
        preview_text,
        topic,
        opts
      )
      when is_list(opts) do
    with :ok <- validate_device(device),
         :ok <- validate_profile(profile_id),
         :ok <- validate_preview(preview_text),
         :ok <- validate_topic(topic),
         {:ok, key} <- derive_key(gateway_private, device.noise_pk, device.apns_key_salt),
         {:ok, inner, alert} <- choose_payload(profile_id, preview_text),
         {:ok, nonce} <- nonce(opts),
         {:ok, encrypted} <- encrypt(key, nonce, inner),
         {:ok, payload} <- outer_payload(alert, nonce, encrypted),
         :ok <- validate_payload_size(payload) do
      {:ok,
       %Notification{
         device_token: device.push_token,
         topic: topic,
         payload: payload,
         push_type: "alert"
       }}
    end
  end

  def build_notification(device, _private, _profile, _preview, _topic, _opts),
    do: {:error, {:invalid_push_device, device}}

  @doc """
  Return the deterministic suppression decision for one row; `connected?` is
  whether every phone the row could reach is connected.
  """
  @spec delivery_decision(boolean(), non_neg_integer(), pos_integer()) ::
          {:ok, :suppress_connected | :suppress_read | :deliver} | {:error, term()}
  def delivery_decision(connected?, read_frontier, server_seq) do
    with :ok <- validate_connected(connected?),
         :ok <- validate_read_frontier(read_frontier),
         :ok <- validate_server_seq(server_seq) do
      {:ok, decide(connected?, read_frontier, server_seq)}
    end
  end

  @doc "Send an unread timeline row to every registered phone that is not connected."
  @spec notify(String.t(), pos_integer(), String.t(), keyword()) ::
          {:ok, delivery_status()} | {:error, term()}
  def notify(profile_id, server_seq, preview_text, opts \\ []) when is_list(opts) do
    with :ok <- validate_profile(profile_id),
         :ok <- validate_server_seq(server_seq),
         :ok <- validate_preview(preview_text),
         apns = apns_config(opts),
         {:ok, decision} <- away_decision(apns, profile_id, opts),
         {:ok, decision} <- read_decision(decision, profile_id, server_seq, opts) do
      fields = %{
        kind: :message,
        profile_id: profile_id,
        server_seq: server_seq,
        preview_text: preview_text
      }

      deliver_decision(decision, apns, %{fields: fields, ttl_s: @row_ttl_s}, opts)
    end
  end

  @doc """
  Tell every registered phone that is not connected, with no content, that an
  approval waits for the owner. `ttl_s:` is how long the approval waits, and
  so how long its Web Push lives: at most a day, 300 s when not given.
  """
  @spec notify_approval(String.t(), keyword()) :: {:ok, delivery_status()} | {:error, term()}
  def notify_approval(profile_id, opts \\ []) when is_list(opts) do
    with :ok <- validate_profile(profile_id),
         {:ok, ttl_s} <- approval_ttl(opts),
         apns = apns_config(opts),
         {:ok, decision} <- away_decision(apns, profile_id, opts) do
      fields = %{kind: :approval, profile_id: profile_id, server_seq: nil, preview_text: nil}
      deliver_decision(decision, apns, %{fields: fields, ttl_s: ttl_s}, opts)
    end
  end

  defp approval_ttl(opts) do
    case Keyword.get(opts, :ttl_s, @approval_ttl_s) do
      ttl_s when is_integer(ttl_s) and ttl_s > 0 -> {:ok, min(ttl_s, @max_ttl_s)}
      other -> {:error, {:invalid_ttl_s, other}}
    end
  end

  # Resolved for the APNs route alone, so a config that does not resolve
  # reaches only the iPhones it would have sent.
  defp apns_config(opts), do: opts |> config_input() |> Config.new()

  defp apns_off?({:ok, %Config{enabled: false}}), do: true
  defp apns_off?(_resolved_or_not), do: false

  # Who would be pushed, before the row's read state: every registered phone
  # that is not connected for the profile.
  defp away_decision(apns, profile_id, opts) do
    with {:ok, connected} <- connected_devices(profile_id, opts),
         {:ok, devices} <- list_registered_devices(opts),
         :ok <- validate_device_count(devices) do
      away = Enum.reject(devices, &(&1.device_id in connected))
      {:ok, decide_away(apns, away, connected)}
    end
  end

  defp decide_away(apns, away, connected) do
    cond do
      apns_off?(apns) and not Enum.any?(away, &web_push?/1) -> :disabled
      away == [] and connected != [] -> :suppress_connected
      true -> {:deliver, away}
    end
  end

  defp read_decision({:deliver, away}, profile_id, server_seq, opts) do
    with {:ok, frontier} <- read_frontier(profile_id, opts) do
      case delivery_decision(false, frontier, server_seq) do
        {:ok, :deliver} -> {:ok, {:deliver, away}}
        decided -> decided
      end
    end
  end

  defp read_decision(decision, _profile, _seq, _opts), do: {:ok, decision}

  defp deliver_decision(:disabled, _apns, _push, _opts),
    do: {:ok, %{status: :disabled, sent: 0}}

  defp deliver_decision(:suppress_connected, _apns, _push, _opts),
    do: {:ok, %{status: :suppressed, reason: :connected, sent: 0}}

  defp deliver_decision(:suppress_read, _apns, _push, _opts),
    do: {:ok, %{status: :suppressed, reason: :read, sent: 0}}

  defp deliver_decision({:deliver, []}, _apns, _push, _opts),
    do: {:ok, %{status: :no_registered_devices, sent: 0}}

  defp deliver_decision({:deliver, away}, apns, push, opts),
    do: away |> routes(apns) |> send_routes(apns, push, opts)

  # One route per phone, by what it registered: its Web Push subscription, or
  # an iPhone's APNs token unless APNs is off. Every other phone is refused by
  # name, its typed reason in the log, and never sent through APNs.
  defp routes(phones, apns) do
    {web, tokens} = Enum.split_with(phones, &web_push?/1)
    {iphones, refused} = Enum.split_with(tokens, &(&1.platform in [nil, "ios"]))
    Enum.each(refused, &log_refusal/1)
    %{web: web, apns: if(apns_off?(apns), do: [], else: iphones)}
  end

  defp web_push?(%Device{push_service: service}), do: is_binary(service)

  defp send_routes(%{web: [], apns: []}, _apns, _push, _opts),
    do: {:ok, %{status: :unconfigured_platform, sent: 0}}

  defp send_routes(%{web: [], apns: iphones}, apns, push, opts),
    do: apns_leg(iphones, apns, push.fields, opts)

  defp send_routes(%{web: phones, apns: []}, _apns, push, opts),
    do: send_web_push(phones, push, opts)

  defp send_routes(%{web: phones, apns: iphones}, apns, push, opts) do
    apns_result = apns_leg(iphones, apns, push.fields, opts)
    combine(iphones, apns_result, send_web_push(phones, push, opts))
  end

  defp apns_leg(iphones, {:ok, config}, fields, opts),
    do: send_apns(iphones, config, fields.profile_id, apns_preview(fields), opts)

  defp apns_leg(iphones, {:error, reason}, _fields, _opts) do
    Logger.error(
      "mobile push could not use its APNs config (#{inspect(reason)}); " <>
        "#{length(iphones)} iPhone(s) not pushed"
    )

    {:error, reason}
  end

  defp apns_preview(%{kind: :approval}), do: :approval
  defp apns_preview(%{kind: :message, preview_text: preview_text}), do: preview_text

  # Both routes ran: every phone that failed is listed, and an APNs failure
  # that names no phone (the identity, the dispatcher) is each iPhone's.
  defp combine(iphones, apns_result, web_result) do
    {apns_sent, apns_failed} = leg_outcome(apns_result, iphones)
    {web_sent, web_failed} = leg_outcome(web_result, [])

    case apns_failed ++ web_failed do
      [] -> {:ok, %{status: :sent, sent: apns_sent + web_sent}}
      failures -> {:error, {:push_failed, failures}}
    end
  end

  defp leg_outcome({:ok, %{sent: sent}}, _phones), do: {sent, []}
  defp leg_outcome({:error, {:push_failed, failures}}, _phones), do: {0, failures}

  defp leg_outcome({:error, reason}, phones),
    do: {0, Enum.map(phones, &%{device_id: &1.device_id, reason: reason})}

  defp send_web_push(phones, push, opts),
    do: WebPushLeg.deliver(phones, push.fields, push.ttl_s, web_push_deps(opts))

  # Every call the leg makes goes through `call_dependency/3`, in its tasks
  # too, so a raising sender is a typed failure and never a crash report that
  # quotes a subscription.
  defp web_push_deps(opts) do
    key = Keyword.get(opts, :web_push_key, &WebPush.Key.load/0)
    sender = Keyword.get(opts, :web_push_send, &WebPush.send/4)
    update = Keyword.get(opts, :update_device, &DeviceStore.update/2)

    %{
      key: fn -> call_dependency(:web_push_key, key, []) end,
      send: fn subscription, plaintext, ttl_s, send_opts ->
        call_dependency(:web_push_send, sender, [subscription, plaintext, ttl_s, send_opts])
      end,
      update_device: fn id, attrs -> call_dependency(:update_device, update, [id, attrs]) end,
      timeout_ms: Keyword.get(opts, :web_push_timeout_ms, @web_push_timeout_ms)
    }
  end

  defp send_apns(devices, config, profile_id, preview_text, opts) do
    with {:ok, gateway_private} <- load_gateway_private(opts),
         {:ok, deliveries} <-
           build_deliveries(devices, gateway_private, profile_id, preview_text, config, opts) do
      dispatch(deliveries, config, opts)
    end
  end

  defp log_refusal(%Device{device_id: device_id, platform: platform}) do
    {reason, sentence} = refusal(platform)

    Logger.warning(
      "mobile push refused #{device_id} #{inspect(reason)}: #{sentence}; nothing was sent"
    )
  end

  defp refusal("android") do
    {{:no_web_push_subscription, :android},
     "an Android phone is pushed through Web Push, and this one holds no subscription"}
  end

  defp refusal(platform),
    do: {{:no_push_service, :unknown_platform}, "its platform #{inspect(platform)} has no push"}

  defp build_deliveries(devices, gateway_private, profile_id, preview_text, config, opts) do
    Enum.reduce_while(devices, {:ok, []}, fn device, {:ok, deliveries} ->
      case build_notification(
             device,
             gateway_private,
             profile_id,
             preview_text,
             config.topic,
             nonce_fun: nonce_fun(opts)
           ) do
        {:ok, notification} ->
          {:cont, {:ok, [{device, notification} | deliveries]}}

        {:error, reason} ->
          Telemetry.emit_push(:mobile, :failed, 0)
          {:halt, {:error, {:notification_build_failed, device.device_id, reason}}}
      end
    end)
    |> reverse_deliveries()
  end

  defp reverse_deliveries({:ok, deliveries}), do: {:ok, Enum.reverse(deliveries)}
  defp reverse_deliveries({:error, _reason} = error), do: error

  defp dispatch(deliveries, config, opts) do
    notifications = Enum.map(deliveries, &elem(&1, 1))
    started = System.monotonic_time()
    result = call_dispatcher(notifications, config, opts)
    duration_us = elapsed_us(started)
    handle_dispatch_result(result, deliveries, duration_us)
  end

  defp handle_dispatch_result({:ok, responses}, deliveries, duration_us)
       when is_list(responses) and length(responses) == length(deliveries) do
    with :ok <- validate_response_tokens(deliveries, responses) do
      summarize_responses(deliveries, responses, duration_us)
    else
      {:error, reason} -> fail_all(deliveries, duration_us, reason)
    end
  end

  defp handle_dispatch_result({:ok, responses}, deliveries, duration_us)
       when is_list(responses) do
    reason = {:invalid_dispatch_response, :count_mismatch, length(responses), length(deliveries)}
    fail_all(deliveries, duration_us, reason)
  end

  defp handle_dispatch_result({:ok, _responses}, deliveries, duration_us),
    do: fail_all(deliveries, duration_us, {:invalid_dispatch_response, :not_a_list})

  defp handle_dispatch_result({:error, reason}, deliveries, duration_us),
    do: fail_all(deliveries, duration_us, {:push_dispatch_failed, dispatch_error_class(reason)})

  defp handle_dispatch_result(_result, deliveries, duration_us),
    do: fail_all(deliveries, duration_us, {:invalid_dispatch_result, :unexpected_shape})

  defp dispatch_error_class(reason) when is_atom(reason), do: reason

  defp dispatch_error_class(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    case elem(reason, 0) do
      class when is_atom(class) -> class
      _other -> :unknown
    end
  end

  defp dispatch_error_class(_reason), do: :unknown

  defp validate_response_tokens(deliveries, responses) do
    matches? =
      Enum.zip(deliveries, responses)
      |> Enum.all?(fn {{_device, sent}, response} ->
        match?(%Notification{}, response) and response.device_token == sent.device_token
      end)

    if matches?, do: :ok, else: {:error, :mismatched_dispatch_responses}
  end

  defp summarize_responses(deliveries, responses, duration_us) do
    failures =
      Enum.zip(deliveries, responses)
      |> Enum.reduce([], fn {{device, _sent}, response}, errors ->
        case response.response do
          :success ->
            Telemetry.emit_push(:mobile, :sent, duration_us)
            errors

          reason ->
            Telemetry.emit_push(:mobile, :failed, duration_us)
            [%{device_id: device.device_id, reason: response_error_class(reason)} | errors]
        end
      end)
      |> Enum.reverse()

    case failures do
      [] -> {:ok, %{status: :sent, sent: length(deliveries)}}
      _nonempty -> {:error, {:push_failed, failures}}
    end
  end

  defp response_error_class(nil), do: :missing_response
  defp response_error_class(reason) when is_atom(reason), do: reason
  defp response_error_class(_reason), do: :invalid_response

  defp fail_all(deliveries, duration_us, reason) do
    Enum.each(deliveries, fn _delivery ->
      Telemetry.emit_push(:mobile, :failed, duration_us)
    end)

    {:error, reason}
  end

  defp choose_payload(profile_id, :approval) do
    {:ok, %{"profile_id" => profile_id, "preview_text" => nil},
     %{"title" => "Fermix", "body" => "Approval needed"}}
  end

  defp choose_payload(profile_id, preview_text) do
    full = %{"profile_id" => profile_id, "preview_text" => preview_text}
    full_alert = %{"title" => "Fermix", "body" => "New message"}

    with {:ok, full_size} <- projected_payload_size(full, full_alert) do
      if full_size <= @max_payload_bytes do
        {:ok, full, full_alert}
      else
        choose_title_only(profile_id)
      end
    end
  end

  defp choose_title_only(profile_id) do
    inner = %{"profile_id" => profile_id, "preview_text" => nil}
    alert = %{"title" => "Fermix"}

    with {:ok, size} <- projected_payload_size(inner, alert) do
      if size <= @max_payload_bytes,
        do: {:ok, inner, alert},
        else: {:error, {:push_payload_too_large, size, @max_payload_bytes}}
    end
  end

  defp projected_payload_size(inner, alert) do
    with {:ok, plaintext} <- Jason.encode(inner) do
      nonce_b64 = String.duplicate("A", encoded64_size(@nonce_bytes))
      ciphertext_b64 = String.duplicate("A", encoded64_size(byte_size(plaintext) + @tag_bytes))

      alert
      |> build_outer(nonce_b64, ciphertext_b64)
      |> Jason.encode()
      |> case do
        {:ok, encoded} -> {:ok, byte_size(encoded)}
        {:error, reason} -> {:error, {:push_payload_encode_failed, reason}}
      end
    else
      {:error, reason} -> {:error, {:push_preview_encode_failed, reason}}
    end
  end

  defp nonce(opts) do
    case nonce_fun(opts).(@nonce_bytes) do
      nonce when is_binary(nonce) and byte_size(nonce) == @nonce_bytes -> {:ok, nonce}
      value -> {:error, {:invalid_push_nonce, value}}
    end
  end

  defp nonce_fun(opts), do: Keyword.get(opts, :nonce_fun, &:crypto.strong_rand_bytes/1)

  defp encrypt(key, nonce, inner) do
    with {:ok, plaintext} <- Jason.encode(inner) do
      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(
          :chacha20_poly1305,
          key,
          nonce,
          plaintext,
          <<>>,
          @tag_bytes,
          true
        )

      {:ok, ciphertext <> tag}
    else
      {:error, reason} -> {:error, {:push_preview_encode_failed, reason}}
    end
  end

  defp outer_payload(alert, nonce, encrypted) do
    payload = build_outer(alert, Base.encode64(nonce), Base.encode64(encrypted))

    case Jason.encode(payload) do
      {:ok, _encoded} -> {:ok, payload}
      {:error, reason} -> {:error, {:push_payload_encode_failed, reason}}
    end
  end

  defp build_outer(alert, nonce_b64, ciphertext_b64) do
    %{
      "aps" => %{"alert" => alert, "mutable-content" => 1},
      "fx" => %{"n" => nonce_b64, "c" => ciphertext_b64}
    }
  end

  defp validate_payload_size(payload) do
    size = payload |> Jason.encode!() |> byte_size()
    if size <= @max_payload_bytes, do: :ok, else: {:error, :push_payload_too_large}
  end

  # The device ids with a socket open for the profile at this moment.
  defp connected_devices(profile_id, opts) do
    callback =
      Keyword.get(opts, :connected_devices, fn profile ->
        {:ok, DeviceRegistry |> DeviceRegistry.connected(profile) |> Enum.map(&elem(&1, 0))}
      end)

    case call_dependency(:connected_devices, callback, [profile_id]) do
      {:ok, ids} when is_list(ids) -> connected_ids(ids)
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_connected_devices_result, other}}
    end
  end

  defp connected_ids(ids) do
    if Enum.all?(ids, &is_binary/1),
      do: {:ok, ids},
      else: {:error, {:invalid_connected_devices_result, ids}}
  end

  defp read_frontier(profile_id, opts) do
    callback = Keyword.get(opts, :read_frontier, &Timeline.read_frontier/1)
    call_dependency(:read_frontier, callback, [profile_id])
  end

  defp list_registered_devices(opts) do
    callback = Keyword.get(opts, :list_devices, &DeviceStore.list/0)

    with {:ok, devices} <- call_dependency(:list_devices, callback, []),
         true <- is_list(devices) or {:error, {:invalid_device_list, devices}} do
      {:ok, Enum.filter(devices, &registered?/1)}
    end
  end

  defp registered?(%Device{push_token: token}) when is_binary(token), do: token != ""
  defp registered?(_device), do: false

  defp load_gateway_private(opts) do
    callback = Keyword.get(opts, :load_identity, &Identity.load/0)

    with {:ok, identity} <- call_dependency(:load_identity, callback, []),
         {:ok, private} <- identity_private(identity) do
      {:ok, private}
    end
  end

  defp identity_private(%{gateway_private_key: private}),
    do: binary_result(:gateway_private_key, private, 32)

  defp identity_private(identity), do: {:error, {:invalid_mobile_identity, identity}}

  defp call_dispatcher(notifications, config, opts) do
    dispatcher = Keyword.get(opts, :dispatcher, PigeonDispatcher)

    cond do
      is_function(dispatcher, 2) ->
        call_dependency(:dispatcher, dispatcher, [notifications, config])

      is_atom(dispatcher) ->
        call_dependency(:dispatcher, fn -> dispatcher.dispatch(notifications, config) end, [])

      true ->
        {:error, {:invalid_push_dependency, :dispatcher, dispatcher}}
    end
  end

  # A dependency callback that raises is either a vendor fault or a Fermix
  # defect, and the two used to be indistinguishable: everything collapsed into
  # one reason with no type and no stacktrace, so a `FunctionClauseError` in our
  # own code read as an APNs hiccup and got blind-retried. The exception class
  # now travels in the reason and the full trace is logged. Stack frame
  # arguments are dropped before formatting because they carry the notification
  # list — device tokens and encrypted payloads never belong in a log line.
  defp call_dependency(name, callback, args) when is_function(callback, length(args)) do
    apply(callback, args)
  rescue
    error ->
      Logger.error(
        "mobile push dependency #{inspect(name)} raised:\n" <>
          Exception.format(:error, error, arity_only(__STACKTRACE__))
      )

      {:error, {:push_dependency_exception, name, error.__struct__, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:push_dependency_exit, name, reason}}
  end

  defp call_dependency(name, callback, _args),
    do: {:error, {:invalid_push_dependency, name, callback}}

  defp arity_only(stacktrace) do
    Enum.map(stacktrace, fn
      {module, function, args, location} when is_list(args) ->
        {module, function, length(args), location}

      entry ->
        entry
    end)
  end

  defp config_input(opts) do
    Keyword.get_lazy(opts, :config, fn ->
      :fermix_channels
      |> Application.get_env(:mobile, [])
      |> nested_value(:push, [])
    end)
  end

  defp nested_value(values, key, default) when is_list(values),
    do: Keyword.get(values, key, default)

  defp nested_value(values, key, default) when is_map(values) do
    Map.get(values, key, Map.get(values, Atom.to_string(key), default))
  end

  defp nested_value(_values, _key, default), do: default

  defp decide(true, _frontier, _seq), do: :suppress_connected
  defp decide(false, frontier, seq) when frontier >= seq, do: :suppress_read
  defp decide(false, _frontier, _seq), do: :deliver

  defp validate_device(%Device{push_token: token, noise_pk: key, apns_key_salt: salt}) do
    with :ok <- nonempty_text(:push_token, token, 255),
         :ok <- binary_size(:noise_pk, key, 32),
         :ok <- binary_size(:apns_key_salt, salt, 32) do
      :ok
    end
  end

  defp validate_profile(value), do: nonempty_text(:profile_id, value, 255)
  defp validate_topic(value), do: nonempty_text(:topic, value, 255)

  defp validate_preview(:approval), do: :ok

  defp validate_preview(value) when is_binary(value) and byte_size(value) <= @max_preview_bytes do
    if String.valid?(value), do: :ok, else: {:error, {:invalid_preview_text, :invalid_utf8}}
  end

  defp validate_preview(value) when is_binary(value) do
    {:error, {:invalid_preview_text, :too_large, byte_size(value), @max_preview_bytes}}
  end

  defp validate_preview(_value), do: {:error, {:invalid_preview_text, :not_binary}}

  defp validate_connected(value) when is_boolean(value), do: :ok
  defp validate_connected(value), do: {:error, {:invalid_connected, value}}

  defp validate_read_frontier(value) when is_integer(value) and value >= 0, do: :ok
  defp validate_read_frontier(value), do: {:error, {:invalid_read_frontier, value}}

  defp validate_server_seq(value) when is_integer(value) and value > 0, do: :ok
  defp validate_server_seq(value), do: {:error, {:invalid_server_seq, value}}

  defp validate_device_count(devices) when length(devices) <= @max_devices, do: :ok

  defp validate_device_count(devices),
    do: {:error, {:too_many_registered_devices, length(devices), @max_devices}}

  defp nonempty_text(_field, value, max)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= max do
    if String.valid?(value), do: :ok, else: {:error, :invalid_utf8}
  end

  defp nonempty_text(field, value, _max), do: {:error, {:invalid_push_field, field, value}}

  defp binary_size(_field, value, size) when is_binary(value) and byte_size(value) == size,
    do: :ok

  defp binary_size(field, _value, size), do: {:error, {:invalid_push_field, field, size}}

  defp binary_result(field, value, size) do
    case binary_size(field, value, size) do
      :ok -> {:ok, value}
      {:error, _reason} = error -> error
    end
  end

  defp x25519(private, public) do
    case :crypto.compute_key(:ecdh, public, private, :x25519) do
      @zero_key -> {:error, :invalid_device_public_key}
      <<shared::binary-size(32)>> -> {:ok, shared}
    end
  rescue
    ErlangError -> {:error, :invalid_device_public_key}
  end

  defp encoded64_size(bytes), do: 4 * div(bytes + 2, 3)

  defp elapsed_us(started) do
    (System.monotonic_time() - started)
    |> System.convert_time_unit(:native, :microsecond)
    |> max(0)
  end
end
