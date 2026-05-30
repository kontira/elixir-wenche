defmodule Wenche.AltinnParties do
  @moduledoc """
  Altinn 3 Access Management client for looking up which parties an authenticated
  end-user is authorized to represent.

  Uses the ID-porten → Altinn token exchange (same as submission flows). The
  resulting Altinn token must have been issued with the
  `altinn:accessmanagement/authorizedparties` scope.

  Endpoint: `GET /accessmanagement/api/v1/authorizedparties`
  """

  @scope "altinn:accessmanagement/authorizedparties"

  @bases %{
    "test" => "https://platform.tt02.altinn.no",
    "prod" => "https://platform.altinn.no"
  }

  @doc "The ID-porten OAuth scope required to call the authorized-parties endpoint."
  def scope, do: @scope

  @doc """
  Returns all parties the authenticated user can represent in Altinn.

  `altinn_token` must be an Altinn platform token obtained by exchanging an
  ID-porten access token at `/authentication/api/v1/exchange/id-porten`.

  ## Options

  - `:env` — `"test"` or `"prod"` (default: `"prod"`)
  - `:req_options` — extra options passed to `Req` (default: `[]`)

  Returns `{:ok, [party]}` or `{:error, reason}`.
  Each party map includes `"organizationNumber"` (string or nil) and `"name"`.
  """
  def hent_parter(altinn_token, opts \\ []) do
    env = Keyword.get(opts, :env, "prod")
    req_options = Keyword.get(opts, :req_options, [])

    base =
      Map.get(@bases, env) ||
        raise ArgumentError, "invalid env: #{inspect(env)}. Use \"prod\" or \"test\"."

    url = "#{base}/accessmanagement/api/v1/authorizedparties"

    case Req.get(
           url,
           Keyword.merge(
             [
               headers: [
                 {"authorization", "Bearer #{altinn_token}"},
                 {"accept", "application/json"}
               ],
               receive_timeout: 30_000
             ],
             req_options
           )
         ) do
      {:ok, %Req.Response{status: 200, body: parties}} ->
        {:ok, parties}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:altinn_parties_error, status, body}}

      {:error, reason} ->
        {:error, {:altinn_parties_request_failed, reason}}
    end
  end

  @doc """
  Returns `{:ok, true}` if the authenticated user has at least one authorized
  role or right for `org_number`, `{:ok, false}` otherwise.

  Passes through `{:error, reason}` if the API call fails.
  """
  def har_tilgang_til_org?(altinn_token, org_number, opts \\ []) do
    case hent_parter(altinn_token, opts) do
      {:ok, parties} ->
        {:ok, Enum.any?(parties, &(&1["organizationNumber"] == org_number))}

      {:error, _} = err ->
        err
    end
  end
end
