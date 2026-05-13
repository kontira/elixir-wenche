defmodule Wenche.Maskinporten do
  @moduledoc """
  Authentication against Maskinporten via JWT grant (RFC 7523).

  Ported from `wenche/auth.py` in the original Python Wenche project.

  ## Flow

  1. Build a JWT signed with your private RSA key
  2. Exchange it at Maskinporten for an access token
  3. Exchange the Maskinporten token for an Altinn platform token

  ## Configuration

  Pass a keyword list with:

  - `:client_id` — Maskinporten client ID from Digdir
  - `:kid` — Key ID (UUID) from Digdir
  - `:private_key_pem` — PEM-encoded RSA private key (binary)
  - `:env` — `"test"` or `"prod"` (default: `"prod"`)
  - `:req_options` — optional extra options passed to `Req` (default: `[]`)
  """

  @maskinporten_urls %{
    "test" => "https://test.maskinporten.no",
    "prod" => "https://maskinporten.no"
  }

  @altinn_urls %{
    "test" => "https://platform.tt02.altinn.no",
    "prod" => "https://platform.altinn.no"
  }

  # Scopes for instance submission
  @scopes "altinn:instances.read altinn:instances.write"

  # Scopes for system register and system user administration
  @admin_scopes "altinn:authentication/systemregister.write " <>
                  "altinn:authentication/systemuser.request.read " <>
                  "altinn:authentication/systemuser.request.write"

  # Scope for aksjonærregisteroppgave submission directly to SKD's API
  @skd_aksjonaer_scope "skatteetaten:innrapporteringaksjonaerregisteroppgave"

  # Scopes for skattemeldingen (tax return): direct SKD API + Altinn 3 instances.
  # Both Altinn scopes are required so Skatteetaten can resolve the systemuser →
  # executor trace via Altinn ("spor til utførende"); without them SKD rejects
  # /valider and /innsendelse with `innkommendeForespoerselManglerSporTilUtfoerende`.
  # Mirrors the Python reference (olefredrik/Wenche, auth.py:54-57).
  @skattemelding_scope "skatteetaten:formueinntekt/skattemelding " <>
                         "altinn:instances.read altinn:instances.write"

  @doc """
  Obtains an Altinn platform token by:
  1. Building a JWT grant assertion
  2. Exchanging it at Maskinporten for an access token
  3. Exchanging the Maskinporten token for an Altinn platform token

  Returns `{:ok, altinn_token}` or `{:error, reason}`.
  """
  def get_altinn_token(config, scope \\ @scopes) do
    with {:ok, jwt} <- build_jwt_grant(config, scope),
         {:ok, maskinporten_token} <- exchange_jwt(config, jwt) do
      exchange_for_altinn_token(config, maskinporten_token)
    end
  end

  @doc """
  Obtains an Altinn token with system user authorization details.

  Use this for organization-specific operations using the system user flow.

  Returns `{:ok, altinn_token}` or `{:error, reason}`.
  """
  def get_systemuser_token(config, org_nummer) do
    with {:ok, jwt} <- build_jwt_grant(config, @scopes, org_nummer: org_nummer),
         {:ok, maskinporten_token} <- exchange_jwt(config, jwt) do
      exchange_for_altinn_token(config, maskinporten_token)
    end
  end

  @doc """
  Obtains a raw Maskinporten token with admin scopes for system register
  and system user administration.

  Does NOT exchange for an Altinn token.

  Returns `{:ok, maskinporten_token}` or `{:error, reason}`.
  """
  def get_admin_token(config) do
    with {:ok, jwt} <- build_jwt_grant(config, @admin_scopes) do
      exchange_jwt(config, jwt)
    end
  end

  @doc """
  Builds a JWT grant assertion (RFC 7523) signed with RS256.

  ## Options

  - `:org_nummer` — if provided, adds authorization_details for system user token

  Returns `{:ok, jwt_string}` or `{:error, reason}`.
  """
  def build_jwt_grant(config, scope, opts \\ []) do
    env = Keyword.get(config, :env, "prod")
    client_id = Keyword.fetch!(config, :client_id)
    kid = Keyword.fetch!(config, :kid)
    private_key_pem = Keyword.fetch!(config, :private_key_pem)
    audience = Map.fetch!(@maskinporten_urls, env) <> "/"
    org_nummer = Keyword.get(opts, :org_nummer)

    now = System.os_time(:second)

    claims = %{
      "aud" => audience,
      "iss" => client_id,
      "sub" => client_id,
      "scope" => scope,
      "iat" => now,
      "exp" => now + 119,
      "jti" => generate_jti()
    }

    claims =
      if org_nummer do
        Map.put(claims, "authorization_details", [
          %{
            "type" => "urn:altinn:systemuser",
            "systemuser_org" => %{
              "authority" => "iso6523-actorid-upis",
              "ID" => "0192:#{org_nummer}"
            }
          }
        ])
      else
        claims
      end

    signer = Joken.Signer.create("RS256", %{"pem" => private_key_pem}, %{"kid" => kid})

    case Joken.encode_and_sign(claims, signer) do
      {:ok, jwt, _claims} -> {:ok, jwt}
      {:error, reason} -> {:error, {:jwt_sign_failed, reason}}
    end
  end

  defp exchange_jwt(config, jwt) do
    env = Keyword.get(config, :env, "prod")
    req_options = Keyword.get(config, :req_options, [])
    token_url = "#{Map.fetch!(@maskinporten_urls, env)}/token"

    body =
      URI.encode_query(%{
        "grant_type" => "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion" => jwt
      })

    case Req.post(
           token_url,
           [
             {:body, body},
             {:headers, [{"content-type", "application/x-www-form-urlencoded"}]} | req_options
           ]
         ) do
      {:ok, %Req.Response{status: 200, body: %{"access_token" => token}}} ->
        {:ok, token}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:maskinporten_error, status, body}}

      {:error, reason} ->
        {:error, {:maskinporten_request_failed, reason}}
    end
  end

  defp exchange_for_altinn_token(config, maskinporten_token) do
    env = Keyword.get(config, :env, "prod")
    req_options = Keyword.get(config, :req_options, [])
    exchange_url = "#{Map.fetch!(@altinn_urls, env)}/authentication/api/v1/exchange/maskinporten"

    case Req.get(
           exchange_url,
           [{:headers, [{"authorization", "Bearer #{maskinporten_token}"}]} | req_options]
         ) do
      {:ok, %Req.Response{status: 200, body: token}} when is_binary(token) ->
        {:ok, String.trim(token, "\"")}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:altinn_exchange_error, status, body}}

      {:error, reason} ->
        {:error, {:altinn_exchange_failed, reason}}
    end
  end

  defp generate_jti do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  @doc """
  Obtains a Maskinporten token with SKD aksjonærregister scope and system user.

  SKD's API uses the Maskinporten token directly (no Altinn exchange).
  Requires that scope `skatteetaten:innrapporteringaksjonaerregisteroppgave`
  has been granted by Skatteetaten for the client.

  Returns `{:ok, maskinporten_token}` or `{:error, reason}`.
  """
  def get_skd_aksjonaer_token(config, org_nummer) do
    with {:ok, jwt} <- build_jwt_grant(config, @skd_aksjonaer_scope, org_nummer: org_nummer) do
      exchange_jwt(config, jwt)
    end
  end

  @doc """
  Obtains a Maskinporten token with skattemelding scope and system user
  authorization for the given organisation.

  SKD's skattemelding API uses the Maskinporten token directly (no Altinn
  exchange). Requires that scope `skatteetaten:formueinntekt/skattemelding`
  has been granted by Skatteetaten for the client.

  Returns `{:ok, maskinporten_token}` or `{:error, reason}`.
  """
  def get_skd_skattemelding_token(config, org_nummer) do
    with {:ok, jwt} <- build_jwt_grant(config, @skattemelding_scope, org_nummer: org_nummer) do
      exchange_jwt(config, jwt)
    end
  end

  @doc """
  Returns the default scopes for instance operations.
  """
  def default_scopes, do: @scopes

  @doc """
  Returns the admin scopes for system register operations.
  """
  def admin_scopes, do: @admin_scopes

  @doc """
  Returns the SKD aksjonærregister scope.
  """
  def skd_aksjonaer_scope, do: @skd_aksjonaer_scope

  @doc """
  Returns the skattemeldingen scope.
  """
  def skattemelding_scope, do: @skattemelding_scope
end
