defmodule Wenche.SkdSkattemeldingClient do
  @moduledoc """
  Skatteetaten API client for skattemeldingen (corporate tax return).

  Endpoints:
  - GET /{year}/{orgNr} — fetch pre-filled draft (contains `partsnummer`)
  - GET /utkast/{year}/{orgNr} — legacy alias for the pre-filled draft
  - POST /valider/{year}/{orgNr} — validate tax return XML

  Authentication uses a raw Maskinporten token (no Altinn exchange) with
  the `skatteetaten:formueinntekt/skattemelding` scope and systemuser
  authorization for the target organisation. See
  `Wenche.Maskinporten.get_skd_skattemelding_token/2`.
  """

  require Logger

  alias Wenche.SkattemeldingXml

  @forespoersel_response_ns "no:skatteetaten:fastsetting:formueinntekt:skattemeldingognaeringsspesifikasjon:forespoersel:response:v2"

  @bases %{
    "test" => "https://api-test.sits.no/api/skattemelding/v2",
    "prod" => "https://api.skatteetaten.no/api/skattemelding/v2"
  }

  defstruct [:base, :token, req_options: []]

  @type t :: %__MODULE__{
          base: String.t(),
          token: String.t(),
          req_options: keyword()
        }

  @doc """
  Creates a new SKD skattemelding client.

  ## Options

  - `:env` — `"test"` or `"prod"` (default: `"prod"`)
  - `:req_options` — extra options passed to `Req` (default: `[]`)
  """
  def new(token, opts \\ []) do
    env = Keyword.get(opts, :env, "prod")
    req_options = Keyword.get(opts, :req_options, [])

    base =
      Map.get(@bases, env) ||
        raise ArgumentError, "invalid env: #{inspect(env)}. Use \"prod\" or \"test\"."

    %__MODULE__{base: base, token: token, req_options: req_options}
  end

  @doc """
  Fetches the pre-filled tax return draft from Skatteetaten.

  Returns `{:ok, %{xml: xml, dokumentidentifikator: id}}` or `{:error, reason}`.
  """
  def hent_utkast(%__MODULE__{} = client, year, org_nr) do
    url = "#{client.base}/utkast/#{year}/#{org_nr}"

    case Req.get(
           url,
           Keyword.merge(
             [headers: headers(client.token), receive_timeout: 30_000],
             client.req_options
           )
         ) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {:ok, %{"content" => body}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:utkast_failed, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @doc """
  Validates a tax return XML against Skatteetaten's validation service.

  The `xml` should be the full `skattemeldingOgNaeringsspesifikasjonRequest` envelope.

  Returns `{:ok, validation_result}` or `{:error, reason}`.
  """
  def valider(%__MODULE__{} = client, year, org_nr, xml) do
    url = "#{client.base}/valider/#{year}/#{org_nr}"

    valider_headers = [
      {"authorization", "Bearer #{client.token}"},
      {"content-type", "application/xml;charset=UTF-8"},
      {"accept", "application/xml;charset=UTF-8"}
    ]

    case Req.post(
           url,
           Keyword.merge(
             [body: xml, headers: valider_headers, receive_timeout: 30_000],
             client.req_options
           )
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case parse_validation_result(body) do
          :ok -> {:ok, body}
          {:error, reason} -> {:error, {:validation_failed, reason, body}}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:valider_failed, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  # Skatteetaten's /valider returns HTTP 200 even when the document is rejected
  # semantically. The actual outcome lives in <resultatAvValidering> with values
  # `validertUtenFeil` (success) or `validertMedFeil` (failure). Treat the
  # latter as an error so callers don't silently proceed with a bad submission.
  defp parse_validation_result(body) when is_binary(body) do
    case Regex.run(
           ~r{<(?:\w+:)?resultatAvValidering>\s*([^<]+?)\s*</(?:\w+:)?resultatAvValidering>},
           body
         ) do
      [_, "validertUtenFeil"] ->
        :ok

      [_, "validertMedFeil"] ->
        reasons =
          Regex.scan(
            ~r{<(?:\w+:)?avvikstype>\s*([^<]+?)\s*</(?:\w+:)?avvikstype>},
            body
          )
          |> Enum.map(fn [_, code] -> String.trim(code) end)

        {:error, {:validert_med_feil, reasons}}

      _ ->
        # Body doesn't contain the expected element — treat as success and let
        # the caller inspect the body. Avoids false negatives on responses we
        # don't fully model.
        :ok
    end
  end

  defp parse_validation_result(_), do: :ok

  @doc """
  Fetches the pre-filled skattemelding XML from Skatteetaten.

  Calls `GET /{year}/{orgNr}` with `Accept: application/xml`. If the response is
  wrapped in a `forespoerselResponse` envelope with base64-encoded `<content>`,
  the wrapper is unpacked and the inner XML returned.

  Returns `{:ok, inner_xml :: binary}` or `{:error, reason}`.
  """
  def hent_forhandsutfylt(%__MODULE__{} = client, year, org_nr) do
    url = "#{client.base}/#{year}/#{org_nr}"

    request_headers = [
      {"authorization", "Bearer #{client.token}"},
      {"accept", "application/xml"}
    ]

    case Req.get(
           url,
           Keyword.merge(
             [headers: request_headers, receive_timeout: 30_000],
             client.req_options
           )
         ) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {:ok, maybe_unwrap_forespoersel(body)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:utkast_failed, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @doc """
  Fetches and extracts the company's `partsnummer` from Skatteetaten.

  Convenience wrapper around `hent_forhandsutfylt/3` + `SkattemeldingXml.hent_partsnummer/1`.

  Returns `{:ok, integer}` or `{:error, reason}`.
  """
  def hent_partsnummer(%__MODULE__{} = client, year, org_nr) do
    with {:ok, xml} <- hent_forhandsutfylt(client, year, org_nr) do
      SkattemeldingXml.hent_partsnummer(xml)
    end
  end

  @doc """
  Fetches the pre-filled draft AND the document identifiers that the request
  envelope must reference back via `<dokumentreferanseTilGjeldendeDokument>`.

  Skatteetaten's `/valider` and `/innsendelse` endpoints both reject a request
  envelope that lacks a reference to the current draft, with the error
  `innkommendeForespoerselManglerReferanseTilGjeldendeSkattemelding`.

  Returns `{:ok, %{partsnummer: integer, skattemelding_id: binary,
  naering_id: binary | nil}}` or `{:error, reason}`.

  - `partsnummer` — Skatteetaten's internal integer ID for the company,
    extracted from the inner skattemelding XML.
  - `skattemelding_id` — `<id>` of `<skattemeldingdokument>` in the response
    wrapper; goes into `<dokumentreferanseTilGjeldendeDokument>` with type
    `skattemeldingUpersonlig`.
  - `naering_id` — `<id>` of `<naeringsspesifikasjondokument>` (optional in
    the schema; may be nil if not present).
  """
  def hent_utkast_referanse(%__MODULE__{} = client, year, org_nr) do
    do_hent_utkast_referanse(client, year, org_nr, &SkattemeldingXml.hent_partsnummer/1)
  end

  @doc """
  Personlig (ENK) analogue of `hent_utkast_referanse/3`.

  Identical flow, but the taxpayer ID is read from the inner document's
  `<partsreferanse>` (personlig) rather than `<partsnummer>` (upersonlig). The
  returned `:partsnummer` key carries the resolved partsreferanse so callers can
  treat both flows uniformly.

  Returns `{:ok, %{partsnummer: integer, skattemelding_id: binary | nil,
  naering_id: binary | nil}}` or `{:error, reason}`.
  """
  def hent_utkast_referanse_personlig(%__MODULE__{} = client, year, org_nr) do
    do_hent_utkast_referanse(
      client,
      year,
      org_nr,
      &Wenche.SkattemeldingPersonligXml.hent_partsreferanse/1
    )
  end

  defp do_hent_utkast_referanse(%__MODULE__{} = client, year, org_nr, partsid_fun) do
    url = "#{client.base}/#{year}/#{org_nr}"

    request_headers = [
      {"authorization", "Bearer #{client.token}"},
      {"accept", "application/xml"}
    ]

    with {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) <-
           Req.get(
             url,
             Keyword.merge(
               [headers: request_headers, receive_timeout: 30_000],
               client.req_options
             )
           ),
         %{xml: inner_xml, skattemelding_id: sm_id, naering_id: ne_id} <-
           parse_forespoersel_response(body),
         {:ok, partsnummer} <- partsid_fun.(inner_xml) do
      # Logged at :info to inspect what Skatteetaten pre-fills (e.g. whether the
      # draft carries fremfoerbarNegativPersoninntektFraTidligereAar). Keyed on
      # the year only — for the personlig flow `org_nr` is the owner's fnr, which
      # is never logged. The body carries `partsreferanse` for correlation.
      Logger.info("Skattemelding utkast (draft) response for #{year}:\n#{inner_xml}")

      {:ok, %{partsnummer: partsnummer, skattemelding_id: sm_id, naering_id: ne_id}}
    else
      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:utkast_failed, status, body}}

      {:error, _} = err ->
        err

      :error ->
        {:error, :utkast_unparseable}

      other when is_binary(other) ->
        # parse returned just XML (no wrapper) → no dokumentidentifikator
        case partsid_fun.(other) do
          {:ok, partsnummer} ->
            {:ok, %{partsnummer: partsnummer, skattemelding_id: nil, naering_id: nil}}

          err ->
            err
        end
    end
  end

  defp parse_forespoersel_response(body) do
    if String.contains?(body, @forespoersel_response_ns) do
      parse_wrapper(body)
    else
      # raw inner XML without wrapper
      body
    end
  end

  defp parse_wrapper(body) do
    sm_id = extract_skattemelding_id(body)
    ne_id = extract_naering_id(body)

    with b64 when not is_nil(b64) <- extract_content_b64(body),
         xml when not is_nil(xml) <- decode_b64(b64) do
      %{xml: xml, skattemelding_id: sm_id, naering_id: ne_id}
    else
      _ -> :error
    end
  end

  defp extract_skattemelding_id(body) do
    # <skattemeldingdokument>...<id>...</id>...
    case Regex.run(
           ~r{<(?:\w+:)?skattemeldingdokument\b[^>]*>.*?<(?:\w+:)?id>\s*([^<]+?)\s*</(?:\w+:)?id>}s,
           body
         ) do
      [_, id] -> String.trim(id)
      _ -> nil
    end
  end

  defp extract_naering_id(body) do
    case Regex.run(
           ~r{<(?:\w+:)?naeringsspesifikasjondokument\b[^>]*>.*?<(?:\w+:)?id>\s*([^<]+?)\s*</(?:\w+:)?id>}s,
           body
         ) do
      [_, id] -> String.trim(id)
      _ -> nil
    end
  end

  defp extract_content_b64(body) do
    case Regex.run(
           ~r{<(?:\w+:)?content[^>]*>\s*([A-Za-z0-9+/=\s]+)\s*</(?:\w+:)?content>},
           body
         ) do
      [_, b64] -> b64
      _ -> nil
    end
  end

  defp maybe_unwrap_forespoersel(xml) do
    case Regex.run(~r{<(?:\w+:)?content[^>]*>\s*([A-Za-z0-9+/=\s]+)\s*</(?:\w+:)?content>}, xml) do
      [_, b64] when is_binary(b64) ->
        if String.contains?(xml, @forespoersel_response_ns) do
          decode_b64(b64) || xml
        else
          xml
        end

      _ ->
        xml
    end
  end

  defp decode_b64(b64) do
    case Base.decode64(String.replace(b64, ~r/\s+/, ""), ignore: :whitespace) do
      {:ok, decoded} -> decoded
      :error -> nil
    end
  end

  defp headers(token) do
    [
      {"authorization", "Bearer #{token}"},
      {"accept", "application/json"}
    ]
  end
end
