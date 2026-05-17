defmodule Wenche.AltinnClient do
  @moduledoc """
  Altinn 3 API client for creating instances, uploading data, and completing submissions.

  Ported from `wenche/altinn_client.py` in the original Python Wenche project.

  Handles instance creation, data submission, and completion for all three
  submission types: annual accounts, tax return, and shareholder register.
  """

  @bases %{
    "test" => %{
      platform: "https://platform.tt02.altinn.no",
      apps: "https://{org}.apps.tt02.altinn.no",
      web: "https://tt02.altinn.no",
      inbox: "https://af.tt02.altinn.no/inbox"
    },
    "prod" => %{
      platform: "https://platform.altinn.no",
      apps: "https://{org}.apps.altinn.no",
      web: "https://altinn.no",
      inbox: "https://af.altinn.no/inbox"
    }
  }

  # Altinn 3 apps for each submission type
  @apps %{
    "aarsregnskap" => %{org: "brg", app: "aarsregnskap-vanlig-202406"},
    "aksjonaerregister" => %{org: "skd", app: "a2-1051-241111"},
    "skattemelding" => %{org: "skd", app: "formueinntekt-skattemelding-v2"},
    "mva_melding" => %{org: "skd", app: "mva-melding-innsending-v1"}
  }

  defstruct [:token, :env, :apps_base, :inbox_url, req_options: []]

  @type t :: %__MODULE__{
          token: String.t(),
          env: String.t(),
          apps_base: String.t(),
          inbox_url: String.t(),
          req_options: keyword()
        }

  @doc """
  Creates a new AltinnClient with the given token and environment.

  ## Options

  - `:env` — `"test"` or `"prod"` (default: `"prod"`)
  - `:req_options` — extra options passed to `Req` (default: `[]`)
  """
  def new(altinn_token, opts \\ []) do
    env = Keyword.get(opts, :env, "prod")
    req_options = Keyword.get(opts, :req_options, [])

    unless Map.has_key?(@bases, env) do
      raise ArgumentError, "Invalid env: #{inspect(env)}. Use 'prod' or 'test'."
    end

    base = Map.fetch!(@bases, env)

    %__MODULE__{
      token: altinn_token,
      env: env,
      apps_base: base.apps,
      inbox_url: base.inbox,
      req_options: req_options
    }
  end

  @doc """
  Creates a new instance for the given submission type and organization.

  ## App keys

  - `"aarsregnskap"` — Annual accounts (BRG)
  - `"aksjonaerregister"` — Shareholder register (SKD)
  - `"skattemelding"` — Tax return (SKD)

  Returns `{:ok, instance_map}` or `{:error, reason}`.
  """
  def opprett_instans(%__MODULE__{} = client, app_key, org_nummer) do
    url = "#{app_base(client, app_key)}/instances"

    body = %{
      "instanceOwner" => %{"organisationNumber" => org_nummer}
    }

    case Req.post(
           url,
           Keyword.merge(
             [json: body, headers: auth_headers(client.token), receive_timeout: 30_000],
             client.req_options
           )
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in [200, 201] ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:altinn_create_instance_error, status, body}}

      {:error, reason} ->
        {:error, {:altinn_request_failed, reason}}
    end
  end

  @doc """
  Updates an existing data element in the instance with PUT.

  Altinn creates data elements automatically upon instance creation;
  we find the correct element via dataType and replace its contents.

  Returns `{:ok, response_body}` or `{:error, reason}`.
  """
  def oppdater_data_element(
        %__MODULE__{} = client,
        app_key,
        instans,
        data_type,
        data,
        content_type
      ) do
    instance_id = instans["id"]

    case finn_data_element_id(instans, data_type) do
      {:ok, element_id} ->
        url = "#{app_base(client, app_key)}/instances/#{instance_id}/data/#{element_id}"

        headers = [{"content-type", content_type} | auth_headers(client.token)]

        case Req.put(
               url,
               Keyword.merge(
                 [body: data, headers: headers, receive_timeout: 30_000],
                 client.req_options
               )
             ) do
          {:ok, %Req.Response{status: status, body: body}} when status in [200, 201] ->
            {:ok, body}

          {:ok, %Req.Response{status: status, body: body}} ->
            {:error, {:altinn_upload_error, status, body}}

          {:error, reason} ->
            {:error, {:altinn_request_failed, reason}}
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Adds a new data element to an instance with POST.

  Unlike `oppdater_data_element/6` which updates an existing element,
  this creates a new data element on the instance.

  Returns `{:ok, response_body}` or `{:error, reason}`.
  """
  def legg_til_data_element(
        %__MODULE__{} = client,
        app_key,
        instans,
        data_type,
        data,
        content_type
      ) do
    instance_id = instans["id"]
    url = "#{app_base(client, app_key)}/instances/#{instance_id}/data?dataType=#{data_type}"

    headers = [{"content-type", content_type} | auth_headers(client.token)]

    case Req.post(url,
           body: data,
           headers: headers,
           receive_timeout: 30_000
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in [200, 201] ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:altinn_upload_error, status, body}}

      {:error, reason} ->
        {:error, {:altinn_request_failed, reason}}
    end
  end

  @doc """
  Uploads the skattemelding envelope (skattemeldingOgNaeringsspesifikasjon)
  as a new data element on the instance.

  The SKD `formueinntekt-skattemelding-v2` app expects:

    - POST (not PUT) to `/instances/{id}/data?dataType=skattemeldingOgNaeringsspesifikasjon`
    - `Content-Type: text/xml`
    - `Content-Disposition: attachment; filename=skattemelding.xml` — no quotes
      around the filename; the app's parser is sensitive to this.

  Returns `{:ok, response_body}` or `{:error, reason}`.
  """
  def last_opp_skattemelding_konvolutt(%__MODULE__{} = client, instans, konvolutt) do
    instance_id = instans["id"]

    url =
      "#{app_base(client, "skattemelding")}/instances/#{instance_id}" <>
        "/data?dataType=skattemeldingOgNaeringsspesifikasjon"

    headers = [
      {"content-type", "text/xml"},
      {"content-disposition", "attachment; filename=skattemelding.xml"}
      | auth_headers(client.token)
    ]

    case Req.post(
           url,
           Keyword.merge(
             [body: konvolutt, headers: headers, receive_timeout: 30_000],
             client.req_options
           )
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in [200, 201] ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:altinn_upload_error, status, body}}

      {:error, reason} ->
        {:error, {:altinn_request_failed, reason}}
    end
  end

  @doc """
  Advances the instance one process step (`PUT /process/next`) without
  returning the inbox URL. Use `fullfoor_instans/3` for the final step.

  Returns `{:ok, response_body}` or `{:error, reason}`.
  """
  def neste_prosesssteg(%__MODULE__{} = client, app_key, instans) do
    instance_id = instans["id"]
    url = "#{app_base(client, app_key)}/instances/#{instance_id}/process/next"

    case Req.put(
           url,
           Keyword.merge(
             [headers: auth_headers(client.token), receive_timeout: 30_000],
             client.req_options
           )
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in [200, 201] ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:altinn_process_error, status, body}}

      {:error, reason} ->
        {:error, {:altinn_request_failed, reason}}
    end
  end

  @doc """
  Advances the instance to the signing step and returns the Altinn inbox URL
  where the user can sign with BankID/ID-Porten.

  Signing requires ID-Porten and cannot be done programmatically.

  Returns `{:ok, inbox_url}` or `{:error, reason}`.
  """
  def fullfoor_instans(%__MODULE__{} = client, app_key, instans) do
    instance_id = instans["id"]
    url = "#{app_base(client, app_key)}/instances/#{instance_id}/process/next"

    case Req.put(
           url,
           Keyword.merge(
             [headers: auth_headers(client.token), receive_timeout: 30_000],
             client.req_options
           )
         ) do
      {:ok, %Req.Response{status: 200}} ->
        {:ok, client.inbox_url}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:altinn_complete_error, status, body}}

      {:error, reason} ->
        {:error, {:altinn_request_failed, reason}}
    end
  end

  @doc """
  Gets the current status of an instance.

  Returns `{:ok, response_body}` or `{:error, reason}`.
  """
  def hent_status(%__MODULE__{} = client, app_key, instans) do
    instance_id = instans["id"]
    url = "#{app_base(client, app_key)}/instances/#{instance_id}"

    case Req.get(
           url,
           Keyword.merge(
             [headers: auth_headers(client.token), receive_timeout: 30_000],
             client.req_options
           )
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:altinn_status_error, status, body}}

      {:error, reason} ->
        {:error, {:altinn_request_failed, reason}}
    end
  end

  # ── Token-based convenience API ─────────────────────────────────────
  #
  # The functions above take an `%AltinnClient{}` struct and are used by
  # Wenche's own submission flows (Aarsregnskap, Skattemelding, MvaMelding).
  # The functions below take a raw Altinn token + app_id directly, and are
  # the preferred surface for application callers that want to drive the
  # Altinn 3 instance lifecycle themselves without constructing a client
  # struct. Both APIs are first-class; pick whichever shape fits the caller.

  @doc """
  Creates a new Altinn 3 app instance.

  Returns `{:ok, instance_body}` or `{:error, reason}`.
  """
  def create_instance(altinn_token, org_number, app_id, opts \\ []) do
    env = Keyword.get(opts, :env, "test")
    req_opts = Keyword.get(opts, :req_options, [])
    url = "#{storage_url(env)}/#{app_id}/instances"

    body = %{
      "instanceOwner" => %{"organisationNumber" => org_number}
    }

    req_opts =
      Keyword.merge(req_opts,
        json: body,
        headers: auth_headers(altinn_token),
        receive_timeout: 30_000
      )

    case Req.post(url, req_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in [200, 201] ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:altinn_create_instance_error, status, body}}

      {:error, reason} ->
        {:error, {:altinn_request_failed, reason}}
    end
  end

  @doc """
  Uploads/updates a data element on an existing instance.

  Returns `{:ok, response_body}` or `{:error, reason}`.
  """
  def update_data_element(
        altinn_token,
        instance_id,
        app_id,
        data_type,
        content_type,
        data,
        opts \\ []
      ) do
    env = Keyword.get(opts, :env, "test")
    req_opts = Keyword.get(opts, :req_options, [])
    url = "#{storage_url(env)}/#{app_id}/instances/#{instance_id}/data?dataType=#{data_type}"

    headers = [{"content-type", content_type} | auth_headers(altinn_token)]

    req_opts =
      Keyword.merge(req_opts,
        body: data,
        headers: headers,
        receive_timeout: 30_000
      )

    case Req.post(url, req_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in [200, 201] ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:altinn_upload_error, status, body}}

      {:error, reason} ->
        {:error, {:altinn_request_failed, reason}}
    end
  end

  @doc """
  Moves the instance to the next process step.

  Returns `{:ok, response_body}` or `{:error, reason}`.
  """
  def complete_instance(altinn_token, instance_id, app_id, opts \\ []) do
    env = Keyword.get(opts, :env, "test")
    req_opts = Keyword.get(opts, :req_options, [])
    url = "#{storage_url(env)}/#{app_id}/instances/#{instance_id}/process/next"

    req_opts =
      Keyword.merge(req_opts,
        headers: auth_headers(altinn_token),
        receive_timeout: 30_000
      )

    case Req.put(url, req_opts) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:altinn_complete_error, status, body}}

      {:error, reason} ->
        {:error, {:altinn_request_failed, reason}}
    end
  end

  @doc """
  Gets the current status of an instance.

  Returns `{:ok, response_body}` or `{:error, reason}`.
  """
  def get_status(altinn_token, instance_id, app_id, opts \\ []) do
    env = Keyword.get(opts, :env, "test")
    req_opts = Keyword.get(opts, :req_options, [])
    url = "#{storage_url(env)}/#{app_id}/instances/#{instance_id}"

    req_opts =
      Keyword.merge(req_opts,
        headers: auth_headers(altinn_token),
        receive_timeout: 30_000
      )

    case Req.get(url, req_opts) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:altinn_status_error, status, body}}

      {:error, reason} ->
        {:error, {:altinn_request_failed, reason}}
    end
  end

  # Private helpers

  defp app_base(%__MODULE__{} = client, app_key) do
    cfg = Map.fetch!(@apps, app_key)
    String.replace(client.apps_base, "{org}", cfg.org) <> "/#{cfg.org}/#{cfg.app}"
  end

  defp finn_data_element_id(instans, data_type) do
    data = instans["data"] || []

    case Enum.find(data, fn el -> el["dataType"] == data_type end) do
      nil ->
        available = Enum.map(data, fn el -> el["dataType"] end)

        {:error,
         "Fant ikke data-element med dataType='#{data_type}' i instansen. " <>
           "Tilgjengelige typer: #{inspect(available)}"}

      element ->
        {:ok, element["id"]}
    end
  end

  defp storage_url(env) do
    base = Map.fetch!(@bases, env)
    "#{base.platform}/storage/api/v1"
  end

  defp auth_headers(token) do
    [
      {"authorization", "Bearer #{token}"},
      {"accept", "application/json"}
    ]
  end
end
