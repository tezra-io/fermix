defmodule FermixCore.Home.Archive.RestoredConfig do
  @moduledoc """
  What a restore changes in the archived `config.toml`, and nothing more, each
  change made through `FermixCore.Home.Archive.ConfigText` so every other byte
  of the file stays as it was:

    * the settings that name the archived machine's own paths
      (`FermixCore.Home.DeviceLocal.settings/0`, such as the dev plugin
      folder) are left out, on any host: they stay on the machine that set
      them, and a return puts that machine's own back
      (`FermixCore.Home.Candidate.Return`);
    * values that named the old home's path name the new one;
    * `[fermix_core.harness] approved` becomes `false`: coding-harness consent
      was given for one machine and is never copied as consent for another
      (M75 §13);
    * a home in keyring mode (no `[fermix_core] secret_store`, or
      `"keyring"`, read by `SecretWriter.parse_store/1`) restored on a host
      that is not macOS and whose keyring cannot be used (`keyring_usable?`,
      true only when the keyring answered `available`: a probe that timed
      out or could not tell keeps nothing in a keyring the new host may not
      read) gets `secret_store = "file"`. On macOS the keyring is kept;
    * `[fermix_channels.imessage] enabled = true` restored on a host that is
      not macOS becomes `false`: iMessage needs that Mac's Messages database
      and helper, and a settings file that asks for it refuses to load on
      another system, so the restored engine could not start (M75);
    * an Always On server's own S3 bucket, signed with its instance role
      (`s3_credentials = "instance_role"`), restored on macOS is left out
      (`Archive.InstanceRole`): a Mac keeps no S3 snapshots. Elsewhere it is
      kept, since a Linux restore may be that server's own, whose first boot
      sets its role up again.

  It also reports, without changing them, the keys that hold absolute paths
  outside the old home, and how many secrets the file keeps as `@keyring`
  references, which do not travel.
  """

  alias FermixCore.Home.Archive.ConfigText
  alias FermixCore.Home.Archive.InstanceRole
  alias FermixCore.Home.DeviceLocal
  alias FermixCore.Setup.SecretWriter

  @type facts :: %{
          old_root: Path.t(),
          new_root: Path.t(),
          macos?: boolean(),
          keyring_usable?: (-> boolean())
        }
  @type settled :: %{
          rewritten: [String.t()],
          kept_paths: [String.t()],
          harness_consent_reset: boolean(),
          secret_store_switched: boolean(),
          imessage_disabled: boolean(),
          instance_role_dropped: boolean(),
          device_settings_dropped: [String.t()],
          keyring_secrets: non_neg_integer()
        }

  @doc "The report for an archive that carries no `config.toml`."
  @spec none() :: settled()
  def none do
    %{
      rewritten: [],
      kept_paths: [],
      harness_consent_reset: false,
      secret_store_switched: false,
      imessage_disabled: false,
      instance_role_dropped: false,
      device_settings_dropped: [],
      keyring_secrets: 0
    }
  end

  @doc "Applies a restore's changes to `text`, answering the new text and what changed."
  @spec settle(String.t(), facts()) ::
          {:ok, String.t(), settled()} | {:error, {:config_not_rewritable, term()}}
  def settle(text, %{old_root: old_root, new_root: new_root, macos?: macos?} = facts)
      when is_binary(text) and is_binary(old_root) and is_binary(new_root) and
             is_boolean(macos?) and is_function(facts.keyring_usable?, 0) do
    {here, dropped} = drop_device_settings(text)

    case ConfigText.rebase(here, old_root, new_root) do
      {:ok, rebased, rewritten} ->
        {:ok, settle_rebased(here, {rebased, rewritten, dropped}, facts)}

      {:error, reason} ->
        {:error, {:config_not_rewritable, reason}}
    end
    |> flatten()
  end

  defp flatten({:ok, {text, settled}}), do: {:ok, text, settled}
  defp flatten({:error, _reason} = error), do: error

  # The archived machine's own settings, each as its dotted key, in the order
  # `DeviceLocal` lists them.
  defp drop_device_settings(text),
    do: Enum.reduce(DeviceLocal.settings(), {text, []}, &drop_setting/2)

  defp drop_setting(%{table: table, key: key}, {text, dropped}) do
    case ConfigText.drop(text, table, key) do
      {text, true} -> {text, dropped ++ ["#{table}.#{key}"]}
      {text, false} -> {text, dropped}
    end
  end

  defp settle_rebased(original, {rebased, rewritten, dropped}, facts) do
    {consent_text, consent_reset?} = reset_harness_consent(rebased)
    {store_text, switched?} = file_store_without_keyring(consent_text, facts)
    {imessage_text, imessage_off?} = imessage_off_away_from_macos(store_text, facts)
    {settled_text, instance_role_dropped?} = instance_role_off_a_mac(imessage_text, facts)

    {settled_text,
     %{
       rewritten: rewritten,
       kept_paths: ConfigText.paths_outside(original, facts.old_root),
       harness_consent_reset: consent_reset?,
       secret_store_switched: switched?,
       imessage_disabled: imessage_off?,
       instance_role_dropped: instance_role_dropped?,
       device_settings_dropped: dropped,
       keyring_secrets: ConfigText.keyring_references(original)
     }}
  end

  defp reset_harness_consent(text) do
    case ConfigText.value(text, "fermix_core.harness", "approved") do
      {:ok, "true"} -> {ConfigText.put(text, "fermix_core.harness", "approved", "false"), true}
      _not_given -> {text, false}
    end
  end

  defp imessage_off_away_from_macos(text, %{macos?: true}), do: {text, false}

  defp imessage_off_away_from_macos(text, %{macos?: false}) do
    case ConfigText.value(text, "fermix_channels.imessage", "enabled") do
      {:ok, "true"} ->
        {ConfigText.put(text, "fermix_channels.imessage", "enabled", "false"), true}

      _off_or_absent ->
        {text, false}
    end
  end

  defp instance_role_off_a_mac(text, %{macos?: true}) do
    dropped = InstanceRole.drop(text)
    {dropped, dropped != text}
  end

  defp instance_role_off_a_mac(text, %{macos?: false}), do: {text, false}

  defp file_store_without_keyring(text, %{macos?: true}), do: {text, false}

  defp file_store_without_keyring(text, %{keyring_usable?: usable?}) do
    if keyring_mode?(text) and not usable?.(),
      do: {ConfigText.put(text, "fermix_core", "secret_store", ~s("file")), true},
      else: {text, false}
  end

  defp keyring_mode?(text) do
    stored =
      case ConfigText.value(text, "fermix_core", "secret_store") do
        :absent -> nil
        {:ok, raw} -> raw |> ConfigText.string() |> string_or(raw)
      end

    SecretWriter.parse_store(stored) == {:ok, :keyring}
  end

  defp string_or({:ok, value}, _raw), do: value
  defp string_or(:error, raw), do: raw
end
