defmodule Wenche.SkattemeldingXml do
  @moduledoc """
  XML generation for skattemelding (corporate tax return) submission to Skatteetaten.

  Generates three XML documents:

  1. `skattemeldingUpersonlig` (v5) — minimal: `partsnummer`, `inntektsaar`, and
     optionally `inntektOgUnderskudd/underskuddTilFremfoering/fremfoertUnderskuddFraTidligereAar`.
     Other fields (income, formue, deductions) are derived by Skatteetaten from the
     næringsspesifikasjon. Per `skattemeldingUpersonlig_v5_ekstern.xsd`.

  2. `naeringsspesifikasjon` (v6) — resultatregnskap, balanseregnskap, virksomhet,
     `skalBekreftesAvRevisor`. Sum/derived fields (`erAvledet="true"`) are computed
     by Skatteetaten and not emitted. Per `naeringsspesifikasjon_v6_ekstern.xsd`.

  3. `skattemeldingOgNaeringsspesifikasjonRequest` (v2) — envelope wrapping both
     inner documents base64-encoded. Per `skattemeldingognaeringsspesifikasjonrequest_v2.xsd`.

  Ported from `wenche/skattemelding_xml.py`, `wenche/naeringsspesifikasjon_xml.py`,
  and `wenche/skattemelding_konvolutt.py` in the Python Wenche project.

  ## Partsnummer

  `partsnummer` (and `partsreferanse` in næringsspesifikasjon) is Skatteetaten's
  internal integer ID for the company. It must be fetched from the pre-filled
  draft API (`GET /api/skattemelding/v2/{år}/{orgnr}`) before generating the
  XML for actual submission.

  When called without `:partsnummer` in opts, the generators fall back to
  `aarsregnskap.selskap.org_nummer` as a placeholder. This passes XSD
  validation (org_nummer fits `xsd:long`) but Skatteetaten will reject the
  actual submission unless replaced with the real partsnummer.
  """

  alias Wenche.Models.{
    Aarsregnskap,
    KortsiktigGjeld,
    LangsiktigGjeld
  }

  @skattemelding_ns "urn:no:skatteetaten:fastsetting:formueinntekt:skattemelding:upersonlig:ekstern:v5"
  @naering_ns "urn:no:skatteetaten:fastsetting:formueinntekt:naeringsspesifikasjon:ekstern:v6"
  @request_ns "no:skatteetaten:fastsetting:formueinntekt:skattemeldingognaeringsspesifikasjon:request:v2"

  @opprettet_av "Wenche"

  # Resultatregnskap kodeliste codes (2025_resultatregnskapOgBalanse.xml)
  @kode_salgsinntekt "3200"
  @kode_andre_driftsinntekter "3900"
  @kode_loennskostnad "5000"
  @kode_avskrivninger "6000"
  @kode_andre_driftskostnader "6700"
  @kode_utbytte_datterselskap "8090"
  @kode_andre_finansinntekter "8050"
  @kode_rentekostnader "8150"
  @kode_andre_finanskostnader "8160"

  # Balanseregnskap kodeliste codes
  @kode_aksjer_datterselskap "1313"
  @kode_andre_aksjer "1350"
  @kode_langsiktige_fordringer "1390"
  @kode_kortsiktige_fordringer "1500"
  @kode_bankinnskudd "1920"
  @kode_aksjekapital "2000"
  @kode_overkursfond "2020"
  @kode_annen_egenkapital "2050"
  @kode_udekket_tap "2080"
  @kode_laan_aksjonaer "2250"
  @kode_andre_langsiktige_laan "2290"
  @kode_leverandoergjeld "2400"
  @kode_offentlige_avgifter "2600"
  @kode_annen_kortsiktig_gjeld "2990"

  # ── skattemeldingUpersonlig (v5) ────────────────────────────────────

  @doc """
  Generates the `skattemeldingUpersonlig` XML document (v5).

  ## Options

  - `:partsnummer` — Skatteetaten's integer ID for the company. Defaults to
    `aarsregnskap.selskap.org_nummer`.
  - `:fremfoert_underskudd` — loss carryforward from prior years (integer kroner).
    Defaults to `konfig.underskudd_til_fremfoering`. Element is emitted only
    when value is > 0.
  - `:aksjespesifikasjon` — list of holding maps emitted as
    `<spesifikasjonAvForholdRelevanteForBeskatning>`. See
    `generer_spesifikasjon_av_forhold_relevante_for_beskatning/1` for the
    expected map shape. Required for SKD to apply fritaksmetoden to dividends
    and gains on aksje/verdipapir holdings — without it, SKD taxes the full
    income.
  - `konfig.formuesverdi_aksjer` — summed formuesverdi of share/fund
    holdings. When present, emits `<formueOgGjeld>` with XSD-backed
    overstyring fields so SKD can derive value behind the company's shares.
  - `konfig.samlet_verdi_bak_aksjene` — explicit net value behind the shares.
    When present, this override takes precedence over `:formuesverdi_aksjer`.
  """
  def generer_skattemelding_xml(%Aarsregnskap{} = regnskap, konfig, opts \\ []) do
    partsnummer = Keyword.get(opts, :partsnummer, regnskap.selskap.org_nummer)
    aar = regnskap.regnskapsaar

    fremfoert =
      Keyword.get(
        opts,
        :fremfoert_underskudd,
        Map.get(konfig || %{}, :underskudd_til_fremfoering, 0)
      )

    pf_entries =
      Keyword.get(
        opts,
        :permanent_forskjeller,
        Map.get(konfig || %{}, :permanent_forskjeller, [])
      )
      |> List.wrap()

    skattepliktig_brutto = Wenche.Skattemelding.derive_skattepliktig_brutto(regnskap, pf_entries)
    aarets_underskudd = max(-skattepliktig_brutto, 0)
    inntekt_foer_fradrag = skattepliktig_brutto
    fremfoerbart = fremfoert + aarets_underskudd

    inntekt_og_underskudd =
      inntekt_og_underskudd_block(
        fremfoert,
        fremfoerbart,
        aarets_underskudd,
        inntekt_foer_fradrag
      )

    aksjespesifikasjon =
      opts
      |> Keyword.get(:aksjespesifikasjon, [])
      |> generer_spesifikasjon_av_forhold_relevante_for_beskatning()

    formue_og_gjeld = formue_og_gjeld_block(regnskap, konfig)
    opplysning_om_skattesubjekt = opplysning_om_skattesubjekt_block(konfig)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <skattemelding xmlns="#{@skattemelding_ns}">
      <partsnummer>#{partsnummer}</partsnummer>
      <inntektsaar>#{aar}</inntektsaar>
    #{inntekt_og_underskudd}
    #{aksjespesifikasjon}
    #{formue_og_gjeld}
    #{opplysning_om_skattesubjekt}
    </skattemelding>
    """
    |> String.trim()
    |> remove_blank_lines()
  end

  @doc """
  Calculates `{samletVerdiFoerEventuellVerdsettingsrabatt, samletGjeld}` for
  `<formueOgGjeld>`.

  `samlet_verdi_bak_aksjene` is treated as an explicit net override and takes
  precedence. Otherwise, `formuesverdi_aksjer` replaces the book value of
  share/fund holdings while bank deposits and receivables are included at face
  value. Returns `{nil, nil}` when no valuation input is present.
  """
  def beregn_formue_inputs(%Aarsregnskap{} = regnskap, konfig) do
    b = regnskap.balanse

    samlet_gjeld =
      LangsiktigGjeld.sum(b.egenkapital_og_gjeld.langsiktig_gjeld) +
        KortsiktigGjeld.sum(b.egenkapital_og_gjeld.kortsiktig_gjeld)

    cond do
      not is_nil(Map.get(konfig || %{}, :samlet_verdi_bak_aksjene)) ->
        netto =
          konfig
          |> Map.get(:samlet_verdi_bak_aksjene)
          |> beloep_to_int(:half_up)
          |> max(0)

        {netto + samlet_gjeld, samlet_gjeld}

      is_nil(Map.get(konfig || %{}, :formuesverdi_aksjer)) ->
        {nil, nil}

      true ->
        formuesverdi_aksjer =
          konfig
          |> Map.get(:formuesverdi_aksjer)
          |> beloep_to_int(:half_up)

        verdi_foer_rabatt =
          formuesverdi_aksjer +
            b.eiendeler.omloepmidler.bankinnskudd +
            b.eiendeler.omloepmidler.kortsiktige_fordringer +
            b.eiendeler.anleggsmidler.langsiktige_fordringer

        {verdi_foer_rabatt, samlet_gjeld}
    end
  end

  @doc """
  Returns net value behind the shares, floored at zero, for display/control.
  """
  def beregn_verdi_bak_aksjene(%Aarsregnskap{} = regnskap, konfig) do
    case beregn_formue_inputs(regnskap, konfig) do
      {nil, _} -> nil
      {foer_rabatt, gjeld} -> max(0, foer_rabatt - (gjeld || 0))
    end
  end

  defp formue_og_gjeld_block(regnskap, konfig) do
    case beregn_formue_inputs(regnskap, konfig) do
      {nil, _} ->
        ""

      {verdi_foer_rabatt, samlet_gjeld} ->
        """
          <formueOgGjeld>
            #{overstyrt_heltall("samletVerdiFoerEventuellVerdsettingsrabatt", verdi_foer_rabatt)}
            #{overstyrt_heltall("samletGjeld", samlet_gjeld || 0)}
          </formueOgGjeld>
        """
        |> String.trim_trailing()
    end
  end

  defp egenkapitalavstemming_block(%{utgaaende_ek: 0, inngaaende_ek: 0, endringer: []}), do: ""

  defp egenkapitalavstemming_block(%{} = avstemming) do
    endringer =
      avstemming.endringer
      |> Enum.map(fn e ->
        """
            <egenkapitalendring>
              <id>#{e.id}</id>
              <egenkapitalendringstype>
                <egenkapitalendringstype>#{e.type}</egenkapitalendringstype>
              </egenkapitalendringstype>
              #{beloep_med_skattemessige("beloep", e.beloep)}
            </egenkapitalendring>
        """
        |> String.trim_trailing()
      end)
      |> Enum.join("\n")

    """
      <egenkapitalavstemming>
        #{beloep_med_skattemessige("inngaaendeEgenkapital", avstemming.inngaaende_ek)}
        #{beloep_med_skattemessige("sumTilleggIEgenkapital", avstemming.sum_tillegg)}
        #{beloep_med_skattemessige("sumFradragIEgenkapital", avstemming.sum_fradrag)}
    #{endringer}
        #{beloep_med_skattemessige("utgaaendeEgenkapital", avstemming.utgaaende_ek)}
      </egenkapitalavstemming>
    """
    |> String.trim_trailing()
  end

  # Emits a `BeloepMedSkattemessigeEgenskaper` element — three nested
  # `<beloep>` levels where the innermost is the decimal value
  # (`BeloepMed2Desimaler`). Matches the same shape used by
  # `balanseforekomst/3`.
  defp beloep_med_skattemessige(tag, value) do
    """
    <#{tag}>
          <beloep>
            <beloep>#{format_beloep(value)}</beloep>
          </beloep>
        </#{tag}>
    """
    |> String.trim()
  end

  # Emits `<inntektOgUnderskudd>` with both the prior-year carryforward and
  # the derived fields SKD flags as `manglerSkattemelding` when omitted:
  # `samletUnderskudd`, `inntektsfradrag/underskudd`,
  # `inntektFoerFradragForEventueltAvgittKonsernbidrag`,
  # `fremfoerbartUnderskuddIInntekt`.
  #
  # `fremfoert`  — prior-year carryforward, integer ≥ 0
  # `fremfoerbart` — fremfoert + this year's new loss (rolled forward)
  # `aarets_underskudd` — current year's loss, integer ≥ 0
  # `inntekt_foer_fradrag` — skattepliktig brutto (signed)
  defp inntekt_og_underskudd_block(fremfoert, fremfoerbart, aarets_underskudd, inntekt) do
    fremfoert_block =
      if fremfoert > 0 do
        "<fremfoertUnderskuddFraTidligereAar><beloepSomHeltall>#{fremfoert}</beloepSomHeltall></fremfoertUnderskuddFraTidligereAar>"
      else
        ""
      end

    fremfoerbart_block =
      if fremfoerbart > 0 do
        "<fremfoerbartUnderskuddIInntekt><beloep><beloepSomHeltall>#{fremfoerbart}</beloepSomHeltall></beloep></fremfoerbartUnderskuddIInntekt>"
      else
        ""
      end

    underskudd_til_fremfoering_xml =
      [fremfoert_block, fremfoerbart_block]
      |> Enum.reject(&(&1 == ""))
      |> case do
        [] ->
          ""

        parts ->
          "    <underskuddTilFremfoering>\n      " <>
            Enum.join(parts, "\n      ") <> "\n    </underskuddTilFremfoering>"
      end

    inntektsfradrag_xml =
      if aarets_underskudd > 0 do
        """
            <inntektsfradrag>
              <underskudd>
                <beloepSomHeltall>#{aarets_underskudd}</beloepSomHeltall>
              </underskudd>
            </inntektsfradrag>
        """
        |> String.trim_trailing()
      else
        ""
      end

    inntekt_foer_xml =
      "    <inntektFoerFradragForEventueltAvgittKonsernbidrag><beloepSomHeltall>#{inntekt}</beloepSomHeltall></inntektFoerFradragForEventueltAvgittKonsernbidrag>"

    samlet_underskudd_xml =
      if aarets_underskudd > 0 do
        "    <samletUnderskudd><beloep><beloepSomHeltall>#{aarets_underskudd}</beloepSomHeltall></beloep></samletUnderskudd>"
      else
        ""
      end

    inner =
      [
        underskudd_til_fremfoering_xml,
        inntektsfradrag_xml,
        inntekt_foer_xml,
        samlet_underskudd_xml
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    "  <inntektOgUnderskudd>\n" <> inner <> "\n  </inntektOgUnderskudd>"
  end

  defp opplysning_om_skattesubjekt_block(konfig) do
    er_boersnotert = Map.get(konfig || %{}, :er_boersnotert, false)
    har_ytelse = Map.get(konfig || %{}, :har_ytelse_mellom_aksjonaer_og_selskap, false)

    """
      <opplysningOmSkattesubjekt>
        <erBoersnotert>#{er_boersnotert}</erBoersnotert>
        <harYtelseMellomAksjonaerEllerNaerstaaendeOgSelskapEllerSelskapetsDatterselskap>#{har_ytelse}</harYtelseMellomAksjonaerEllerNaerstaaendeOgSelskapEllerSelskapetsDatterselskap>
      </opplysningOmSkattesubjekt>
    """
    |> String.trim_trailing()
  end

  defp overstyrt_heltall(tag, value) do
    """
    <#{tag}>
      <beloep>
        <beloepSomHeltall>#{value}</beloepSomHeltall>
      </beloep>
      <erOverstyrt>
        <boolsk>true</boolsk>
      </erOverstyrt>
    </#{tag}>
    """
    |> String.trim()
  end

  @doc """
  Generates a `<spesifikasjonAvForholdRelevanteForBeskatning>` block from a
  list of holding maps. Returns an empty string for an empty list.

  Each holding map must include `:type`, which selects the forekomst variant:

    * `:aksje_i_aksjonaerregisteret` — Norwegian AS in aksjonærregisteret.
      Expected keys: `:selskapets_navn`, `:selskapets_organisasjonsnummer`,
      `:landkode`, `:er_omfattet_av_fritaksmetoden`, `:aksjeklasse`,
      `:isinnummer`, `:antall_aksjer`, `:utbytte`,
      `:gevinst_ved_realisasjon_av_aksje`, `:tap_ved_realisasjon_av_aksje`.

    * `:aksje_ikke_i_aksjonaerregisteret` — foreign shares held via custodian.
      Adds `:kontofoerers_navn`, `:kontonummer`, `:finansproduktidentifikator`,
      `:finansproduktidentifikatortype`.

    * `:verdipapirfond` — mutual fund. Expected keys: `:fondets_navn`,
      `:fondets_organisasjonsnummer`, `:landkode`,
      `:er_omfattet_av_fritaksmetoden`, `:isinnummer`, `:antall_andeler`,
      `:utbytte`, `:renteinntekt`,
      `:gevinst_ved_realisasjon_av_andel_i_aksjedel`,
      `:tap_ved_realisasjon_av_andel_i_aksjedel`,
      `:gevinst_ved_realisasjon_av_andel_i_rentedel`,
      `:tap_ved_realisasjon_av_andel_i_rentedel`.

  All numeric fields are emitted only when non-nil. `id` is assigned by
  index (1-based) in the order received.
  """
  def generer_spesifikasjon_av_forhold_relevante_for_beskatning([]), do: ""

  def generer_spesifikasjon_av_forhold_relevante_for_beskatning(holdings)
      when is_list(holdings) do
    # Forekomster must appear in XSD-declared order within
    # SpesifikasjonAvForholdRelevanteForBeskatning. Sort holdings by this order
    # before emission while keeping each group's input order stable.
    forekomster =
      holdings
      |> Enum.with_index(1)
      |> Enum.sort_by(fn {%{type: t}, idx} -> {xsd_order(t), idx} end)
      |> Enum.map(fn {holding, idx} -> forekomst(holding, idx) end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    if forekomster == "" do
      ""
    else
      "  <spesifikasjonAvForholdRelevanteForBeskatning>\n" <>
        forekomster <>
        "\n  </spesifikasjonAvForholdRelevanteForBeskatning>"
    end
  end

  # XSD child order within <spesifikasjonAvForholdRelevanteForBeskatning>.
  defp xsd_order(:aksje_i_aksjonaerregisteret), do: 1
  defp xsd_order(:verdipapirfond), do: 2
  defp xsd_order(:aksje_ikke_i_aksjonaerregisteret), do: 3
  defp xsd_order(_), do: 99

  defp forekomst(%{type: :aksje_i_aksjonaerregisteret} = h, idx) do
    children =
      [
        "<id>#{idx}</id>",
        wrap_navn("selskapetsNavn", h[:selskapets_navn]),
        wrap_orgnr("selskapetsOrganisasjonsnummer", h[:selskapets_organisasjonsnummer]),
        wrap_landkode(h[:landkode]),
        wrap_boolsk("erOmfattetAvFritaksmetoden", h[:er_omfattet_av_fritaksmetoden]),
        wrap_aksjeklasse(h[:aksjeklasse]),
        wrap_isin(h[:isinnummer]),
        wrap_antall("antallAksjer", h[:antall_aksjer]),
        wrap_beloep_heltall("utbytte", h[:utbytte]),
        wrap_beloep_heltall(
          "gevinstVedRealisasjonAvAksje",
          h[:gevinst_ved_realisasjon_av_aksje]
        ),
        wrap_beloep_heltall("tapVedRealisasjonAvAksje", h[:tap_ved_realisasjon_av_aksje])
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.map_join("\n", &("      " <> &1))

    "    <aksjeIAksjonaerregisteret>\n" <>
      children <>
      "\n    </aksjeIAksjonaerregisteret>"
  end

  defp forekomst(%{type: :aksje_ikke_i_aksjonaerregisteret} = h, idx) do
    children =
      [
        "<id>#{idx}</id>",
        wrap_navn("kontofoerersNavn", h[:kontofoerers_navn]),
        wrap_tekst("kontonummer", h[:kontonummer]),
        wrap_navn("selskapetsNavn", h[:selskapets_navn]),
        wrap_orgnr("selskapetsOrganisasjonsnummer", h[:selskapets_organisasjonsnummer]),
        wrap_tekst("finansproduktidentifikator", h[:finansproduktidentifikator]),
        wrap_tekst("finansproduktidentifikatortype", h[:finansproduktidentifikatortype]),
        wrap_landkode(h[:landkode]),
        wrap_boolsk("erOmfattetAvFritaksmetoden", h[:er_omfattet_av_fritaksmetoden]),
        wrap_desimaltall("antallAksjer", h[:antall_aksjer]),
        wrap_beloep_heltall("utbytte", h[:utbytte]),
        wrap_beloep_heltall(
          "gevinstVedRealisasjonAvAksje",
          h[:gevinst_ved_realisasjon_av_aksje]
        ),
        wrap_beloep_heltall("tapVedRealisasjonAvAksje", h[:tap_ved_realisasjon_av_aksje])
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.map_join("\n", &("      " <> &1))

    "    <aksjeIkkeIAksjonaerregisteret>\n" <>
      children <>
      "\n    </aksjeIkkeIAksjonaerregisteret>"
  end

  defp forekomst(%{type: :verdipapirfond} = h, idx) do
    children =
      [
        "<id>#{idx}</id>",
        wrap_navn("fondetsNavn", h[:fondets_navn]),
        wrap_orgnr("fondetsOrganisasjonsnummer", h[:fondets_organisasjonsnummer]),
        wrap_landkode(h[:landkode]),
        wrap_boolsk("erOmfattetAvFritaksmetoden", h[:er_omfattet_av_fritaksmetoden]),
        wrap_isin(h[:isinnummer]),
        wrap_desimaltall("antallAndeler", h[:antall_andeler]),
        wrap_beloep_heltall("utbytte", h[:utbytte]),
        wrap_beloep_heltall("renteinntekt", h[:renteinntekt]),
        wrap_beloep_heltall(
          "gevinstVedRealisasjonAvAndelIAksjedel",
          h[:gevinst_ved_realisasjon_av_andel_i_aksjedel]
        ),
        wrap_beloep_heltall(
          "tapVedRealisasjonAvAndelIAksjedel",
          h[:tap_ved_realisasjon_av_andel_i_aksjedel]
        ),
        wrap_beloep_heltall(
          "gevinstVedRealisasjonAvAndelIRentedel",
          h[:gevinst_ved_realisasjon_av_andel_i_rentedel]
        ),
        wrap_beloep_heltall(
          "tapVedRealisasjonAvAndelIRentedel",
          h[:tap_ved_realisasjon_av_andel_i_rentedel]
        )
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.map_join("\n", &("      " <> &1))

    "    <verdipapirfond>\n" <>
      children <>
      "\n    </verdipapirfond>"
  end

  defp forekomst(%{type: type}, _idx) do
    raise ArgumentError,
          "unsupported aksjespesifikasjon :type — #{inspect(type)}. " <>
            "Skattemelding XML can only emit :aksje_i_aksjonaerregisteret, " <>
            ":aksje_ikke_i_aksjonaerregisteret, or :verdipapirfond."
  end

  defp wrap_navn(_tag, nil), do: ""
  defp wrap_navn(_tag, ""), do: ""

  defp wrap_navn(tag, value),
    do: "<#{tag}><organisasjonsnavn>#{escape(value)}</organisasjonsnavn></#{tag}>"

  defp wrap_orgnr(_tag, nil), do: ""
  defp wrap_orgnr(_tag, ""), do: ""

  defp wrap_orgnr(tag, value),
    do: "<#{tag}><organisasjonsnummer>#{escape(value)}</organisasjonsnummer></#{tag}>"

  defp wrap_landkode(nil), do: ""
  defp wrap_landkode(""), do: ""

  defp wrap_landkode(value),
    do: "<landkode><landkode>#{escape(value)}</landkode></landkode>"

  defp wrap_boolsk(_tag, nil), do: ""

  defp wrap_boolsk(tag, value) when is_boolean(value),
    do: "<#{tag}><boolsk>#{value}</boolsk></#{tag}>"

  defp wrap_tekst(_tag, nil), do: ""
  defp wrap_tekst(_tag, ""), do: ""

  defp wrap_tekst(tag, value),
    do: "<#{tag}><tekst>#{escape(value)}</tekst></#{tag}>"

  defp wrap_isin(nil), do: ""
  defp wrap_isin(""), do: ""

  defp wrap_isin(value),
    do: "<isinnummer><isinnummer>#{escape(value)}</isinnummer></isinnummer>"

  defp wrap_antall(_tag, nil), do: ""

  defp wrap_antall(tag, value),
    do: "<#{tag}><antall>#{value}</antall></#{tag}>"

  defp wrap_desimaltall(_tag, nil), do: ""

  defp wrap_desimaltall(tag, value),
    do: "<#{tag}><desimaltall>#{value}</desimaltall></#{tag}>"

  defp wrap_aksjeklasse(nil), do: ""
  defp wrap_aksjeklasse(""), do: ""

  # SKD's "aksjeklasse" kodeliste is case-sensitive lowercase
  # (see Skatteetaten/skattemeldingen/src/resources/kodeliste/aksjeklasse.xml —
  # values: alle, ordinaer, a..j, preferanse, ekstraordinaer). Submitting
  # "B" instead of "b" gets rejected with UgyldigKodelisteverdi at the
  # /valider step, so normalize here.
  defp wrap_aksjeklasse(value),
    do: "<aksjeklasse><aksjeklasse>#{escape(String.downcase(value))}</aksjeklasse></aksjeklasse>"

  defp wrap_beloep_heltall(_tag, nil), do: ""
  defp wrap_beloep_heltall(_tag, 0), do: ""

  defp wrap_beloep_heltall(tag, value),
    do: "<#{tag}><beloepSomHeltall>#{value}</beloepSomHeltall></#{tag}>"

  # ── naeringsspesifikasjon (v6) ──────────────────────────────────────

  @doc """
  Generates the `naeringsspesifikasjon` XML document (v6).

  ## Options

  - `:partsnummer` — Skatteetaten's integer ID. Defaults to
    `aarsregnskap.selskap.org_nummer`.
  - `:permanent_forskjeller` — list of maps emitted as
    `<forskjellMellomRegnskapsmessigOgSkattemessigVerdi><permanentForskjell>…`.
    Required for SKD to apply fritaksmetoden — without these explicit
    "tilbakeføring av utbytte" / "treprosent" / "gevinst-fradrag" /
    "tap-tillegg" declarations, SKD taxes the full regnskapsmessig income.
    See `generer_permanent_forskjell_block/1` for the expected shape.
  - `:kontaktperson` — map with `:navn` (required), `:telefonnummer`
    (optional), `:epostadresse` (optional). Emitted as `<kontaktperson>`
    inside `<virksomhet>`. SKD's post-acceptance audit appears to read
    this as the "spor til utførende" (named human to contact about the
    submission); omitting it has been observed to cause SKD to return
    `innkommendeForespoerselManglerSporTilUtfoerende` in the
    tilbakemelding after a successful Altinn signing.
  """
  def generer_naeringsspesifikasjon_xml(%Aarsregnskap{} = regnskap, opts \\ []) do
    partsnummer = Keyword.get(opts, :partsnummer, regnskap.selskap.org_nummer)
    aar = regnskap.regnskapsaar
    r = regnskap.resultatregnskap
    b = regnskap.balanse
    skal_revisor = if regnskap.revideres, do: "true", else: "false"
    kontaktperson = Keyword.get(opts, :kontaktperson)

    pf_entries = Keyword.get(opts, :permanent_forskjeller, [])
    permanent_forskjeller = generer_permanent_forskjell_block(pf_entries)

    skattepliktig_brutto = Wenche.Skattemelding.derive_skattepliktig_brutto(regnskap, pf_entries)
    beregnet_naeringsinntekt = beregnet_naeringsinntekt_block(skattepliktig_brutto)

    egenkapitalavstemming =
      regnskap
      |> Wenche.Skattemelding.beregn_egenkapitalavstemming()
      |> egenkapitalavstemming_block()

    parts =
      [
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
        "<naeringsspesifikasjon xmlns=\"#{@naering_ns}\">",
        "  <partsreferanse>#{partsnummer}</partsreferanse>",
        "  <inntektsaar>#{aar}</inntektsaar>",
        resultatregnskap_block(r),
        balanseregnskap_block(b),
        beregnet_naeringsinntekt,
        permanent_forskjeller,
        virksomhet_block(aar, kontaktperson),
        egenkapitalavstemming,
        "  <skalBekreftesAvRevisor>#{skal_revisor}</skalBekreftesAvRevisor>",
        "</naeringsspesifikasjon>"
      ]
      |> Enum.reject(&(&1 == ""))

    Enum.join(parts, "\n")
  end

  @doc """
  Generates a `<forskjellMellomRegnskapsmessigOgSkattemessigVerdi>` block
  from a list of permanent-forskjell maps. Returns `""` for an empty list.

  Each entry must include:

    * `:type` — `tekniskNavn` from the 2025 permanentForskjellstype kodeliste.
      Examples relevant to fritaksmetoden:
      `:tilbakefoeringAvInntektsfoertUtbytte` (0815, fradrag),
      `:skattepliktigDelAvUtbytterOgUtdelinger` (0653, tillegg = 3 %),
      `:regnskapsmessigGevinstVedRealisasjonAvFinansielleInstrumenter`
        (0833, fradrag),
      `:regnskapsmessigTapVedRealisasjonAvFinansielleInstrumenter`
        (0633, tillegg).
    * `:beloep` — `Decimal.t` or integer NOK (always positive; the
      kodeliste's `kategori` determines whether SKD treats it as
      tillegg or fradrag). Decimal beloep is rounded per line for
      emission as an integer. Rounding mode is `:half_up` for most
      types; the 3 % addback (`:skattepliktigDelAvUtbytterOgUtdelinger`)
      floors instead, per skatteloven § 2-38 (6) and the SKD
      veiledning convention.
    * `:beskrivelse` — optional free text.

  Entries with `:beloep <= 0` (after rounding) are dropped — SKD
  rejects zero-valued permanent forskjeller as invalid.
  """
  def generer_permanent_forskjell_block([]), do: ""

  def generer_permanent_forskjell_block(entries) when is_list(entries) do
    forekomster =
      entries
      |> Enum.map(&normalize_permanent_forskjell/1)
      |> Enum.filter(&(&1.beloep > 0))
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {entry, idx} -> permanent_forskjell(entry, idx) end)

    if forekomster == "" do
      ""
    else
      {sum_tillegg, sum_fradrag} =
        Wenche.Skattemelding.permanent_forskjeller_tillegg_fradrag(entries)

      sums =
        "\n    " <>
          beloep_med_skattemessige("sumTilleggINaeringsinntekt", sum_tillegg) <>
          "\n    " <>
          beloep_med_skattemessige("sumFradragINaeringsinntekt", sum_fradrag)

      "  <forskjellMellomRegnskapsmessigOgSkattemessigVerdi>\n" <>
        forekomster <>
        sums <>
        "\n  </forskjellMellomRegnskapsmessigOgSkattemessigVerdi>"
    end
  end

  # Emits the optional `<beregnetNaeringsinntekt>` block. SKD computes this
  # itself in /valider but flags it as `manglerNaeringsopplysninger` when
  # missing from the submission. We always emit it once we have a regnskap
  # — fordeltSkattemessigResultat at id="1" carries the full year for an
  # ordinary AS (single virksomhet).
  defp beregnet_naeringsinntekt_block(skattepliktig_brutto) do
    """
      <beregnetNaeringsinntekt>
        <fordeltBeregnetNaeringsinntektForUpersonligSkattepliktig>
          <id>1</id>
          #{beloep_med_skattemessige("fordeltSkattemessigResultat", skattepliktig_brutto)}
          #{beloep_med_skattemessige("fordeltSkattemessigResultatEtterKorreksjon", skattepliktig_brutto)}
        </fordeltBeregnetNaeringsinntektForUpersonligSkattepliktig>
        #{beloep_med_skattemessige("skattemessigResultat", skattepliktig_brutto)}
      </beregnetNaeringsinntekt>
    """
    |> String.trim_trailing()
  end

  defp normalize_permanent_forskjell(%{type: type, beloep: b} = entry) do
    %{entry | beloep: beloep_to_int(b, rounding_mode(type))}
  end

  # The 3 % addback under skatteloven § 2-38 (6) is a tillegg to skattepliktig
  # inntekt. Rounding it down (taxpayer-favorable) is the convention used by
  # the SKD veiledning and by reference implementations such as Fiken.
  # Other permanent forskjeller use standard half-up rounding.
  defp rounding_mode(:skattepliktigDelAvUtbytterOgUtdelinger), do: :floor
  defp rounding_mode("skattepliktigDelAvUtbytterOgUtdelinger"), do: :floor
  defp rounding_mode(_), do: :half_up

  defp beloep_to_int(%Decimal{} = d, mode),
    do: d |> Decimal.round(0, mode) |> Decimal.to_integer()

  defp beloep_to_int(n, _mode) when is_integer(n), do: n

  defp permanent_forskjell(%{type: type, beloep: beloep} = entry, idx)
       when is_atom(type) or is_binary(type) do
    type_name = type |> to_string()

    beskrivelse =
      case Map.get(entry, :beskrivelse) do
        nil -> ""
        "" -> ""
        text -> "\n      <beskrivelse><tekst>#{escape(text)}</tekst></beskrivelse>"
      end

    """
        <permanentForskjell>
          <id>#{idx}</id>
          <permanentForskjellstype><permanentForskjellstype>#{type_name}</permanentForskjellstype></permanentForskjellstype>
          <beloep><beloep><beloep>#{beloep}</beloep></beloep></beloep>#{beskrivelse}
        </permanentForskjell>\
    """
    |> String.trim_trailing()
  end

  defp resultatregnskap_block(r) do
    alias Wenche.Models.{Driftsinntekter, Driftskostnader, Finansposter, Resultatregnskap}
    di = r.driftsinntekter
    dk = r.driftskostnader
    fp = r.finansposter

    driftsinntekt_children =
      []
      |> add_inntekt_post("salgsinntekt", di.salgsinntekter, @kode_salgsinntekt)
      |> add_inntekt_post(
        "annenDriftsinntekt",
        di.andre_driftsinntekter,
        @kode_andre_driftsinntekter
      )

    driftskostnad_children =
      []
      |> add_kostnad_post("loennskostnad", dk.loennskostnader, @kode_loennskostnad)
      |> add_annen_driftskostnad(dk)

    finansinntekt_forekomster =
      []
      |> add_forekomst("inntekt", fp.utbytte_fra_datterselskap, @kode_utbytte_datterselskap)
      |> add_forekomst("inntekt", fp.andre_finansinntekter, @kode_andre_finansinntekter)

    finanskostnad_forekomster =
      []
      |> add_forekomst("kostnad", fp.rentekostnader, @kode_rentekostnader)
      |> add_forekomst("kostnad", fp.andre_finanskostnader, @kode_andre_finanskostnader)

    sum_di = Driftsinntekter.sum(di)
    sum_dk = Driftskostnader.sum(dk)
    sum_fi = Finansposter.sum_inntekter(fp)
    sum_fk = Finansposter.sum_kostnader(fp)
    aarsresultat = Resultatregnskap.aarsresultat(r)

    inner =
      [
        wrap_children("driftsinntekt", driftsinntekt_children,
          sum_tag: "sumDriftsinntekt",
          sum_value: sum_di
        ),
        wrap_children("driftskostnad", driftskostnad_children,
          sum_tag: "sumDriftskostnad",
          sum_value: sum_dk
        ),
        "    " <> beloep_med_skattemessige("sumFinansinntekt", sum_fi),
        "    " <> beloep_med_skattemessige("sumFinanskostnad", sum_fk),
        wrap_forekomster("finansinntekt", finansinntekt_forekomster),
        wrap_forekomster("finanskostnad", finanskostnad_forekomster),
        "    " <> beloep_med_skattemessige("aarsresultat", aarsresultat)
      ]
      |> Enum.reject(&(&1 == ""))

    if inner == [] do
      ""
    else
      "  <resultatregnskap>\n" <> Enum.join(inner, "\n") <> "\n  </resultatregnskap>"
    end
  end

  defp add_inntekt_post(acc, _wrapper_tag, 0, _kode), do: acc

  defp add_inntekt_post(acc, wrapper_tag, beloep, kode) do
    acc ++ [{wrapper_tag, resultatforekomst("inntekt", beloep, kode)}]
  end

  defp add_kostnad_post(acc, _wrapper_tag, 0, _kode), do: acc

  defp add_kostnad_post(acc, wrapper_tag, beloep, kode) do
    acc ++ [{wrapper_tag, resultatforekomst("kostnad", beloep, kode)}]
  end

  defp add_annen_driftskostnad(acc, dk) do
    forekomster =
      []
      |> add_forekomst("kostnad", dk.avskrivninger, @kode_avskrivninger)
      |> add_forekomst("kostnad", dk.andre_driftskostnader, @kode_andre_driftskostnader)

    if forekomster == [] do
      acc
    else
      acc ++ [{"annenDriftskostnad", Enum.join(forekomster, "\n")}]
    end
  end

  defp add_forekomst(acc, _child_tag, 0, _kode), do: acc

  defp add_forekomst(acc, child_tag, beloep, kode) do
    acc ++ [resultatforekomst(child_tag, beloep, kode)]
  end

  defp wrap_children(_tag, [], _opts), do: ""

  defp wrap_children(tag, children, opts) do
    sum_xml =
      case Keyword.get(opts, :sum_tag) do
        nil ->
          ""

        sum_tag ->
          "      " <> beloep_med_skattemessige(sum_tag, Keyword.fetch!(opts, :sum_value)) <> "\n"
      end

    inner =
      Enum.map_join(children, "\n", fn {wrapper_tag, forekomst_xml} ->
        "      <#{wrapper_tag}>\n#{forekomst_xml}\n      </#{wrapper_tag}>"
      end)

    "    <#{tag}>\n#{sum_xml}#{inner}\n    </#{tag}>"
  end

  defp wrap_forekomster(_tag, []), do: ""

  defp wrap_forekomster(tag, forekomster) do
    "    <#{tag}>\n#{Enum.join(forekomster, "\n")}\n    </#{tag}>"
  end

  # Resultatregnskapsforekomst sequence per XSD: beloep, id, type.
  defp resultatforekomst(child_tag, beloep, kode) do
    """
            <#{child_tag}>
              <beloep>
                <beloep>
                  <beloep>#{format_beloep(beloep)}</beloep>
                </beloep>
              </beloep>
              <id>#{kode}</id>
              <type>
                <resultatOgBalanseregnskapstype>#{kode}</resultatOgBalanseregnskapstype>
              </type>
            </#{child_tag}>
    """
    |> String.trim_trailing()
  end

  # Balanseregnskapsforekomst: id is FIRST, then beloep, then type
  defp balanseforekomst(child_tag, beloep, kode) do
    """
            <#{child_tag}>
              <id>#{kode}</id>
              <beloep>
                <beloep>
                  <beloep>#{format_beloep(beloep)}</beloep>
                </beloep>
              </beloep>
              <type>
                <resultatOgBalanseregnskapstype>#{kode}</resultatOgBalanseregnskapstype>
              </type>
            </#{child_tag}>
    """
    |> String.trim_trailing()
  end

  defp balanseregnskap_block(b) do
    alias Wenche.Models.{
      Anleggsmidler,
      Egenkapital,
      EgenkapitalOgGjeld,
      Eiendeler,
      KortsiktigGjeld,
      LangsiktigGjeld,
      Omloepmidler
    }

    am = b.eiendeler.anleggsmidler
    om = b.eiendeler.omloepmidler
    eog = b.egenkapital_og_gjeld

    anleggsmidler_forekomster =
      []
      |> add_forekomst_bal(am.aksjer_i_datterselskap, @kode_aksjer_datterselskap)
      |> add_forekomst_bal(am.andre_aksjer, @kode_andre_aksjer)
      |> add_forekomst_bal(am.langsiktige_fordringer, @kode_langsiktige_fordringer)

    omloepsmidler_forekomster =
      []
      |> add_forekomst_bal(om.kortsiktige_fordringer, @kode_kortsiktige_fordringer)
      |> add_forekomst_bal(om.bankinnskudd, @kode_bankinnskudd)

    egenkapital_forekomster = egenkapital_forekomster(eog.egenkapital)

    langsiktig_gjeld_forekomster =
      []
      |> add_forekomst_bal_named(
        "gjeld",
        eog.langsiktig_gjeld.laan_fra_aksjonaer,
        @kode_laan_aksjonaer
      )
      |> add_forekomst_bal_named(
        "gjeld",
        eog.langsiktig_gjeld.andre_langsiktige_laan,
        @kode_andre_langsiktige_laan
      )

    kortsiktig_gjeld_forekomster =
      []
      |> add_forekomst_bal_named(
        "gjeld",
        eog.kortsiktig_gjeld.leverandoergjeld,
        @kode_leverandoergjeld
      )
      |> add_forekomst_bal_named(
        "gjeld",
        eog.kortsiktig_gjeld.skyldige_offentlige_avgifter,
        @kode_offentlige_avgifter
      )
      |> add_forekomst_bal_named(
        "gjeld",
        eog.kortsiktig_gjeld.annen_kortsiktig_gjeld,
        @kode_annen_kortsiktig_gjeld
      )

    sum_am = Anleggsmidler.sum(am)
    sum_om = Omloepmidler.sum(om)
    sum_lg = LangsiktigGjeld.sum(eog.langsiktig_gjeld)
    sum_kg = KortsiktigGjeld.sum(eog.kortsiktig_gjeld)
    sum_ek = Egenkapital.sum(eog.egenkapital)
    sum_eiendel = Eiendeler.sum(b.eiendeler)
    sum_gjeld_og_ek = EgenkapitalOgGjeld.sum(eog)

    anleggsmiddel_block =
      wrap_balanseverdi(
        "anleggsmiddel",
        "balanseverdiForAnleggsmiddel",
        anleggsmidler_forekomster,
        sum_tag: "sumBalanseverdiForAnleggsmiddel",
        sum_value: sum_am
      )

    omloepsmiddel_block =
      wrap_balanseverdi(
        "omloepsmiddel",
        "balanseverdiForOmloepsmiddel",
        omloepsmidler_forekomster,
        sum_tag: "sumBalanseverdiForOmloepsmiddel",
        sum_value: sum_om
      )

    gjeld_og_egenkapital_block =
      build_gjeld_og_egenkapital(
        langsiktig_gjeld_forekomster,
        kortsiktig_gjeld_forekomster,
        egenkapital_forekomster,
        sum_lg: sum_lg,
        sum_kg: sum_kg,
        sum_ek: sum_ek
      )

    inner =
      [
        anleggsmiddel_block,
        omloepsmiddel_block,
        gjeld_og_egenkapital_block,
        "    " <> beloep_med_skattemessige("sumBalanseverdiForEiendel", sum_eiendel),
        "    " <> beloep_med_skattemessige("sumGjeldOgEgenkapital", sum_gjeld_og_ek)
      ]
      |> Enum.reject(&(&1 == ""))

    if inner == [] do
      ""
    else
      "  <balanseregnskap>\n" <> Enum.join(inner, "\n") <> "\n  </balanseregnskap>"
    end
  end

  defp egenkapital_forekomster(ek) do
    {annen_kode, annen_beloep} =
      if ek.annen_egenkapital >= 0 do
        {@kode_annen_egenkapital, ek.annen_egenkapital}
      else
        {@kode_udekket_tap, abs(ek.annen_egenkapital)}
      end

    []
    |> add_forekomst_bal_named("kapital", ek.aksjekapital, @kode_aksjekapital)
    |> add_forekomst_bal_named("kapital", ek.overkursfond, @kode_overkursfond)
    |> add_forekomst_bal_named("kapital", annen_beloep, annen_kode)
  end

  defp add_forekomst_bal(acc, 0, _kode), do: acc

  defp add_forekomst_bal(acc, beloep, kode) do
    acc ++ [balanseforekomst("balanseverdi", beloep, kode)]
  end

  defp add_forekomst_bal_named(acc, _tag, 0, _kode), do: acc

  defp add_forekomst_bal_named(acc, tag, beloep, kode) do
    acc ++ [balanseforekomst(tag, beloep, kode)]
  end

  defp wrap_balanseverdi(_outer_tag, _inner_tag, [], _opts), do: ""

  defp wrap_balanseverdi(outer_tag, inner_tag, forekomster, opts) do
    sum_xml =
      case Keyword.get(opts, :sum_tag) do
        nil ->
          ""

        sum_tag ->
          "      " <> beloep_med_skattemessige(sum_tag, Keyword.fetch!(opts, :sum_value)) <> "\n"
      end

    """
        <#{outer_tag}>
    #{sum_xml}      <#{inner_tag}>
    #{Enum.join(forekomster, "\n")}
          </#{inner_tag}>
        </#{outer_tag}>
    """
    |> String.trim_trailing()
  end

  defp build_gjeld_og_egenkapital(lg, kg, ek, sums) do
    # XSD sequence: sumLangsiktigGjeld, sumKortsiktigGjeld, sumEgenkapital,
    # langsiktigGjeld, kortsiktigGjeld, egenkapital. The sum-* elements are
    # derived but SKD flags them as `manglerNaeringsopplysninger` when
    # omitted.
    sum_xml =
      case sums do
        [] ->
          ""

        _ ->
          Enum.map_join(
            [
              {"sumLangsiktigGjeld", Keyword.get(sums, :sum_lg, 0)},
              {"sumKortsiktigGjeld", Keyword.get(sums, :sum_kg, 0)},
              {"sumEgenkapital", Keyword.get(sums, :sum_ek, 0)}
            ],
            "\n",
            fn {tag, value} -> "      " <> beloep_med_skattemessige(tag, value) end
          ) <> "\n"
      end

    parts =
      []
      |> append_gjeld_group("langsiktigGjeld", "gjeld", lg)
      |> append_gjeld_group("kortsiktigGjeld", "gjeld", kg)
      |> append_egenkapital(ek)

    if parts == [] do
      ""
    else
      "    <gjeldOgEgenkapital>\n" <>
        sum_xml <> Enum.join(parts, "\n") <> "\n    </gjeldOgEgenkapital>"
    end
  end

  defp append_gjeld_group(acc, _tag, _child_tag, []), do: acc

  defp append_gjeld_group(acc, tag, _child_tag, forekomster) do
    acc ++ ["      <#{tag}>\n#{Enum.join(forekomster, "\n")}\n      </#{tag}>"]
  end

  defp append_egenkapital(acc, []), do: acc

  defp append_egenkapital(acc, forekomster) do
    acc ++ ["      <egenkapital>\n#{Enum.join(forekomster, "\n")}\n      </egenkapital>"]
  end

  defp virksomhet_block(aar, kontaktperson) do
    inner =
      [
        "    <regnskapspliktstype>",
        "      <regnskapspliktstype>fullRegnskapsplikt</regnskapspliktstype>",
        "    </regnskapspliktstype>",
        "    <regnskapsperiode>",
        "      <start>",
        "        <dato>#{aar}-01-01</dato>",
        "      </start>",
        "      <slutt>",
        "        <dato>#{aar}-12-31</dato>",
        "      </slutt>",
        "    </regnskapsperiode>",
        "    <virksomhetstype>",
        "      <virksomhetstype>oevrigSelskap</virksomhetstype>",
        "    </virksomhetstype>",
        "    <regeltypeForAarsregnskap>",
        "      <regeltypeForAarsregnskap>regnskapslovensReglerForSmaaForetak</regeltypeForAarsregnskap>",
        "    </regeltypeForAarsregnskap>",
        kontaktperson_block(kontaktperson)
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    ("  <virksomhet>\n" <> inner <> "\n  </virksomhet>")
    |> String.trim_trailing()
  end

  # Emits the optional `<kontaktperson>` element on `<virksomhet>`. Returns ""
  # when the input is nil or has no usable `:navn` — we never emit a partial
  # block. XSD `Kontaktinformasjon` requires `<navn>` first and accepts
  # `<telefonnummer>`, `<epostadresse>`, `<mobiltelefonummer>`, `<smsNummer>`
  # in that order. Each is a simple string type.
  defp kontaktperson_block(nil), do: ""
  defp kontaktperson_block(%{navn: nil}), do: ""
  defp kontaktperson_block(%{navn: ""}), do: ""

  defp kontaktperson_block(%{navn: navn} = k) do
    children =
      [
        "      <navn>#{escape(navn)}</navn>",
        wrap_simple("telefonnummer", Map.get(k, :telefonnummer)),
        wrap_simple("epostadresse", Map.get(k, :epostadresse)),
        wrap_simple("mobiltelefonummer", Map.get(k, :mobiltelefonummer)),
        wrap_simple("smsNummer", Map.get(k, :sms_nummer))
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    "    <kontaktperson>\n" <> children <> "\n    </kontaktperson>"
  end

  defp kontaktperson_block(_), do: ""

  defp wrap_simple(_tag, nil), do: ""
  defp wrap_simple(_tag, ""), do: ""
  defp wrap_simple(tag, value), do: "      <#{tag}>#{escape(value)}</#{tag}>"

  # ── Request envelope (v2) ───────────────────────────────────────────

  @doc """
  Generates the request envelope wrapping skattemelding + naeringsspesifikasjon.

  Both inner documents are base64-encoded into `<dokument><content>` entries.

  ## Options

  - `:inntektsaar` — required for the envelope element.
  - `:tin` — TIN/organisasjonsnummer (recommended).
  - `:innsendingstype` — `"komplett"` (default) or `"ikkeKomplett"`.
  - `:innsendingsformaal` — `"egenfastsetting"` (default), `"klage"`, or `"endringsanmodning"`.
  - `:dokumentreferanse` — optional list of `{dokumenttype, dokumentidentifikator}` pairs to
    emit as `<dokumentreferanseTilGjeldendeDokument>` entries.
  - `:opprettet_av` — text used for `<opprettetAv>` (default `"Wenche"`). Override
    to identify the originating end-user system.
  """
  def generer_request_xml(skattemelding_xml, naeringsspesifikasjon_xml, opts \\ []) do
    aar = Keyword.get(opts, :inntektsaar) || raise ArgumentError, "missing :inntektsaar"
    tin = Keyword.get(opts, :tin)
    innsendingstype = Keyword.get(opts, :innsendingstype, "komplett")
    innsendingsformaal = Keyword.get(opts, :innsendingsformaal, "egenfastsetting")
    dokumentreferanser = Keyword.get(opts, :dokumentreferanse, [])
    opprettet_av = Keyword.get(opts, :opprettet_av, @opprettet_av)

    validate_enum!(:innsendingstype, innsendingstype, ~w(komplett ikkeKomplett))

    validate_enum!(
      :innsendingsformaal,
      innsendingsformaal,
      ~w(egenfastsetting klage endringsanmodning)
    )

    skattemelding_b64 = Base.encode64(skattemelding_xml)

    naering_dok =
      if naeringsspesifikasjon_xml in [nil, ""] do
        ""
      else
        naering_b64 = Base.encode64(naeringsspesifikasjon_xml)

        """
            <dokument>
              <type>naeringsspesifikasjon</type>
              <encoding>utf-8</encoding>
              <content>#{naering_b64}</content>
            </dokument>
        """
        |> String.trim_trailing()
      end

    dokumentreferanse_xml =
      dokumentreferanser
      |> Enum.map_join("\n", fn {dtype, ident} ->
        """
          <dokumentreferanseTilGjeldendeDokument>
            <dokumenttype>#{dtype}</dokumenttype>
            <dokumentidentifikator>#{escape(ident)}</dokumentidentifikator>
          </dokumentreferanseTilGjeldendeDokument>
        """
        |> String.trim_trailing()
      end)

    tin_xml =
      if tin do
        "    <tin>#{escape(tin)}</tin>"
      else
        ""
      end

    parts =
      [
        ~s|<?xml version="1.0" encoding="UTF-8"?>|,
        ~s|<skattemeldingOgNaeringsspesifikasjonRequest xmlns="#{@request_ns}">|,
        "  <dokumenter>",
        """
            <dokument>
              <type>skattemeldingUpersonlig</type>
              <encoding>utf-8</encoding>
              <content>#{skattemelding_b64}</content>
            </dokument>
        """
        |> String.trim_trailing(),
        naering_dok,
        "  </dokumenter>",
        dokumentreferanse_xml,
        "  <inntektsaar>#{aar}</inntektsaar>",
        "  <innsendingsinformasjon>",
        "    <innsendingstype>#{innsendingstype}</innsendingstype>",
        "    <opprettetAv>#{escape(opprettet_av)}</opprettetAv>",
        tin_xml,
        "    <innsendingsformaal>#{innsendingsformaal}</innsendingsformaal>",
        "  </innsendingsinformasjon>",
        "</skattemeldingOgNaeringsspesifikasjonRequest>"
      ]
      |> Enum.reject(&(&1 == ""))

    Enum.join(parts, "\n")
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  @doc """
  Extracts the `partsnummer` from a skattemeldingUpersonlig XML document.

  Used after fetching the pre-filled draft from
  `GET /api/skattemelding/v2/{år}/{orgnr}` to learn Skatteetaten's internal
  ID for the company.

  Returns `{:ok, integer}` or `{:error, :partsnummer_not_found}`.
  """
  def hent_partsnummer(xml) when is_binary(xml) do
    case Regex.run(~r{<(?:\w+:)?partsnummer[^>]*>\s*(\d+)\s*</(?:\w+:)?partsnummer>}, xml) do
      [_, value] -> {:ok, String.to_integer(value)}
      _ -> {:error, :partsnummer_not_found}
    end
  end

  defp format_beloep(beloep) when is_integer(beloep) do
    :erlang.float_to_binary(beloep * 1.0, decimals: 2)
  end

  defp format_beloep(beloep) when is_float(beloep) do
    :erlang.float_to_binary(beloep, decimals: 2)
  end

  defp validate_enum!(field, value, allowed) do
    unless value in allowed do
      raise ArgumentError,
            "invalid #{field}: #{inspect(value)}, expected one of #{inspect(allowed)}"
    end
  end

  defp escape(nil), do: ""

  defp escape(str) when is_binary(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  defp escape(other), do: to_string(other)

  defp remove_blank_lines(str) do
    str
    |> String.split("\n")
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.join("\n")
  end
end
