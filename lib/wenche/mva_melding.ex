defmodule Wenche.MvaMelding do
  @moduledoc """
  MVA-melding (VAT return) submission to Skatteetaten via Altinn 3.

  Supports submitting and validating MVA-meldinger for Norwegian companies.

  ## MVA Data

  The `mva_data` parameter is a map with these keys:

  - `:org_nummer` — organization number (string)
  - `:termin` — bi-monthly period 1-6
  - `:year` — tax year (integer)
  - `:linjer` — list of `%{mva_kode: integer, grunnlag: number, sats: number, merverdiavgift: number}`
  - `:fastsatt_merverdiavgift` — total MVA to pay (negative = refund)
  - `:system_name` — name of submitting system (default "Kontira")

  > #### Experimental {: .warning}
  >
  > This module is **experimental and untested in production**. The MVA-melding
  > scope (`app_skd_mva-melding-innsending-v1`) is not included in the default
  > system user rights — you must explicitly opt in via
  > `Wenche.Systembruker.rights([:mva_melding])`.
  """

  alias Wenche.{AltinnClient, MvaMeldingXml}

  @validation_bases %{
    "test" => "https://skatt-utv3.sits.no/api/mva/mva-melding/valider",
    "prod" => "https://api.sits.no/api/mva/mva-melding/valider"
  }

  @doc """
  Submits an MVA-melding to Skatteetaten via Altinn 3.

  Mirrors the Skatteetaten reference flow documented at
  https://skatteetaten.github.io/mva-meldingen/english/implementationguide/
  (sequence diagram in github.com/Skatteetaten/mva-meldingen,
  `docs/documentation/api/Mva-Melding-Innsending-Sekvensdiagram.txt`):

  1. Generate konvolutt (envelope) and melding XML
  2. `POST /instances`                            — create Altinn instance
  3. `PUT  /data/{guid}` (`mvaMeldingInnsending`) — upload konvolutt
  4. `POST /data?dataType=mvamelding`             — upload melding
  5. `PUT  /process/next`  ("Fullfør Utfylling")  — utfylling   → bekreftelse
  6. `PUT  /process/next`  ("Fullfør Innsending") — bekreftelse → tilbakemelding

  Both `process/next` calls return 200; the second one's response is what
  Skatteetaten's `betalingsinformasjon.xml` is generated from. We use
  `fullfoor_instans/3` for both because Skatteetaten labels both transitions
  as "Fullfør" steps in their documentation — `neste_prosesssteg/3` would
  work identically (same endpoint, same accepted status codes for this app).

  To inspect the generated XML without submitting, call
  `Wenche.MvaMeldingXml.generer_konvolutt_xml/1` and
  `Wenche.MvaMeldingXml.generer_melding_xml/1` directly.

  Returns `{:ok, inbox_url}` or `{:error, reason}`.
  """
  def send_inn(mva_data, %AltinnClient{} = client, _opts \\ []) do
    org = mva_data.org_nummer

    konvolutt_xml = MvaMeldingXml.generer_konvolutt_xml(mva_data)
    melding_xml = MvaMeldingXml.generer_melding_xml(mva_data)

    with {:ok, instans} <- AltinnClient.opprett_instans(client, "mva_melding", org),
         {:ok, _} <-
           AltinnClient.oppdater_data_element(
             client,
             "mva_melding",
             instans,
             "no.skatteetaten.fastsetting.avgift.mva.mvameldinginnsending.v1.0",
             konvolutt_xml,
             "application/xml"
           ),
         {:ok, _} <-
           AltinnClient.legg_til_data_element(
             client,
             "mva_melding",
             instans,
             "no.skatteetaten.fastsetting.avgift.mva.skattemeldingformerverdiavgift.v1.0",
             melding_xml,
             "application/xml"
           ),
         {:ok, _} <- AltinnClient.fullfoor_instans(client, "mva_melding", instans),
         {:ok, inbox_url} <- AltinnClient.fullfoor_instans(client, "mva_melding", instans) do
      {:ok, inbox_url}
    end
  end

  @doc """
  Validates an MVA-melding against Skatteetaten's validation API.

  ## Options

  - `:env` — `"test"` or `"prod"` (default: `"prod"`)
  - `:token` — Altinn/Maskinporten token for authentication
  - `:req_options` — additional options merged into `Req` calls (e.g. for test stubs)

  Returns `{:ok, validation_result}` or `{:error, reason}`.
  """
  def valider(mva_data, opts \\ []) do
    env = Keyword.get(opts, :env, "prod")
    token = Keyword.fetch!(opts, :token)
    req_options = Keyword.get(opts, :req_options, [])

    base_url =
      Map.get(@validation_bases, env) ||
        raise ArgumentError, "invalid env: #{inspect(env)}. Use \"prod\" or \"test\"."

    melding_xml = MvaMeldingXml.generer_melding_xml(mva_data)

    headers = [
      {"content-type", "application/xml"},
      {"authorization", "Bearer #{token}"},
      {"accept", "application/json"}
    ]

    case Req.post(
           base_url,
           Keyword.merge(
             [body: melding_xml, headers: headers, receive_timeout: 30_000],
             req_options
           )
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:valider_failed, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end
end
