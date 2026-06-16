defmodule Wenche.MvaMelding do
  @moduledoc """
  MVA-melding (VAT return) submission to Skatteetaten via Altinn 3.

  Supports submitting and validating MVA-meldinger for Norwegian companies.

  ## Authentication

  Skatteetaten's MVA-melding API **only supports ID-porten** (end-user
  authentication). Maskinporten and system users are **not supported** —
  there is no Wenche helper to obtain a token here, and the systembruker
  flow cannot grant MVA rights.

  Callers must obtain an Altinn platform token themselves by:

  1. Authenticating the end user via ID-porten
  2. Exchanging the resulting token for an Altinn token

  The same Altinn token is used for both validation and submission. The
  scope tuples required from ID-porten are:

  - Validation: `openid skatteetaten:mvameldingvalidering`
  - Submission: `openid altinn:instances.read altinn:instances.write`

  (The deprecated `skatteetaten:mvameldinginnsending` scope is being phased
  out during 2026 and replaced by the two Altinn instance scopes above.)

  Pass the resulting Altinn token as `:token` to `valider/2` or via the
  `AltinnClient` for `send_inn/3`.

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
  > This module is **experimental and untested in production**.
  """

  alias Wenche.{AltinnClient, MvaMeldingXml, SubmissionResult}

  @validation_bases %{
    "test" => "https://idporten-api-test.sits.no/api/mva/grensesnittstoette/mva-melding/valider",
    "prod" =>
      "https://idporten.api.skatteetaten.no/api/mva/grensesnittstoette/mva-melding/valider"
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

  Returns `{:ok, %Wenche.SubmissionResult{}}` (carrying the submitted konvolutt
  and melding XML and the Altinn inbox URL) or `{:error, reason}`.
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
         {:ok, %{inbox_url: inbox_url, response: response}} <-
           AltinnClient.fullfoor_instans(client, "mva_melding", instans) do
      {:ok,
       %SubmissionResult{
         documents: [
           %{name: "konvolutt", content: konvolutt_xml},
           %{name: "melding", content: melding_xml}
         ],
         response: response,
         reference: inbox_url
       }}
    end
  end

  @doc """
  Validates an MVA-melding against Skatteetaten's validation API.

  ## Options

  - `:env` — `"test"` or `"prod"` (default: `"prod"`)
  - `:token` — Altinn/Maskinporten token for authentication
  - `:req_options` — additional options merged into `Req` calls (e.g. for test stubs)

  Skatteetaten's validation endpoint always responds with an XML
  `<valideringsresultat>` document — even when the melding is invalid the
  HTTP status is 200 and the payload describes the rule violations. This
  function parses that document into:

      %{
        avvik_ved_meldingslevering: "ok" | "ugyldig skattemelding" | "advarsel" | nil,
        avvik: [
          %{
            sti_til_avvik: String.t() | nil,
            mva_kode: String.t() | nil,
            begrunnelse: String.t() | nil,
            avvikstype: String.t() | nil,
            avvik_kode: String.t() | nil,
            regel_definisjon: String.t() | nil
          }
        ],
        raw_xml: String.t(),
        request_xml: String.t()
      }

  `raw_xml` is the validation response document; `request_xml` is the melding
  XML that was sent (useful for persisting an audit trail of the validation).

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
      {"accept", "application/xml"}
    ]

    case Req.post(
           base_url,
           Keyword.merge(
             [
               body: melding_xml,
               headers: headers,
               decode_body: false,
               receive_timeout: 30_000
             ],
             req_options
           )
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        result =
          body
          |> to_string()
          |> parse_valideringsresultat()
          |> Map.put(:request_xml, melding_xml)

        {:ok, result}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:valider_failed, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  # ── Validation response parsing ────────────────────────────────────
  #
  # The endpoint returns documents shaped like:
  #
  #     <valideringsresultat xmlns="...">
  #       <avvikVedMeldingslevering>ugyldig skattemelding</avvikVedMeldingslevering>
  #       <avvik>
  #         <stiTilAvvik>//meldingskategori</stiTilAvvik>
  #         <mvaKode>null</mvaKode>
  #         <avviksinformasjon>
  #           <begrunnelse>…</begrunnelse>
  #           <avvikstype>…</avvikstype>
  #           <avvikKode>…</avvikKode>
  #           <regelDefinisjon>…</regelDefinisjon>
  #         </avviksinformasjon>
  #       </avvik>
  #     </valideringsresultat>
  #
  # On a clean validation `<avvik>` blocks are absent.
  defp parse_valideringsresultat(xml) when is_binary(xml) do
    %{
      avvik_ved_meldingslevering: extract_text(xml, "avvikVedMeldingslevering"),
      avvik: extract_avvik(xml),
      raw_xml: xml
    }
  end

  defp extract_avvik(xml) do
    ~r{<(?:\w+:)?avvik>(.*?)</(?:\w+:)?avvik>}s
    |> Regex.scan(xml, capture: :all_but_first)
    |> Enum.map(fn [inner] ->
      %{
        sti_til_avvik: extract_text(inner, "stiTilAvvik"),
        mva_kode: extract_text(inner, "mvaKode"),
        begrunnelse: extract_text(inner, "begrunnelse"),
        avvikstype: extract_text(inner, "avvikstype"),
        avvik_kode: extract_text(inner, "avvikKode"),
        regel_definisjon: extract_text(inner, "regelDefinisjon")
      }
    end)
  end

  defp extract_text(xml, tag) do
    case Regex.run(~r{<(?:\w+:)?#{tag}>(.*?)</(?:\w+:)?#{tag}>}s, xml) do
      [_, value] -> value |> String.trim() |> unescape_entities()
      _ -> nil
    end
  end

  defp unescape_entities(s) do
    s
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&apos;", "'")
    |> String.replace("&amp;", "&")
  end
end
