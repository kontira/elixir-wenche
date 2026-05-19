defmodule Wenche.Systembruker do
  @moduledoc """
  System user flow for Altinn 3.

  Ported from `wenche/systembruker.py` in the original Python Wenche project.

  Altinn 3 requires that end-user systems register themselves in the system register
  and create a system user for each organization they will act on behalf of.

  ## Required options

  All public functions require a `:name` option — a short, lowercase identifier
  for the system (e.g. `"kontira"`). This is used to build the system ID
  (`<vendor_orgnr>_<name>`) and as the display name in Altinn.

  `registrer_system/4` additionally requires a `:description` option — a map
  with `"nb"`, `"nn"`, and `"en"` keys describing the system.

  ## Configurable scopes

  By default, the system requests rights for årsregnskap and aksjonærregisteroppgaven.
  Additional scopes can be enabled via the `:features` option:

      # Default — årsregnskap + aksjonærregister only
      Wenche.Systembruker.rights()

      # Include skattemelding scope
      Wenche.Systembruker.rights([:skattemelding])

  ## Setup (run once)

  1. `registrer_system/4` — registers the system in Altinn's system register
  2. `opprett_forespoersel/4` — sends request to org for approval
  3. User approves via confirmUrl in browser

  For submission, use `Wenche.Maskinporten.get_systemuser_token/2` to get a token.
  """

  @bases %{
    "test" => "https://platform.tt02.altinn.no",
    "prod" => "https://platform.altinn.no"
  }

  # Default rights — always included
  @default_rights [
    %{
      "resource" => [
        %{"id" => "urn:altinn:resource", "value" => "app_brg_aarsregnskap-vanlig-202406"}
      ]
    },
    %{
      "resource" => [
        %{
          "id" => "urn:altinn:resource",
          "value" => "ske-innrapportering-aksjonaerregisteroppgave"
        }
      ]
    }
  ]

  # Optional rights — enabled via :features
  #
  # Note: MVA-melding is NOT available here. Skatteetaten's MVA-melding API
  # only supports ID-porten (end-user authentication), not Maskinporten or
  # system users. Submitting an MVA-melding therefore cannot be done through
  # the systembruker flow.
  @optional_rights %{
    skattemelding: %{
      "resource" => [
        %{
          "id" => "urn:altinn:resource",
          "value" => "app_skd_formueinntekt-skattemelding-v2"
        }
      ]
    }
  }

  @doc """
  Returns the list of resource IDs that the system requests access to.

  Accepts an optional list of feature atoms to enable additional scopes.

  ## Examples

      Wenche.Systembruker.resource_ids()
      #=> ["app_brg_aarsregnskap-vanlig-202406", "ske-innrapportering-aksjonaerregisteroppgave"]

      Wenche.Systembruker.resource_ids([:skattemelding])
      #=> ["app_brg_aarsregnskap-vanlig-202406", "ske-innrapportering-aksjonaerregisteroppgave",
      #    "app_skd_formueinntekt-skattemelding-v2"]

  """
  def resource_ids(features \\ []) do
    rights(features)
    |> Enum.map(fn %{"resource" => [%{"value" => value}]} -> value end)
  end

  @doc """
  Returns the raw rights structure used in Altinn API payloads.

  Accepts an optional list of feature atoms to enable additional scopes.
  By default, only årsregnskap and aksjonærregisteroppgaven rights are included.

  ## Supported features

    * `:skattemelding` — adds the skattemelding scope
      (`app_skd_formueinntekt-skattemelding-v2`). Lets the systemuser
      authenticate against Skatteetaten's `/valider` endpoint via
      Maskinporten. **Submission still requires ID-porten** — a system
      user cannot submit the skattemelding. See `Wenche.Skattemelding`.

  MVA-melding is intentionally not listed: Skatteetaten only supports
  ID-porten authentication for MVA (validation and submission), so it
  cannot be requested via a system user.

  ## Examples

      Wenche.Systembruker.rights()
      #=> [%{"resource" => [...]}, %{"resource" => [...]}]

      Wenche.Systembruker.rights([:skattemelding])
      #=> [%{"resource" => [...]}, %{"resource" => [...]}, %{"resource" => [...]}]
  """
  def rights(features \\ []) do
    optional =
      features
      |> Enum.filter(&Map.has_key?(@optional_rights, &1))
      |> Enum.map(&Map.fetch!(@optional_rights, &1))

    @default_rights ++ optional
  end

  @doc """
  Returns the system ID in the format `<vendor_orgnr>_<name>`.
  """
  def system_id(vendor_orgnr, name) when is_binary(name) and name != "" do
    "#{vendor_orgnr}_#{name}"
  end

  @doc """
  Registers or updates the system in Altinn's system register.

  Tries POST first. If the system already exists, uses PUT to update.

  ## Required options

    * `:name` — short lowercase system identifier (e.g. `"kontira"`)
    * `:description` — map with `"nb"`, `"nn"`, `"en"` keys

  ## Optional options

    * `:env` — `"test"` or `"prod"` (default: `"prod"`)
    * `:features` — list of feature atoms to enable additional scopes (default: `[]`)

  Returns `{:ok, response_map}` or `{:error, reason}`.
  """
  def registrer_system(maskinporten_token, vendor_orgnr, client_id, opts \\ []) do
    name = fetch_required!(opts, :name)
    description = fetch_required!(opts, :description)
    env = Keyword.get(opts, :env, "prod")
    features = Keyword.get(opts, :features, [])
    req_options = Keyword.get(opts, :req_options, [])
    base = Map.fetch!(@bases, env)
    sid = system_id(vendor_orgnr, name)
    payload = bygg_system_payload(vendor_orgnr, client_id, name, description, features)

    headers = [
      {"Authorization", "Bearer #{maskinporten_token}"},
      {"Content-Type", "application/json"}
    ]

    url = "#{base}/authentication/api/v1/systemregister/vendor"

    case Req.post(
           url,
           Keyword.merge([json: payload, headers: headers, receive_timeout: 15_000], req_options)
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: 400, body: body}} when is_binary(body) ->
        handle_register_conflict(body, url, sid, payload, headers, req_options)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:system_register_failed, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp handle_register_conflict(body, url, sid, payload, headers, req_options) do
    if String.contains?(body, "already exists") do
      update_existing_system("#{url}/#{sid}", sid, payload, headers, req_options)
    else
      {:error, {:system_register_failed, 400, body}}
    end
  end

  defp update_existing_system(update_url, sid, payload, headers, req_options) do
    case Req.put(
           update_url,
           Keyword.merge([json: payload, headers: headers, receive_timeout: 15_000], req_options)
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        normalize_update_response(body, sid)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:system_update_failed, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp normalize_update_response(body, _sid) when is_map(body) and map_size(body) > 0 do
    {:ok, body}
  end

  defp normalize_update_response(_body, sid) do
    {:ok, %{"id" => sid, "oppdatert" => true}}
  end

  @doc """
  Creates a system user request for the organization.

  Returns `{:ok, %{id: uuid, status: "New", confirmUrl: url}}` or `{:error, reason}`.

  The user must go to confirmUrl and approve in the browser.

  ## Required options

    * `:name` — short lowercase system identifier (e.g. `"kontira"`)

  ## Optional options

    * `:env` — `"test"` or `"prod"` (default: `"prod"`)
    * `:features` — list of feature atoms to enable additional scopes (default: `[]`)
  """
  def opprett_forespoersel(maskinporten_token, vendor_orgnr, org_nummer, opts \\ []) do
    name = fetch_required!(opts, :name)
    env = Keyword.get(opts, :env, "prod")
    features = Keyword.get(opts, :features, [])
    req_options = Keyword.get(opts, :req_options, [])
    base = Map.fetch!(@bases, env)
    sid = system_id(vendor_orgnr, name)

    payload = %{
      "systemId" => sid,
      "partyOrgNo" => org_nummer,
      "integrationTitle" => name,
      "rights" => rights(features)
    }

    headers = [
      {"Authorization", "Bearer #{maskinporten_token}"},
      {"Content-Type", "application/json"}
    ]

    url = "#{base}/authentication/api/v1/systemuser/request/vendor"

    case Req.post(
           url,
           Keyword.merge([json: payload, headers: headers, receive_timeout: 15_000], req_options)
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:request_create_failed, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @doc """
  Gets the status of a system user request.

  Returns `{:ok, response_map}` or `{:error, reason}`.

  ## Optional options

    * `:env` — `"test"` or `"prod"` (default: `"prod"`)
  """
  def hent_forespoersel_status(maskinporten_token, request_id, opts \\ []) do
    env = Keyword.get(opts, :env, "prod")
    req_options = Keyword.get(opts, :req_options, [])
    base = Map.fetch!(@bases, env)

    headers = [{"Authorization", "Bearer #{maskinporten_token}"}]
    url = "#{base}/authentication/api/v1/systemuser/request/vendor/#{request_id}"

    case Req.get(
           url,
           Keyword.merge([headers: headers, receive_timeout: 15_000], req_options)
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:status_fetch_failed, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @doc """
  Gets all approved system users for the system.

  Returns `{:ok, [system_user_map]}` or `{:error, reason}`.

  ## Required options

    * `:name` — short lowercase system identifier (e.g. `"kontira"`)

  ## Optional options

    * `:env` — `"test"` or `"prod"` (default: `"prod"`)
  """
  def hent_systembrukere(maskinporten_token, vendor_orgnr, opts \\ []) do
    name = fetch_required!(opts, :name)
    env = Keyword.get(opts, :env, "prod")
    req_options = Keyword.get(opts, :req_options, [])
    base = Map.fetch!(@bases, env)
    sid = system_id(vendor_orgnr, name)

    headers = [{"Authorization", "Bearer #{maskinporten_token}"}]
    url = "#{base}/authentication/api/v1/systemuser/vendor/bysystem/#{sid}"

    case Req.get(
           url,
           Keyword.merge([headers: headers, receive_timeout: 15_000], req_options)
         ) do
      {:ok, %Req.Response{status: 200, body: body}} when is_list(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: 200, body: %{"data" => data}}} when is_list(data) ->
        {:ok, data}

      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:ok, Map.get(body, "data", [body])}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:users_fetch_failed, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @doc """
  Deletes (marks as deleted) a system from Altinn's system register.

  Returns `:ok` or `{:error, reason}`.

  ## Required options

    * `:name` — short lowercase system identifier (e.g. `"kontira"`)

  ## Optional options

    * `:env` — `"test"` or `"prod"` (default: `"prod"`)
  """
  def slett_system(maskinporten_token, vendor_orgnr, opts \\ []) do
    name = fetch_required!(opts, :name)
    env = Keyword.get(opts, :env, "prod")
    req_options = Keyword.get(opts, :req_options, [])
    base = Map.fetch!(@bases, env)
    sid = system_id(vendor_orgnr, name)

    headers = [{"Authorization", "Bearer #{maskinporten_token}"}]
    url = "#{base}/authentication/api/v1/systemregister/vendor/#{sid}"

    case Req.delete(
           url,
           Keyword.merge([headers: headers, receive_timeout: 15_000], req_options)
         ) do
      {:ok, %Req.Response{status: status}} when status in 200..204 ->
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:system_delete_failed, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp bygg_system_payload(vendor_orgnr, client_id, name, description, features) do
    sid = system_id(vendor_orgnr, name)

    %{
      "id" => sid,
      "vendor" => %{
        "authority" => "iso6523-actorid-upis",
        "ID" => "0192:#{vendor_orgnr}"
      },
      "name" => %{
        "nb" => name,
        "nn" => name,
        "en" => name
      },
      "description" => description,
      "clientId" => [client_id],
      "isVisible" => true,
      "rights" => rights(features)
    }
  end

  defp fetch_required!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when value != nil -> value
      _ -> raise ArgumentError, "required option :#{key} is missing"
    end
  end
end
