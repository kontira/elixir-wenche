defmodule Wenche.MaskinportenTest do
  use ExUnit.Case, async: true

  alias Wenche.Maskinporten

  setup do
    rsa_key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem_entry = :public_key.pem_entry_encode(:RSAPrivateKey, rsa_key)
    pem = :public_key.pem_encode([pem_entry])

    %{private_key_pem: pem}
  end

  describe "build_jwt_grant/3" do
    test "builds a valid JWT with correct claims", %{private_key_pem: pem} do
      config = [
        client_id: "test-client-id",
        kid: "test-kid",
        private_key_pem: pem,
        env: "test"
      ]

      assert {:ok, jwt} = Maskinporten.build_jwt_grant(config, "altinn:instances.read")
      assert is_binary(jwt)

      # JWT should have 3 parts
      parts = String.split(jwt, ".")
      assert length(parts) == 3

      # Decode header to check RS256 and kid
      header = parts |> hd() |> Base.url_decode64!(padding: false) |> Jason.decode!()
      assert header["alg"] == "RS256"
      assert header["kid"] == "test-kid"

      # Decode payload to check claims
      payload = parts |> Enum.at(1) |> Base.url_decode64!(padding: false) |> Jason.decode!()
      assert payload["iss"] == "test-client-id"
      assert payload["aud"] == "https://test.maskinporten.no/"
      assert payload["scope"] == "altinn:instances.read"
      assert is_integer(payload["iat"])
      assert is_integer(payload["exp"])
      assert payload["exp"] == payload["iat"] + 119
      assert is_binary(payload["jti"])
    end

    test "uses prod URLs when env is prod", %{private_key_pem: pem} do
      config = [
        client_id: "test-client-id",
        kid: "test-kid",
        private_key_pem: pem,
        env: "prod"
      ]

      assert {:ok, jwt} = Maskinporten.build_jwt_grant(config, "altinn:instances.read")
      parts = String.split(jwt, ".")
      payload = parts |> Enum.at(1) |> Base.url_decode64!(padding: false) |> Jason.decode!()
      assert payload["aud"] == "https://maskinporten.no/"
    end

    test "adds authorization_details when org_nummer is provided", %{private_key_pem: pem} do
      config = [
        client_id: "test-client-id",
        kid: "test-kid",
        private_key_pem: pem,
        env: "test"
      ]

      assert {:ok, jwt} =
               Maskinporten.build_jwt_grant(config, "altinn:instances.read",
                 org_nummer: "912345678"
               )

      parts = String.split(jwt, ".")
      payload = parts |> Enum.at(1) |> Base.url_decode64!(padding: false) |> Jason.decode!()

      assert is_list(payload["authorization_details"])
      [auth_detail] = payload["authorization_details"]
      assert auth_detail["type"] == "urn:altinn:systemuser"
      assert auth_detail["systemuser_org"]["ID"] == "0192:912345678"
    end

    test "raises on missing config" do
      assert_raise KeyError, fn ->
        Maskinporten.build_jwt_grant([], "test:scope")
      end
    end
  end

  describe "default_scopes/0" do
    test "returns the default scopes" do
      scopes = Maskinporten.default_scopes()
      assert scopes =~ "altinn:instances.read"
      assert scopes =~ "altinn:instances.write"
    end
  end

  describe "skattemelding_scope/0" do
    test "includes the SKD scope and both Altinn instance scopes" do
      scopes = Maskinporten.skattemelding_scope()
      assert scopes =~ "skatteetaten:formueinntekt/skattemelding"
      # The Altinn scopes are required so SKD can resolve the systemuser →
      # executor trace via Altinn — without them, /valider and /innsendelse
      # reject with `innkommendeForespoerselManglerSporTilUtfoerende`.
      assert scopes =~ "altinn:instances.read"
      assert scopes =~ "altinn:instances.write"
    end
  end

  describe "admin_scopes/0" do
    test "returns the admin scopes" do
      scopes = Maskinporten.admin_scopes()
      assert scopes =~ "systemregister.write"
      assert scopes =~ "systemuser.request"
    end
  end
end
