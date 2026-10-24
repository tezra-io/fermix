defmodule FermixChannels.Mobile.Push.FcmConfigTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.Push.FcmConfig

  setup_all do
    %{private_key: X509.PrivateKey.new_rsa(2048) |> X509.PrivateKey.to_pem(wrap: true)}
  end

  test "an enabled table keeps the project and only the two fields that sign a token",
       %{private_key: private_key} do
    account = service_account(private_key)

    assert {:ok, %FcmConfig{enabled: true, project_id: "fermix-owner-123"} = config} =
             FcmConfig.new(
               enabled: true,
               project_id: "fermix-owner-123",
               service_account: account
             )

    assert config.credentials == %{
             "client_email" => "push@fermix-owner-123.iam.gserviceaccount.com",
             "private_key" => private_key
           }

    assert {:ok, ^config} = FcmConfig.new(config)

    assert {:ok, ^config} =
             FcmConfig.new(%{
               "enabled" => true,
               "project_id" => "fermix-owner-123",
               "service_account" => account
             })
  end

  # config/runtime.exs gives every home an `fcm` table, an empty one where the
  # TOML has none, and that must not stop a push through APNs.
  test "a disabled or absent switch needs nothing else" do
    assert {:ok, %FcmConfig{enabled: false, credentials: nil}} = FcmConfig.new(enabled: false)
    assert {:ok, %FcmConfig{enabled: false}} = FcmConfig.new(%FcmConfig{})
    assert {:ok, %FcmConfig{enabled: false}} = FcmConfig.new([])
    assert {:ok, %FcmConfig{enabled: false}} = FcmConfig.new(service_account: "@keyring")
  end

  test "inspection and every refusal leave the service account out", %{private_key: private_key} do
    account = service_account(private_key)

    {:ok, config} =
      FcmConfig.new(enabled: true, project_id: "fermix-owner-123", service_account: account)

    refute inspect(config) =~ "PRIVATE KEY"
    refute inspect(config) =~ "client_email"

    for broken <- [
          String.replace(account, "service_account", "authorized_user"),
          String.replace(account, "BEGIN", "BEGAN"),
          "{not json " <> account
        ] do
      assert {:error, {:invalid_fcm_config, :service_account, reason}} =
               FcmConfig.new(
                 enabled: true,
                 project_id: "fermix-owner-123",
                 service_account: broken
               )

      assert is_atom(reason)
    end
  end

  test "an enabled table refuses what cannot send", %{private_key: private_key} do
    account = service_account(private_key)
    ec_key = X509.PrivateKey.new_ec(:secp256r1) |> X509.PrivateKey.to_pem()

    cases = [
      {[enabled: "yes", project_id: "fermix-owner-123", service_account: account],
       {:enabled, :not_a_boolean}},
      {[enabled: true, service_account: account], {:project_id, :missing}},
      {[enabled: true, project_id: "Fermix_Owner", service_account: account],
       {:project_id, :not_a_firebase_project_id}},
      {[enabled: true, project_id: "fermix-owner-123"], {:service_account, :missing}},
      {[enabled: true, project_id: "fermix-owner-123", service_account: service_account(ec_key)],
       {:service_account, :invalid_private_key}},
      {[enabled: true, project_id: "fermix-owner-123", service_account: "@keyring"],
       {:service_account, :invalid_json}}
    ]

    for {values, {field, reason}} <- cases do
      assert {:error, {:invalid_fcm_config, ^field, ^reason}} = FcmConfig.new(values)
    end

    assert {:error, {:invalid_fcm_config, :unknown_key, :timeout_ms}} =
             FcmConfig.new(enabled: false, timeout_ms: 5_000)
  end

  defp service_account(private_key) do
    Jason.encode!(%{
      "type" => "service_account",
      "project_id" => "fermix-owner-123",
      "private_key_id" => "0123456789abcdef",
      "private_key" => private_key,
      "client_email" => "push@fermix-owner-123.iam.gserviceaccount.com",
      "client_id" => "123456789012345678901"
    })
  end
end
