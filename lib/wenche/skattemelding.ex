defmodule Wenche.Skattemelding do
  @moduledoc """
  Tax return generation for Norwegian AS (RF-1028 and RF-1167).

  Ported from `wenche/skattemelding.py` in the original Python Wenche project.

  Wenche produces a complete pre-filled summary that you use as reference
  when submitting the tax return manually at skatteetaten.no.

  Supports:
  - Standard 22% corporate tax calculation
  - Fritaksmetoden (participation exemption) for subsidiary dividends
  - Loss carryforward deduction
  - Prior year comparison figures
  - Equity reconciliation note

  > #### Experimental: Systemic submission {: .warning}
  >
  > Systemic submission of the skattemelding via Altinn 3 (`send_inn/4`)
  > is **untested and highly experimental**. It requires the submitting
  > system to be a registered revisor or regnskapsfører. The skattemelding
  > scope (`app_skd_formueinntekt-skattemelding-v2`) is not included in
  > the default system user rights — you must explicitly opt in via
  > `Wenche.Systembruker.rights([:skattemelding])`.
  >
  > The `beregn/2` and `generer/2` functions for local tax calculation
  > and report generation are stable and production-ready.
  """

  alias Wenche.Models.{
    Aarsregnskap,
    Anleggsmidler,
    Balanse,
    Driftsinntekter,
    Driftskostnader,
    Egenkapital,
    EgenkapitalOgGjeld,
    Eiendeler,
    Finansposter,
    KortsiktigGjeld,
    LangsiktigGjeld,
    Omloepmidler,
    Resultatregnskap,
    SkattemeldingKonfig
  }

  alias Wenche.{AltinnClient, SkattemeldingXml, SkdSkattemeldingClient}

  @skattesats 0.22

  @doc """
  Computes the tax return as a structured map.

  Returns a map with all computed values for RF-1167 and RF-1028,
  suitable for rendering in a UI or further processing.
  """
  def beregn(%Aarsregnskap{} = regnskap, %SkattemeldingKonfig{} = konfig) do
    r = regnskap.resultatregnskap
    b = regnskap.balanse
    s = regnskap.selskap
    aar = regnskap.regnskapsaar

    har_fjoraar =
      regnskap.foregaaende_aar_resultat != %Resultatregnskap{} or
        regnskap.foregaaende_aar_balanse != %Balanse{}

    rf_1028 = beregn_skattemelding(r, konfig)
    beregnet_skatt = rf_1028.beregnet_skatt
    aarsresultat = Resultatregnskap.resultat_foer_skatt(r) - beregnet_skatt

    %{
      selskap: %{navn: s.navn, org_nummer: s.org_nummer},
      regnskapsaar: aar,
      rf_1167: beregn_naeringsoppgave(r, beregnet_skatt, aarsresultat),
      rf_1028: rf_1028,
      balanse: beregn_balanse_oversikt(b),
      sammenligning: beregn_sammenligning(har_fjoraar, aar, regnskap),
      egenkapitalnote: beregn_egenkapitalnote(har_fjoraar, regnskap, aarsresultat),
      advarsler: beregn_advarsler(b, beregnet_skatt)
    }
  end

  defp beregn_naeringsoppgave(r, beregnet_skatt, aarsresultat) do
    %{
      driftsinntekter: %{
        salgsinntekter: r.driftsinntekter.salgsinntekter,
        andre_driftsinntekter: r.driftsinntekter.andre_driftsinntekter,
        sum: Driftsinntekter.sum(r.driftsinntekter)
      },
      driftskostnader: %{
        loennskostnader: r.driftskostnader.loennskostnader,
        avskrivninger: r.driftskostnader.avskrivninger,
        andre_driftskostnader: r.driftskostnader.andre_driftskostnader,
        sum: Driftskostnader.sum(r.driftskostnader)
      },
      driftsresultat: Resultatregnskap.driftsresultat(r),
      finansposter: %{
        utbytte_fra_datterselskap: r.finansposter.utbytte_fra_datterselskap,
        andre_finansinntekter: r.finansposter.andre_finansinntekter,
        rentekostnader: r.finansposter.rentekostnader,
        andre_finanskostnader: r.finansposter.andre_finanskostnader
      },
      resultat_foer_skatt: Resultatregnskap.resultat_foer_skatt(r),
      skattekostnad: -beregnet_skatt,
      aarsresultat: aarsresultat
    }
  end

  defp beregn_skattemelding(r, konfig) do
    driftsresultat = Resultatregnskap.driftsresultat(r)
    utbytte = r.finansposter.utbytte_fra_datterselskap
    andre_finansinntekter = r.finansposter.andre_finansinntekter
    fin_kostnader = Finansposter.sum_kostnader(r.finansposter)

    {skattepliktig_utbytte, fritatt_utbytte} =
      beregn_fritaksmetoden(konfig, utbytte)

    skattepliktig_inntekt_brutto =
      driftsresultat + skattepliktig_utbytte + andre_finansinntekter - fin_kostnader

    {fradrag_underskudd, skattepliktig_inntekt_netto, nytt_underskudd, beregnet_skatt} =
      beregn_skattepliktig_inntekt(skattepliktig_inntekt_brutto, konfig)

    fritaksmetoden =
      beregn_fritaksmetoden_detaljer(konfig, utbytte, skattepliktig_utbytte, fritatt_utbytte)

    %{
      driftsresultat: driftsresultat,
      utbytte: utbytte,
      fritaksmetoden: fritaksmetoden,
      andre_finansinntekter: andre_finansinntekter,
      finanskostnader: fin_kostnader,
      skattepliktig_inntekt_brutto: skattepliktig_inntekt_brutto,
      fradrag_underskudd: fradrag_underskudd,
      skattepliktig_inntekt_netto: skattepliktig_inntekt_netto,
      beregnet_skatt: beregnet_skatt,
      underskudd_til_fremfoering: if(nytt_underskudd > 0, do: nytt_underskudd, else: 0)
    }
  end

  defp beregn_fritaksmetoden(konfig, utbytte)
       when konfig.anvend_fritaksmetoden and utbytte > 0 do
    if konfig.eierandel_datterselskap >= 90 do
      {0, utbytte}
    else
      skattepliktig = ceil(utbytte * 0.03)
      {skattepliktig, utbytte - skattepliktig}
    end
  end

  defp beregn_fritaksmetoden(_konfig, utbytte), do: {utbytte, 0}

  defp beregn_fritaksmetoden_detaljer(konfig, utbytte, skattepliktig_utbytte, fritatt_utbytte)
       when konfig.anvend_fritaksmetoden and utbytte > 0 do
    %{
      fritatt_utbytte: fritatt_utbytte,
      skattepliktig_utbytte: skattepliktig_utbytte,
      eierandel_over_90: konfig.eierandel_datterselskap >= 90
    }
  end

  defp beregn_fritaksmetoden_detaljer(_konfig, _utbytte, _sp, _fr), do: nil

  defp beregn_skattepliktig_inntekt(brutto, konfig) do
    fradrag =
      if brutto > 0 and konfig.underskudd_til_fremfoering > 0 do
        min(konfig.underskudd_til_fremfoering, brutto)
      else
        0
      end

    netto = brutto - fradrag

    nytt_underskudd =
      if brutto < 0 do
        konfig.underskudd_til_fremfoering + abs(brutto)
      else
        konfig.underskudd_til_fremfoering - fradrag
      end

    skatt = if netto > 0, do: ceil(netto * @skattesats), else: 0

    {fradrag, netto, nytt_underskudd, skatt}
  end

  defp beregn_balanse_oversikt(b) do
    am = b.eiendeler.anleggsmidler
    om = b.eiendeler.omloepmidler
    ek = b.egenkapital_og_gjeld.egenkapital
    lg = b.egenkapital_og_gjeld.langsiktig_gjeld
    kg = b.egenkapital_og_gjeld.kortsiktig_gjeld

    %{
      eiendeler: %{
        anleggsmidler: %{
          aksjer_i_datterselskap: am.aksjer_i_datterselskap,
          andre_aksjer: am.andre_aksjer,
          langsiktige_fordringer: am.langsiktige_fordringer,
          sum: Anleggsmidler.sum(am)
        },
        omloepmidler: %{
          kortsiktige_fordringer: om.kortsiktige_fordringer,
          bankinnskudd: om.bankinnskudd,
          sum: Omloepmidler.sum(om)
        },
        sum: Eiendeler.sum(b.eiendeler)
      },
      egenkapital_og_gjeld: %{
        egenkapital: %{
          aksjekapital: ek.aksjekapital,
          overkursfond: ek.overkursfond,
          annen_egenkapital: ek.annen_egenkapital,
          sum: Egenkapital.sum(ek)
        },
        langsiktig_gjeld: %{
          laan_fra_aksjonaer: lg.laan_fra_aksjonaer,
          andre_langsiktige_laan: lg.andre_langsiktige_laan,
          sum: LangsiktigGjeld.sum(lg)
        },
        kortsiktig_gjeld: %{
          leverandoergjeld: kg.leverandoergjeld,
          skyldige_offentlige_avgifter: kg.skyldige_offentlige_avgifter,
          annen_kortsiktig_gjeld: kg.annen_kortsiktig_gjeld,
          sum: KortsiktigGjeld.sum(kg)
        },
        sum: EgenkapitalOgGjeld.sum(b.egenkapital_og_gjeld)
      },
      i_balanse: Balanse.er_i_balanse?(b),
      differanse: Balanse.differanse(b)
    }
  end

  defp beregn_sammenligning(false, _aar, _regnskap), do: nil

  defp beregn_sammenligning(true, aar, regnskap) do
    r = regnskap.resultatregnskap
    fr = regnskap.foregaaende_aar_resultat
    b = regnskap.balanse
    fb = regnskap.foregaaende_aar_balanse

    %{
      regnskapsaar: aar,
      foregaaende_aar: aar - 1,
      sum_driftsinntekter: %{
        aar: Driftsinntekter.sum(r.driftsinntekter),
        fjoraar: Driftsinntekter.sum(fr.driftsinntekter)
      },
      sum_driftskostnader: %{
        aar: Driftskostnader.sum(r.driftskostnader),
        fjoraar: Driftskostnader.sum(fr.driftskostnader)
      },
      driftsresultat: %{
        aar: Resultatregnskap.driftsresultat(r),
        fjoraar: Resultatregnskap.driftsresultat(fr)
      },
      netto_finansposter: %{
        aar:
          Finansposter.sum_inntekter(r.finansposter) -
            Finansposter.sum_kostnader(r.finansposter),
        fjoraar:
          Finansposter.sum_inntekter(fr.finansposter) -
            Finansposter.sum_kostnader(fr.finansposter)
      },
      resultat_foer_skatt: %{
        aar: Resultatregnskap.resultat_foer_skatt(r),
        fjoraar: Resultatregnskap.resultat_foer_skatt(fr)
      },
      sum_eiendeler: %{
        aar: Eiendeler.sum(b.eiendeler),
        fjoraar: Eiendeler.sum(fb.eiendeler)
      },
      sum_egenkapital_og_gjeld: %{
        aar: EgenkapitalOgGjeld.sum(b.egenkapital_og_gjeld),
        fjoraar: EgenkapitalOgGjeld.sum(fb.egenkapital_og_gjeld)
      }
    }
  end

  defp beregn_egenkapitalnote(false, regnskap, _aarsresultat) do
    ek_ub = regnskap.balanse.egenkapital_og_gjeld.egenkapital

    %{
      har_fjoraar: false,
      ek_ub: %{
        aksjekapital: ek_ub.aksjekapital,
        overkursfond: ek_ub.overkursfond,
        annen_egenkapital: ek_ub.annen_egenkapital
      }
    }
  end

  defp beregn_egenkapitalnote(true, regnskap, aarsresultat) do
    ek_ub = regnskap.balanse.egenkapital_og_gjeld.egenkapital
    ek_ib = regnskap.foregaaende_aar_balanse.egenkapital_og_gjeld.egenkapital
    forklart_aek = ek_ib.annen_egenkapital + aarsresultat - regnskap.utbytte_utbetalt
    andre_aek = ek_ub.annen_egenkapital - forklart_aek

    %{
      har_fjoraar: true,
      ek_ib: %{
        aksjekapital: ek_ib.aksjekapital,
        overkursfond: ek_ib.overkursfond,
        annen_egenkapital: ek_ib.annen_egenkapital
      },
      ek_ub: %{
        aksjekapital: ek_ub.aksjekapital,
        overkursfond: ek_ub.overkursfond,
        annen_egenkapital: ek_ub.annen_egenkapital
      },
      aarsresultat: aarsresultat,
      utbytte_utbetalt: regnskap.utbytte_utbetalt,
      andre_endringer: %{
        aksjekapital: ek_ub.aksjekapital - ek_ib.aksjekapital,
        overkursfond: ek_ub.overkursfond - ek_ib.overkursfond,
        annen_egenkapital: andre_aek
      }
    }
  end

  defp beregn_advarsler(b, beregnet_skatt) do
    i_balanse = Balanse.er_i_balanse?(b)
    differanse = Balanse.differanse(b)

    []
    |> maybe_add_advarsel(
      not i_balanse,
      "Balansen stemmer ikke! Differanse: #{differanse} kr"
    )
    |> maybe_add_advarsel(
      beregnet_skatt > 0,
      "Beregnet skatt er #{beregnet_skatt} kr. Husk å føre dette som «Skyldig skatt» (konto 2500) under kortsiktig gjeld i balansen, og kontroller at balansen fortsatt går opp."
    )
  end

  defp maybe_add_advarsel(list, true, msg), do: list ++ [msg]
  defp maybe_add_advarsel(list, false, _msg), do: list

  @doc """
  Generates a complete pre-filled summary for RF-1167 and RF-1028.

  Returns the report as a string.
  """
  def generer(%Aarsregnskap{} = regnskap, %SkattemeldingKonfig{} = konfig) do
    beregning = beregn(regnskap, konfig)

    r = regnskap.resultatregnskap
    b = regnskap.balanse
    s = regnskap.selskap
    aar = regnskap.regnskapsaar
    fr = regnskap.foregaaende_aar_resultat
    fb = regnskap.foregaaende_aar_balanse

    har_fjoraar = fr != %Resultatregnskap{} or fb != %Balanse{}

    driftsinntekter = beregning.rf_1167.driftsinntekter.sum
    driftskostnader = beregning.rf_1167.driftskostnader.sum
    driftsresultat = beregning.rf_1167.driftsresultat
    fin_kostnader = beregning.rf_1028.finanskostnader
    resultat_foer_skatt = beregning.rf_1167.resultat_foer_skatt
    utbytte = beregning.rf_1028.utbytte
    andre_finansinntekter = beregning.rf_1028.andre_finansinntekter
    skattepliktig_inntekt_brutto = beregning.rf_1028.skattepliktig_inntekt_brutto
    fradrag_underskudd = beregning.rf_1028.fradrag_underskudd
    skattepliktig_inntekt_netto = beregning.rf_1028.skattepliktig_inntekt_netto
    beregnet_skatt = beregning.rf_1028.beregnet_skatt
    nytt_underskudd = beregning.rf_1028.underskudd_til_fremfoering

    fritatt_utbytte =
      if beregning.rf_1028.fritaksmetoden,
        do: beregning.rf_1028.fritaksmetoden.fritatt_utbytte,
        else: 0

    skattepliktig_utbytte =
      if beregning.rf_1028.fritaksmetoden,
        do: beregning.rf_1028.fritaksmetoden.skattepliktig_utbytte,
        else: utbytte

    i_balanse = beregning.balanse.i_balanse
    differanse = beregning.balanse.differanse

    linje = String.duplicate("─", 60)
    bred = String.duplicate("═", 60)

    linjer =
      [
        bred,
        "  SKATTEMELDING FOR AS — #{aar}",
        "  #{s.navn}  |  Org.nr. #{s.org_nummer}",
        bred,
        "",
        linje,
        "  RF-1167  NÆRINGSOPPGAVE",
        linje,
        "",
        "  DRIFTSINNTEKTER",
        "    Salgsinntekter               #{nok(r.driftsinntekter.salgsinntekter)}",
        "    Andre driftsinntekter        #{nok(r.driftsinntekter.andre_driftsinntekter)}",
        "  Sum driftsinntekter            #{nok(driftsinntekter)}",
        "",
        "  DRIFTSKOSTNADER",
        "    Lønnskostnader               #{nok(r.driftskostnader.loennskostnader)}",
        "    Avskrivninger                #{nok(r.driftskostnader.avskrivninger)}",
        "    Andre driftskostnader        #{nok(r.driftskostnader.andre_driftskostnader)}",
        "  Sum driftskostnader            #{nok(driftskostnader)}",
        "",
        "  DRIFTSRESULTAT                 #{nok(driftsresultat)}",
        "",
        "  FINANSPOSTER",
        "    Utbytte fra datterselskap    #{nok(utbytte)}",
        "    Andre finansinntekter        #{nok(andre_finansinntekter)}",
        "    Rentekostnader               #{nok(r.finansposter.rentekostnader)}",
        "    Andre finanskostnader        #{nok(r.finansposter.andre_finanskostnader)}",
        "",
        "  RESULTAT FØR SKATT             #{nok(resultat_foer_skatt)}",
        "  Skattekostnad                  #{nok(-beregnet_skatt)}",
        "  ÅRSRESULTAT                    #{nok(resultat_foer_skatt - beregnet_skatt)}",
        "",
        linje,
        "  RF-1028  SKATTEMELDING FOR AS",
        linje,
        "",
        "  INNTEKTER OG FRADRAG",
        "    Driftsresultat               #{nok(driftsresultat)}"
      ] ++
        fritaksmetoden_linjer(konfig, utbytte, fritatt_utbytte, skattepliktig_utbytte) ++
        [
          "    Andre finansinntekter        #{nok(andre_finansinntekter)}",
          "    Finanskostnader             -#{nok(fin_kostnader)}",
          "  Skattepliktig inntekt (brutto) #{nok(skattepliktig_inntekt_brutto)}"
        ] ++
        underskudd_linjer(fradrag_underskudd) ++
        [
          "  SKATTEPLIKTIG INNTEKT (NETTO)  #{nok(skattepliktig_inntekt_netto)}",
          "",
          "  Beregnet skatt (22 %)          #{nok(beregnet_skatt)}",
          ""
        ] ++
        fremforing_linjer(nytt_underskudd) ++
        balanse_linjer(b) ++
        sammenligning_linjer(har_fjoraar, aar, r, fr, b, fb) ++
        egenkapital_note_linjer(har_fjoraar, aar, regnskap, beregnet_skatt) ++
        balanse_kontroll_linjer(i_balanse, differanse) ++
        skatt_varsel_linjer(beregnet_skatt) ++
        neste_steg_linjer(aar, bred)

    Enum.join(linjer, "\n") <> "\n"
  end

  defp fritaksmetoden_linjer(konfig, utbytte, fritatt_utbytte, skattepliktig_utbytte) do
    if konfig.anvend_fritaksmetoden and utbytte > 0 do
      if konfig.eierandel_datterselskap >= 90 do
        ["    Utbytte (100 % fritatt)      #{nok(fritatt_utbytte)}"]
      else
        [
          "    Utbytte (fritatt, 97 %)      #{nok(fritatt_utbytte)}",
          "    Utbytte (sjablonregel, 3 %)  #{nok(skattepliktig_utbytte)}"
        ]
      end
    else
      ["    Utbytte                      #{nok(utbytte)}"]
    end
  end

  defp underskudd_linjer(0), do: []

  defp underskudd_linjer(fradrag) do
    ["  Fradrag: fremf. underskudd  -#{nok(fradrag)}"]
  end

  defp fremforing_linjer(0), do: []

  defp fremforing_linjer(nytt_underskudd) when nytt_underskudd > 0 do
    [
      "  Underskudd til fremføring      #{nok(nytt_underskudd)}",
      "  (føres på skattemeldingen under «Underskudd til fremføring»)",
      ""
    ]
  end

  defp fremforing_linjer(_), do: []

  defp balanse_linjer(b) do
    am = b.eiendeler.anleggsmidler
    om = b.eiendeler.omloepmidler
    ek = b.egenkapital_og_gjeld.egenkapital
    lg = b.egenkapital_og_gjeld.langsiktig_gjeld
    kg = b.egenkapital_og_gjeld.kortsiktig_gjeld
    linje = String.duplicate("─", 60)

    [
      linje,
      "  RF-1167  BALANSE",
      linje,
      "",
      "  EIENDELER",
      "    Anleggsmidler:",
      "      Aksjer i datterselskap      #{nok(am.aksjer_i_datterselskap)}",
      "      Andre aksjer                #{nok(am.andre_aksjer)}",
      "      Langsiktige fordringer      #{nok(am.langsiktige_fordringer)}",
      "    Sum anleggsmidler             #{nok(Anleggsmidler.sum(am))}",
      "",
      "    Omløpsmidler:",
      "      Kortsiktige fordringer      #{nok(om.kortsiktige_fordringer)}",
      "      Bankinnskudd                #{nok(om.bankinnskudd)}",
      "    Sum omløpsmidler              #{nok(Omloepmidler.sum(om))}",
      "",
      "  SUM EIENDELER                  #{nok(Eiendeler.sum(b.eiendeler))}",
      "",
      "  EGENKAPITAL OG GJELD",
      "    Egenkapital:",
      "      Aksjekapital                #{nok(ek.aksjekapital)}",
      "      Overkursfond                #{nok(ek.overkursfond)}",
      "      Annen egenkapital           #{nok(ek.annen_egenkapital)}",
      "    Sum egenkapital               #{nok(Egenkapital.sum(ek))}",
      "",
      "    Langsiktig gjeld:",
      "      Lån fra aksjonær            #{nok(lg.laan_fra_aksjonaer)}",
      "      Andre langsiktige lån       #{nok(lg.andre_langsiktige_laan)}",
      "    Sum langsiktig gjeld          #{nok(LangsiktigGjeld.sum(lg))}",
      "",
      "    Kortsiktig gjeld:",
      "      Leverandørgjeld             #{nok(kg.leverandoergjeld)}",
      "      Skyldige offentlige avgifter #{nok(kg.skyldige_offentlige_avgifter)}",
      "      Annen kortsiktig gjeld      #{nok(kg.annen_kortsiktig_gjeld)}",
      "    Sum kortsiktig gjeld          #{nok(KortsiktigGjeld.sum(kg))}",
      "",
      "  SUM EGENKAPITAL OG GJELD       #{nok(EgenkapitalOgGjeld.sum(b.egenkapital_og_gjeld))}",
      ""
    ]
  end

  defp sammenligning_linjer(false, aar, _r, _fr, _b, _fb) do
    [
      "",
      "  NB: Sammenligningstall for #{aar - 1} er ikke lagt inn.",
      "  Legg til 'foregaaende_aar' i config.yaml (påkrevd, jf. rskl. § 6-6).",
      ""
    ]
  end

  defp sammenligning_linjer(true, aar, r, fr, b, fb) do
    netto_finans_fjor =
      Finansposter.sum_inntekter(fr.finansposter) - Finansposter.sum_kostnader(fr.finansposter)

    linje = String.duplicate("─", 60)

    [
      "",
      linje,
      "  RF-1167  SAMMENLIGNINGSTALL  (rskl. § 6-6)",
      linje,
      "                                 #{pad_right(aar, 12)}   #{pad_right(aar - 1, 12)}",
      "  Sum driftsinntekter          #{nok2(Driftsinntekter.sum(r.driftsinntekter), Driftsinntekter.sum(fr.driftsinntekter))}",
      "  Sum driftskostnader          #{nok2(Driftskostnader.sum(r.driftskostnader), Driftskostnader.sum(fr.driftskostnader))}",
      "  Driftsresultat               #{nok2(Resultatregnskap.driftsresultat(r), Resultatregnskap.driftsresultat(fr))}",
      "  Netto finansposter           #{nok2(Finansposter.sum_inntekter(r.finansposter) - Finansposter.sum_kostnader(r.finansposter), netto_finans_fjor)}",
      "  RESULTAT FØR SKATT           #{nok2(Resultatregnskap.resultat_foer_skatt(r), Resultatregnskap.resultat_foer_skatt(fr))}",
      "  SUM EIENDELER                #{nok2(Eiendeler.sum(b.eiendeler), Eiendeler.sum(fb.eiendeler))}",
      "  SUM EGENKAPITAL OG GJELD     #{nok2(EgenkapitalOgGjeld.sum(b.egenkapital_og_gjeld), EgenkapitalOgGjeld.sum(fb.egenkapital_og_gjeld))}",
      ""
    ]
  end

  defp egenkapital_note_linjer(har_fjoraar, aar, regnskap, beregnet_skatt) do
    linje = String.duplicate("─", 60)
    b = regnskap.balanse
    ek_ub = b.egenkapital_og_gjeld.egenkapital

    aarsresultat =
      Resultatregnskap.resultat_foer_skatt(regnskap.resultatregnskap) - beregnet_skatt

    header_linjer = [
      "",
      linje,
      "  NOTE: EGENKAPITAL  (rskl. § 7-2b)",
      linje,
      "  #{pad_left("", 20)}#{pad_left("AK-kapital", 12)}#{pad_left("Overkursfond", 12)}#{pad_left("Annen EK", 12)}#{pad_left("Sum", 12)}"
    ]

    body_linjer =
      if har_fjoraar do
        fb = regnskap.foregaaende_aar_balanse
        ek_ib = fb.egenkapital_og_gjeld.egenkapital
        delta_ak = ek_ub.aksjekapital - ek_ib.aksjekapital
        delta_ok = ek_ub.overkursfond - ek_ib.overkursfond
        forklart_aek = ek_ib.annen_egenkapital + aarsresultat - regnskap.utbytte_utbetalt
        andre_aek = ek_ub.annen_egenkapital - forklart_aek

        base = [
          ek_rad(
            "EK 01.01.#{aar}",
            ek_ib.aksjekapital,
            ek_ib.overkursfond,
            ek_ib.annen_egenkapital
          ),
          ek_rad("Årsresultat", 0, 0, aarsresultat)
        ]

        utbytte_linje =
          if regnskap.utbytte_utbetalt != 0 do
            [ek_rad("Utbytte utbetalt", 0, 0, -regnskap.utbytte_utbetalt)]
          else
            []
          end

        andre_linje =
          if delta_ak != 0 or delta_ok != 0 or andre_aek != 0 do
            [ek_rad("Andre endringer", delta_ak, delta_ok, andre_aek)]
          else
            []
          end

        slutt = [
          ek_rad(
            "EK 31.12.#{aar}",
            ek_ub.aksjekapital,
            ek_ub.overkursfond,
            ek_ub.annen_egenkapital
          )
        ]

        base ++ utbytte_linje ++ andre_linje ++ slutt
      else
        [
          "  NB: Egenkapitalbevegelse krever foregaaende_aar (rskl. § 7-2b).",
          ek_rad(
            "EK 31.12.#{aar}",
            ek_ub.aksjekapital,
            ek_ub.overkursfond,
            ek_ub.annen_egenkapital
          )
        ]
      end

    header_linjer ++ body_linjer ++ ["  (beløp i hele kroner, NOK)", ""]
  end

  defp balanse_kontroll_linjer(true, _), do: ["  Balansekontroll: OK"]

  defp balanse_kontroll_linjer(false, differanse) do
    ["  ADVARSEL: Balansen stemmer ikke! Differanse: #{nok(differanse)}"]
  end

  defp skatt_varsel_linjer(0), do: []

  defp skatt_varsel_linjer(beregnet_skatt) do
    [
      "",
      "  NB: Beregnet skatt er #{String.trim(nok(beregnet_skatt))}. Husk å føre dette",
      "  som «Skyldig skatt» (konto 2500) under kortsiktig gjeld i balansen,",
      "  og kontroller at balansen fortsatt går opp."
    ]
  end

  defp neste_steg_linjer(aar, bred) do
    [
      "",
      bred,
      "  NESTE STEG",
      bred,
      "",
      "  1. Gå til https://www.skatteetaten.no/ og logg inn med BankID.",
      "  2. Åpne skattemeldingen for AS for #{aar}.",
      "  3. Fyll inn tallene fra RF-1167 og RF-1028 ovenfor.",
      "  4. Kontroller at skatteetaten beregner samme skatt.",
      "  5. Send inn innen 31. mai.",
      "",
      bred
    ]
  end

  defp nok(amount) do
    formatted =
      amount
      |> abs()
      |> Integer.to_string()
      |> String.reverse()
      |> String.to_charlist()
      |> Enum.chunk_every(3)
      |> Enum.join(" ")
      |> String.reverse()

    sign = if amount < 0, do: "-", else: ""
    String.pad_leading("#{sign}#{formatted} kr", 12)
  end

  defp nok2(aarets, fjoraarets) do
    "#{nok(aarets)}   #{nok(fjoraarets)}"
  end

  defp ekk(v) do
    String.pad_leading(Integer.to_string(v) |> add_thousand_sep(), 12)
  end

  defp add_thousand_sep(str) do
    str
    |> String.reverse()
    |> String.to_charlist()
    |> Enum.chunk_every(3)
    |> Enum.join(" ")
    |> String.reverse()
  end

  defp ek_rad(label, ak, ok, aek) do
    s = ak + ok + aek
    "  #{pad_left(label, 20)}#{ekk(ak)}#{ekk(ok)}#{ekk(aek)}#{ekk(s)}"
  end

  defp pad_left(str, width), do: String.pad_leading(to_string(str), width)
  defp pad_right(str, width), do: String.pad_trailing(to_string(str), width)

  # ── Submission ──────────────────────────────────────────────────────

  @doc """
  Submits the tax return to Skatteetaten via Altinn 3.

  Generates XML documents from the given `Aarsregnskap` and `SkattemeldingKonfig`,
  then submits via the Altinn 3 skattemelding app.

  ## Options

  - `:dry_run` — if true, writes XML files locally without submitting (default: false)
  - `:dokumentidentifikator` — reference to draft (from `hent_utkast`)

  Returns `{:ok, inbox_url}` or `{:ok, {:dry_run, files}}` or `{:error, reason}`.
  """
  def send_inn(
        %Aarsregnskap{} = regnskap,
        %SkattemeldingKonfig{} = konfig,
        %AltinnClient{} = client,
        opts \\ []
      ) do
    dry_run = Keyword.get(opts, :dry_run, false)
    org = regnskap.selskap.org_nummer
    aar = regnskap.regnskapsaar

    skd_client = Keyword.get(opts, :skd_client)

    case resolve_utkast_referanse(opts, skd_client, aar, org) do
      {:ok, ref} ->
        do_send_inn(regnskap, konfig, client, opts, ref, dry_run)

      {:error, reason} ->
        {:error, {:utkast_referanse_failed, reason}}
    end
  end

  defp do_send_inn(regnskap, konfig, client, opts, ref, dry_run) do
    org = regnskap.selskap.org_nummer
    aar = regnskap.regnskapsaar

    xml_opts = [partsnummer: ref.partsnummer]

    skattemelding_xml = SkattemeldingXml.generer_skattemelding_xml(regnskap, konfig, xml_opts)
    naering_xml = SkattemeldingXml.generer_naeringsspesifikasjon_xml(regnskap, xml_opts)

    request_xml =
      SkattemeldingXml.generer_request_xml(
        skattemelding_xml,
        naering_xml,
        request_envelope_opts(opts, aar, org, ref)
      )

    if dry_run do
      skattemelding_fil = "skattemelding_#{aar}_#{org}_skattemelding.xml"
      naering_fil = "skattemelding_#{aar}_#{org}_naeringsspesifikasjon.xml"
      request_fil = "skattemelding_#{aar}_#{org}_request.xml"
      File.write!(skattemelding_fil, skattemelding_xml)
      File.write!(naering_fil, naering_xml)
      File.write!(request_fil, request_xml)

      {:ok, {:dry_run, skattemelding_fil, naering_fil, request_fil}}
    else
      with {:ok, instans} <- AltinnClient.opprett_instans(client, "skattemelding", org),
           {:ok, _} <-
             AltinnClient.oppdater_data_element(
               client,
               "skattemelding",
               instans,
               "skattemelding",
               request_xml,
               "application/xml"
             ) do
        AltinnClient.fullfoor_instans(client, "skattemelding", instans)
      end
    end
  end

  @doc """
  Validates the tax return against Skatteetaten's validation API.

  Generates XML documents and sends them to the validation endpoint.

  Returns `{:ok, validation_result}` or `{:error, reason}`.
  """
  def valider(
        %Aarsregnskap{} = regnskap,
        %SkattemeldingKonfig{} = konfig,
        %SkdSkattemeldingClient{} = skd_client,
        opts \\ []
      ) do
    aar = regnskap.regnskapsaar
    org = regnskap.selskap.org_nummer

    case resolve_utkast_referanse(opts, skd_client, aar, org) do
      {:ok, ref} ->
        xml_opts = [partsnummer: ref.partsnummer]

        skattemelding_xml =
          SkattemeldingXml.generer_skattemelding_xml(regnskap, konfig, xml_opts)

        naering_xml = SkattemeldingXml.generer_naeringsspesifikasjon_xml(regnskap, xml_opts)

        request_xml =
          SkattemeldingXml.generer_request_xml(
            skattemelding_xml,
            naering_xml,
            request_envelope_opts(opts, aar, org, ref)
          )

        SkdSkattemeldingClient.valider(skd_client, aar, org, request_xml)

      {:error, reason} ->
        {:error, {:utkast_referanse_failed, reason}}
    end
  end

  # Resolves both the company's partsnummer and the dokumentidentifikator(s)
  # for `<dokumentreferanseTilGjeldendeDokument>` in one fetch from
  # `GET /api/skattemelding/v2/{year}/{org}`. Without the dokumentreferanse,
  # Skatteetaten's /valider and /innsendelse reject the request with
  # `innkommendeForespoerselManglerReferanseTilGjeldendeSkattemelding`.
  defp resolve_utkast_referanse(opts, skd_client, aar, org) do
    case Keyword.get(opts, :partsnummer) do
      partsnummer when is_integer(partsnummer) ->
        {:ok,
         %{
           partsnummer: partsnummer,
           skattemelding_id: Keyword.get(opts, :dokumentidentifikator),
           naering_id: nil
         }}

      _ ->
        if is_nil(skd_client) do
          {:ok, %{partsnummer: org, skattemelding_id: nil, naering_id: nil}}
        else
          SkdSkattemeldingClient.hent_utkast_referanse(skd_client, aar, org)
        end
    end
  end

  defp request_envelope_opts(opts, aar, org, ref) do
    base = [inntektsaar: aar, tin: org]

    sm_id = ref.skattemelding_id || Keyword.get(opts, :dokumentidentifikator)
    ne_id = ref.naering_id

    refs =
      []
      |> append_ref("skattemeldingUpersonlig", sm_id)
      |> append_ref("naeringsspesifikasjon", ne_id)

    if refs == [] do
      base
    else
      Keyword.put(base, :dokumentreferanse, refs)
    end
  end

  defp append_ref(acc, _type, nil), do: acc
  defp append_ref(acc, _type, ""), do: acc
  defp append_ref(acc, type, id), do: acc ++ [{type, id}]
end
