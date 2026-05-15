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

  alias Wenche.Models.Aarsregnskap

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

    inntekt_og_underskudd =
      if fremfoert > 0 do
        """
          <inntektOgUnderskudd>
            <underskuddTilFremfoering>
              <fremfoertUnderskuddFraTidligereAar>
                <beloepSomHeltall>#{fremfoert}</beloepSomHeltall>
              </fremfoertUnderskuddFraTidligereAar>
            </underskuddTilFremfoering>
          </inntektOgUnderskudd>
        """
        |> String.trim_trailing()
      else
        ""
      end

    aksjespesifikasjon =
      opts
      |> Keyword.get(:aksjespesifikasjon, [])
      |> generer_spesifikasjon_av_forhold_relevante_for_beskatning()

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <skattemelding xmlns="#{@skattemelding_ns}">
      <partsnummer>#{partsnummer}</partsnummer>
      <inntektsaar>#{aar}</inntektsaar>
    #{inntekt_og_underskudd}
    #{aksjespesifikasjon}
    </skattemelding>
    """
    |> String.trim()
    |> remove_blank_lines()
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
      |> Enum.map(&("      " <> &1))
      |> Enum.join("\n")

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
      |> Enum.map(&("      " <> &1))
      |> Enum.join("\n")

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
      |> Enum.map(&("      " <> &1))
      |> Enum.join("\n")

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

  defp wrap_aksjeklasse(value),
    do: "<aksjeklasse><aksjeklasse>#{escape(value)}</aksjeklasse></aksjeklasse>"

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
  """
  def generer_naeringsspesifikasjon_xml(%Aarsregnskap{} = regnskap, opts \\ []) do
    partsnummer = Keyword.get(opts, :partsnummer, regnskap.selskap.org_nummer)
    aar = regnskap.regnskapsaar
    r = regnskap.resultatregnskap
    b = regnskap.balanse
    skal_revisor = if regnskap.revideres, do: "true", else: "false"

    permanent_forskjeller =
      opts
      |> Keyword.get(:permanent_forskjeller, [])
      |> generer_permanent_forskjell_block()

    parts =
      [
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
        "<naeringsspesifikasjon xmlns=\"#{@naering_ns}\">",
        "  <partsreferanse>#{partsnummer}</partsreferanse>",
        "  <inntektsaar>#{aar}</inntektsaar>",
        resultatregnskap_block(r),
        balanseregnskap_block(b),
        permanent_forskjeller,
        virksomhet_block(aar),
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
    * `:beloep` — integer NOK (always positive; the kodeliste's
      `kategori` determines whether SKD treats it as tillegg or fradrag).
    * `:beskrivelse` — optional free text.

  Entries with `:beloep <= 0` are dropped — SKD rejects zero-valued
  permanent forskjeller as invalid.
  """
  def generer_permanent_forskjell_block([]), do: ""

  def generer_permanent_forskjell_block(entries) when is_list(entries) do
    forekomster =
      entries
      |> Enum.filter(&positive_beloep?/1)
      |> Enum.with_index(1)
      |> Enum.map(fn {entry, idx} -> permanent_forskjell(entry, idx) end)
      |> Enum.join("\n")

    if forekomster == "" do
      ""
    else
      "  <forskjellMellomRegnskapsmessigOgSkattemessigVerdi>\n" <>
        forekomster <>
        "\n  </forskjellMellomRegnskapsmessigOgSkattemessigVerdi>"
    end
  end

  defp positive_beloep?(%{beloep: b}) when is_integer(b), do: b > 0
  defp positive_beloep?(_), do: false

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

    inner =
      [
        wrap_children("driftsinntekt", driftsinntekt_children),
        wrap_children("driftskostnad", driftskostnad_children),
        wrap_forekomster("finansinntekt", finansinntekt_forekomster),
        wrap_forekomster("finanskostnad", finanskostnad_forekomster)
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

  defp wrap_children(_tag, []), do: ""

  defp wrap_children(tag, children) do
    inner =
      Enum.map_join(children, "\n", fn {wrapper_tag, forekomst_xml} ->
        "      <#{wrapper_tag}>\n#{forekomst_xml}\n      </#{wrapper_tag}>"
      end)

    "    <#{tag}>\n#{inner}\n    </#{tag}>"
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

    anleggsmiddel_block =
      wrap_balanseverdi(
        "anleggsmiddel",
        "balanseverdiForAnleggsmiddel",
        anleggsmidler_forekomster
      )

    omloepsmiddel_block =
      wrap_balanseverdi(
        "omloepsmiddel",
        "balanseverdiForOmloepsmiddel",
        omloepsmidler_forekomster
      )

    gjeld_og_egenkapital_block =
      build_gjeld_og_egenkapital(
        langsiktig_gjeld_forekomster,
        kortsiktig_gjeld_forekomster,
        egenkapital_forekomster
      )

    inner =
      [anleggsmiddel_block, omloepsmiddel_block, gjeld_og_egenkapital_block]
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

  defp wrap_balanseverdi(_outer_tag, _inner_tag, []), do: ""

  defp wrap_balanseverdi(outer_tag, inner_tag, forekomster) do
    """
        <#{outer_tag}>
          <#{inner_tag}>
    #{Enum.join(forekomster, "\n")}
          </#{inner_tag}>
        </#{outer_tag}>
    """
    |> String.trim_trailing()
  end

  defp build_gjeld_og_egenkapital(lg, kg, ek) do
    # XSD sequence: langsiktigGjeld, kortsiktigGjeld, egenkapital
    parts =
      []
      |> append_gjeld_group("langsiktigGjeld", "gjeld", lg)
      |> append_gjeld_group("kortsiktigGjeld", "gjeld", kg)
      |> append_egenkapital(ek)

    if parts == [] do
      ""
    else
      "    <gjeldOgEgenkapital>\n" <> Enum.join(parts, "\n") <> "\n    </gjeldOgEgenkapital>"
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

  defp virksomhet_block(aar) do
    """
      <virksomhet>
        <regnskapspliktstype>
          <regnskapspliktstype>fullRegnskapsplikt</regnskapspliktstype>
        </regnskapspliktstype>
        <regnskapsperiode>
          <start>
            <dato>#{aar}-01-01</dato>
          </start>
          <slutt>
            <dato>#{aar}-12-31</dato>
          </slutt>
        </regnskapsperiode>
        <virksomhetstype>
          <virksomhetstype>oevrigSelskap</virksomhetstype>
        </virksomhetstype>
        <regeltypeForAarsregnskap>
          <regeltypeForAarsregnskap>regnskapslovensReglerForSmaaForetak</regeltypeForAarsregnskap>
        </regeltypeForAarsregnskap>
      </virksomhet>
    """
    |> String.trim_trailing()
  end

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
