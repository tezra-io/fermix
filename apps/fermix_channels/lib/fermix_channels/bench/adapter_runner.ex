defmodule FermixChannels.Bench.AdapterRunner do
  @moduledoc false

  alias FermixChannels.CLI
  alias FermixChannels.Discord
  alias FermixChannels.Dispatcher
  alias FermixChannels.Idempotency
  alias FermixChannels.Signal
  alias FermixChannels.Slack
  alias FermixChannels.Telegram
  alias FermixChannels.WhatsApp
  alias FermixCore.Agents.MainAgent
  alias FermixCore.Bench.MockProvider
  alias FermixCore.Bench.Recorder
  alias FermixCore.Bench.Stats
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Telemetry

  @http_stub :fermix_bench_http
  @reply_timeout_ms 2_000
  @adapter_samples 200
  @media_samples 50
  @e2e_samples 200
  # CLI has no channel-owned media transport, so there is no cli_send_media scenario.
  @scenario_specs %{
    "telegram_parse_inbound" => %{channel: :telegram, kind: :parse, samples: @adapter_samples},
    "telegram_send_short_text" => %{channel: :telegram, kind: :send_short_text, samples: @adapter_samples},
    "telegram_send_long_text_split" => %{
      channel: :telegram,
      kind: :send_long_text_split,
      samples: @adapter_samples
    },
    "telegram_send_media" => %{channel: :telegram, kind: :send_media, samples: @media_samples},
    "telegram_e2e_text" => %{channel: :telegram, kind: :e2e, samples: @e2e_samples},
    "discord_parse_inbound" => %{channel: :discord, kind: :parse, samples: @adapter_samples},
    "discord_send_short_text" => %{channel: :discord, kind: :send_short_text, samples: @adapter_samples},
    "discord_send_media" => %{channel: :discord, kind: :send_media, samples: @media_samples},
    "discord_e2e_text" => %{channel: :discord, kind: :e2e, samples: @e2e_samples},
    "slack_parse_inbound" => %{channel: :slack, kind: :parse, samples: @adapter_samples},
    "slack_send_short_text" => %{channel: :slack, kind: :send_short_text, samples: @adapter_samples},
    "slack_send_media" => %{channel: :slack, kind: :send_media, samples: @media_samples},
    "slack_e2e_text" => %{channel: :slack, kind: :e2e, samples: @e2e_samples},
    "whatsapp_parse_inbound" => %{channel: :whatsapp, kind: :parse, samples: @adapter_samples},
    "whatsapp_send_short_text" => %{channel: :whatsapp, kind: :send_short_text, samples: @adapter_samples},
    "whatsapp_send_media" => %{channel: :whatsapp, kind: :send_media, samples: @media_samples},
    "whatsapp_e2e_text" => %{channel: :whatsapp, kind: :e2e, samples: @e2e_samples},
    "signal_parse_inbound" => %{channel: :signal, kind: :parse, samples: @adapter_samples},
    "signal_send_short_text" => %{channel: :signal, kind: :send_short_text, samples: @adapter_samples},
    "signal_send_media" => %{channel: :signal, kind: :send_media, samples: @media_samples},
    "signal_e2e_text" => %{channel: :signal, kind: :e2e, samples: @e2e_samples},
    "cli_parse_inbound" => %{channel: :cli, kind: :parse, samples: @adapter_samples},
    "cli_send_short_text" => %{channel: :cli, kind: :send_short_text, samples: @adapter_samples},
    "cli_e2e_text" => %{channel: :cli, kind: :e2e, samples: @e2e_samples},
    "webhook_ingress_idempotency" => %{
      channel: :slack,
      kind: :webhook_idempotency,
      samples: @adapter_samples
    }
  }

  defmodule SignalClient do
    @moduledoc false

    def send_message(_account, _recipient, _text, _opts), do: :ok
    def send_attachment(_account, _recipient, _caption, _path, _opts), do: :ok
  end

  @spec list_scenarios() :: [String.t()]
  def list_scenarios do
    @scenario_specs |> Map.keys() |> Enum.sort()
  end

  @spec scenario?(String.t()) :: boolean()
  def scenario?(name) when is_binary(name), do: Map.has_key?(@scenario_specs, name)

  @spec run!(String.t(), keyword(), [{[atom()], String.t()}]) :: map()
  def run!(name, opts, events) when is_binary(name) and is_list(opts) and is_list(events) do
    spec = Map.fetch!(@scenario_specs, name)
    samples = Keyword.get(opts, :samples) || Map.fetch!(spec, :samples)
    warmup = Keyword.get(opts, :warmup, 20)
    before_snapshot = runtime_snapshot()

    {result, wall_time_us} =
      Telemetry.timed_us(fn -> with_env(spec, fn env -> run_samples(spec, env, samples, warmup, events) end) end)

    %{
      messages_dispatched: samples,
      messages_processed: result.processed,
      messages_superseded: 0,
      wall_time_us: wall_time_us,
      throughput_messages_per_second: throughput(result.processed, wall_time_us),
      setup: result.setup,
      stages: summarize_samples(result.raw_samples),
      memory: memory_delta(before_snapshot, runtime_snapshot())
    }
  end

  defp run_samples(spec, env, samples, warmup, events) do
    Enum.each(1..warmup//1, &run_sample!(spec, env, &1))

    {:ok, recorder} = Recorder.start(events: events)

    try do
      processed =
        Enum.reduce(1..samples//1, 0, fn index, count ->
          run_sample!(spec, env, index)
          count + 1
        end)

      %{processed: processed, raw_samples: Recorder.samples(recorder), setup: env.setup}
    after
      Recorder.stop(recorder)
    end
  end

  defp run_sample!(%{kind: :parse, channel: channel}, _env, index) do
    {:ok, _messages} = parse_message(channel, index)
    :ok
  end

  defp run_sample!(%{kind: :send_short_text, channel: channel}, env, index) do
    :ok = send_text(channel, reply_target(channel), "bench short #{index}", env)
  end

  defp run_sample!(%{kind: :send_long_text_split, channel: :telegram}, env, index) do
    :ok = send_text(:telegram, "123", long_markdown(index), env)
  end

  defp run_sample!(%{kind: :send_media, channel: channel}, env, index) do
    :ok = send_media(channel, reply_target(channel), media_part(env.media_path, index), env)
  end

  defp run_sample!(%{kind: :e2e, channel: channel}, env, index) do
    {:ok, [message]} = parse_message(channel, index)
    ref = make_ref()
    parent = self()

    reply_fn = fn
      {:text, text} ->
        result = send_text(channel, message.reply_target, text, env)
        send(parent, {:adapter_e2e_reply, ref, result})
        result

      {:media, media_part} ->
        result = send_media(channel, message.reply_target, media_part, env)
        send(parent, {:adapter_e2e_reply, ref, result})
        result
    end

    :ok =
      Dispatcher.dispatch([message],
        channel: adapter_module(channel),
        agent: MainAgent,
        agent_server: env.agent,
        conversation_store: env.conversation_store,
        reply_fn: reply_fn
      )

    await_e2e_reply!(ref)
    wait_until_idle!(env.agent)
  end

  defp run_sample!(%{kind: :webhook_idempotency, channel: channel}, env, index) do
    :fresh = Idempotency.check_and_record(channel, "bench-webhook-#{env.run_id}-#{index}")
    :ok
  end

  defp with_env(spec, fun) when is_function(fun, 1) do
    # This mutates Application env for channel adapters; adapter scenarios must
    # stay sequential at this layer.
    old_env = snapshot_channel_env()
    {:ok, _apps} = Application.ensure_all_started(:req)
    Req.Test.set_req_test_to_shared()
    stub_http()
    idempotency_pid = ensure_idempotency_started()
    env = build_env(spec)

    try do
      fun.(env)
    after
      stop_env(env)
      maybe_stop_idempotency(idempotency_pid)
      restore_channel_env(old_env)
    end
  end

  defp build_env(%{kind: :e2e}) do
    base_env()
    |> Map.merge(start_agent_env!())
  end

  defp build_env(_spec), do: base_env()

  defp base_env do
    put_bench_channel_env()
    media_path = write_media_file!()

    %{
      media_path: media_path,
      run_id: System.unique_integer([:positive]),
      setup: %{
        environments_started: 0,
        history_conversations_seeded: 0,
        history_messages_seeded: 0
      }
    }
  end

  defp start_agent_env! do
    unique = System.unique_integer([:positive])
    task_supervisor = :"adapter_bench_task_supervisor_#{unique}"
    conversation_store = :"adapter_bench_conversation_store_#{unique}"
    capability_registry = :"adapter_bench_capability_registry_#{unique}"
    agent = :"adapter_bench_main_agent_#{unique}"

    {:ok, task_pid} = Task.Supervisor.start_link(name: task_supervisor)
    {:ok, store_pid} = ConversationStore.start_link(name: conversation_store, repo: nil)
    {:ok, registry_pid} = CapabilityRegistry.start_link(name: capability_registry)
    :ok = CapabilityRegistry.register(capability_registry, bench_capability())

    {:ok, agent_pid} =
      MainAgent.start_link(
        name: agent,
        provider: MockProvider,
        capability_registry: capability_registry,
        conversation_store: conversation_store,
        task_supervisor: task_supervisor,
        extraction_enabled: false,
        memory_repo: nil,
        adapter_opts: [bench_script: :text, model: "bench-mock"]
      )

    %{
      task_pid: task_pid,
      store_pid: store_pid,
      registry_pid: registry_pid,
      agent_pid: agent_pid,
      conversation_store: conversation_store,
      agent: agent,
      setup: %{
        environments_started: 1,
        history_conversations_seeded: 0,
        history_messages_seeded: 0
      }
    }
  end

  defp stop_env(env) do
    if is_binary(Map.get(env, :media_path)), do: File.rm(env.media_path)

    env
    |> Map.take([:agent_pid, :registry_pid, :store_pid, :task_pid])
    |> Map.values()
    |> Enum.each(&stop_pid/1)
  end

  defp stop_pid(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end

  defp stop_pid(_pid), do: :ok

  defp ensure_idempotency_started do
    case Process.whereis(Idempotency) do
      nil ->
        {:ok, pid} = Idempotency.start_link()
        pid

      _pid ->
        nil
    end
  end

  defp maybe_stop_idempotency(nil), do: :ok
  defp maybe_stop_idempotency(pid), do: stop_pid(pid)

  defp put_bench_channel_env do
    Application.put_env(:fermix_channels, :telegram,
      bot_token: "telegram-token",
      owner_user_id: "111",
      allowed_user_ids: ["111"],
      req_options: [plug: {Req.Test, @http_stub}]
    )

    Application.put_env(:fermix_channels, :discord,
      enabled: true,
      bot_token: "discord-token",
      bot_user_id: "999",
      owner_user_id: "111",
      allowed_user_ids: ["111"],
      req_options: [plug: {Req.Test, @http_stub}]
    )

    Application.put_env(:fermix_channels, :slack,
      enabled: true,
      bot_token: "slack-token",
      signing_secret: "secret",
      owner_user_id: "U12345",
      allowed_user_ids: ["U12345"],
      req_options: [plug: {Req.Test, @http_stub}]
    )

    Application.put_env(:fermix_channels, :whatsapp,
      enabled: true,
      access_token: "whatsapp-token",
      phone_number_id: "123456789",
      owner_user_id: "15551234567",
      allowed_sender_ids: ["15551234567"],
      req_options: [plug: {Req.Test, @http_stub}]
    )

    Application.put_env(:fermix_channels, :signal,
      enabled: true,
      account: "+15550001111",
      owner_user_id: "+15551234567",
      allowed_sender_ids: ["+15551234567"],
      client: SignalClient,
      client_opts: []
    )
  end

  defp snapshot_channel_env do
    Map.new([:telegram, :discord, :slack, :whatsapp, :signal], fn channel ->
      {channel, Application.get_env(:fermix_channels, channel)}
    end)
  end

  defp restore_channel_env(old_env) do
    Enum.each(old_env, fn
      {channel, nil} -> Application.delete_env(:fermix_channels, channel)
      {channel, config} -> Application.put_env(:fermix_channels, channel, config)
    end)
  end

  defp stub_http do
    Req.Test.stub(@http_stub, fn conn ->
      Req.Test.json(conn, response_body(conn.request_path))
    end)
  end

  defp response_body("/api/files.getUploadURLExternal"),
    do: %{"ok" => true, "upload_url" => "https://slack-upload.test/upload", "file_id" => "F1"}

  defp response_body("/api/files.completeUploadExternal"), do: %{"ok" => true}
  defp response_body("/api/chat.postMessage"), do: %{"ok" => true}
  defp response_body("/upload"), do: %{"ok" => true}
  defp response_body(_path), do: %{"ok" => true, "id" => "media-1"}

  defp parse_message(:telegram, index), do: Telegram.parse_update(telegram_update(index))
  defp parse_message(:discord, index), do: Discord.parse_gateway_event(discord_event(index))
  defp parse_message(:slack, index), do: Slack.parse_webhook(slack_payload(index))
  defp parse_message(:whatsapp, index), do: WhatsApp.parse_webhook(whatsapp_payload(index))
  defp parse_message(:signal, index), do: Signal.parse_receive_entry(signal_entry(index))
  defp parse_message(:cli, index), do: CLI.parse_input("hello cli #{index}")

  defp send_text(:telegram, target, text, _env), do: Telegram.send_message(target, text)
  defp send_text(:discord, target, text, _env), do: Discord.send_message(target, text)
  defp send_text(:slack, target, text, _env), do: Slack.send_message(target, text)
  defp send_text(:whatsapp, target, text, _env), do: WhatsApp.send_message(target, text)
  defp send_text(:signal, target, text, _env), do: Signal.send_message(target, text)
  defp send_text(:cli, target, text, _env), do: CLI.send_message(target, text)

  defp send_media(:telegram, target, media_part, _env), do: Telegram.send_media(target, media_part)
  defp send_media(:discord, target, media_part, _env), do: Discord.send_media(target, media_part)
  defp send_media(:slack, target, media_part, _env), do: Slack.send_media(target, media_part)
  defp send_media(:whatsapp, target, media_part, _env), do: WhatsApp.send_media(target, media_part)
  defp send_media(:signal, target, media_part, _env), do: Signal.send_media(target, media_part)

  defp adapter_module(:telegram), do: Telegram
  defp adapter_module(:discord), do: Discord
  defp adapter_module(:slack), do: Slack
  defp adapter_module(:whatsapp), do: WhatsApp
  defp adapter_module(:signal), do: Signal
  defp adapter_module(:cli), do: CLI

  defp reply_target(:telegram), do: "123"
  defp reply_target(:discord), do: "dm-channel-1"
  defp reply_target(:slack), do: "D12345"
  defp reply_target(:whatsapp), do: "15551234567"
  defp reply_target(:signal), do: "+15551234567"
  defp reply_target(:cli), do: "cli"

  defp media_part(path, index) do
    %{
      kind: :image,
      path: path,
      filename: "bench-#{index}.png",
      mime_type: "image/png",
      caption: "bench media #{index}"
    }
  end

  defp long_markdown(index) do
    paragraph = "**bench #{index}** [link](https://example.com) text\n"
    String.duplicate(paragraph, 450)
  end

  defp await_e2e_reply!(ref) do
    receive do
      {:adapter_e2e_reply, ^ref, :ok} -> :ok
      {:adapter_e2e_reply, ^ref, {:error, reason}} -> raise "adapter e2e failed: #{inspect(reason)}"
    after
      @reply_timeout_ms -> raise "adapter e2e reply timed out"
    end
  end

  defp wait_until_idle!(agent) do
    deadline = System.monotonic_time(:millisecond) + @reply_timeout_ms
    wait_until_idle!(agent, deadline)
  end

  defp wait_until_idle!(agent, deadline) do
    status = MainAgent.status(agent)

    cond do
      status.active_requests == 0 and status.pending_requests == 0 ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        raise "adapter e2e agent did not become idle"

      true ->
        Process.sleep(5)
        wait_until_idle!(agent, deadline)
    end
  end

  defp bench_capability do
    Capability.new(%{
      name: "bench_echo",
      description: "Benchmark capability",
      parameters: %{type: "object", properties: %{"text" => %{type: "string"}}},
      kind: :builtin,
      executor: {FermixCore.Bench.Tools, :echo, []},
      policy_class: :read_only,
      metadata: %{category: :bench}
    })
  end

  defp telegram_update(index) do
    %{
      "message" => %{
        "message_id" => index,
        "text" => "hello telegram #{index}",
        "chat" => %{"id" => 123},
        "from" => %{"id" => 111, "username" => "alice"}
      }
    }
  end

  defp discord_event(index) do
    %{
      "t" => "MESSAGE_CREATE",
      "d" => %{
        "id" => "message-#{index}",
        "channel_id" => "dm-channel-1",
        "content" => "hello discord #{index}",
        "guild_id" => nil,
        "author" => %{"id" => "111", "username" => "alice", "bot" => false},
        "attachments" => []
      }
    }
  end

  defp slack_payload(index) do
    %{
      "type" => "event_callback",
      "team_id" => "T12345",
      "event" => %{
        "type" => "message",
        "channel" => "D12345",
        "channel_type" => "im",
        "user" => "U12345",
        "username" => "Alice",
        "text" => "hello slack #{index}",
        "ts" => "1714000000.#{String.pad_leading(to_string(index), 6, "0")}"
      }
    }
  end

  defp whatsapp_payload(index) do
    %{
      "entry" => [
        %{
          "changes" => [
            %{
              "value" => %{
                "metadata" => %{"phone_number_id" => "123456789"},
                "contacts" => [%{"wa_id" => "15551234567", "profile" => %{"name" => "Alice"}}],
                "messages" => [
                  %{
                    "from" => "15551234567",
                    "id" => "wamid.#{index}",
                    "timestamp" => "1714000000",
                    "type" => "text",
                    "text" => %{"body" => "hello whatsapp #{index}"}
                  }
                ]
              }
            }
          ]
        }
      ]
    }
  end

  defp signal_entry(index) do
    %{
      "envelope" => %{
        "sourceNumber" => "+15551234567",
        "sourceName" => "Alice",
        "timestamp" => 1_714_000_000_000 + index,
        "dataMessage" => %{
          "timestamp" => 1_714_000_000_000 + index,
          "message" => "hello signal #{index}"
        }
      }
    }
  end

  defp write_media_file! do
    path = Path.join(System.tmp_dir!(), "fermix-bench-media-#{System.unique_integer([:positive])}.png")
    {:ok, file} = File.open(path, [:write, :binary])

    try do
      :ok = IO.binwrite(file, <<0::8>>)
    after
      File.close(file)
    end

    path
  end

  defp summarize_samples(samples_by_stage) do
    samples_by_stage
    |> Enum.map(fn {stage, samples} -> {stage, Stats.summarize(samples)} end)
    |> Map.new()
  end

  defp throughput(_processed, 0), do: 0.0
  defp throughput(processed, wall_time_us), do: Float.round(processed * 1_000_000 / wall_time_us, 2)

  defp runtime_snapshot do
    %{
      beam_total_bytes: :erlang.memory(:total),
      ets_bytes: ets_bytes(),
      process_count: :erlang.system_info(:process_count)
    }
  end

  defp memory_delta(before, after_snapshot) do
    %{
      beam_total_before_bytes: before.beam_total_bytes,
      beam_total_after_bytes: after_snapshot.beam_total_bytes,
      ets_growth_bytes: after_snapshot.ets_bytes - before.ets_bytes,
      process_count_before: before.process_count,
      process_count_after: after_snapshot.process_count
    }
  end

  defp ets_bytes do
    word_size = :erlang.system_info(:wordsize)

    :ets.all()
    |> Enum.reduce(0, fn table, total ->
      total + (:ets.info(table, :memory) || 0) * word_size
    end)
  end
end
