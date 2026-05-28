defmodule Wenche.Skattemelding do
  @moduledoc """
  Tax return computation and submission for Norwegian AS (RF-1028 and RF-1167).

  Ported from `wenche/skattemelding.py` in the original Python Wenche project.

  - `beregn/2` returns the computed tax return as a structured map suitable
    for rendering in a UI or further processing.
  - `valider/2` and `send_inn/2` orchestrate validation and submission via
    Skatteetaten / Altinn 3.

  Supports:
  - Standard 22 % corporate tax calculation
  - Fritaksmetoden (participation exemption) for subsidiary dividends
  - Loss carryforward deduction
  - Caller-supplied `:permanent_forskjeller` on `SkattemeldingKonfig`
  - Prior year comparison figures and equity reconciliation note (via `beregn/2`)

  ## Authentication

  Validation and submission use different auth flows:

  - **Validation** (`valider/3` → `SkdSkattemeldingClient`) works with a
    Maskinporten + systemuser token, obtained via
    `Wenche.Maskinporten.get_skd_skattemelding_token/2`. The
    `altinn:instances.read`/`.write` scopes in that token are required so
    Skatteetaten can resolve the systemuser → executor trace via Altinn.
  - **Submission** (`send_inn/4` → `AltinnClient`) requires an Altinn
    platform token obtained from **ID-porten** (end-user authentication +
    Altinn token exchange). Skatteetaten does **not** accept a system user
    for the submission step. Wenche does not provide an ID-porten flow —
    callers must obtain the Altinn token themselves and pass it via
    `AltinnClient.new/2`.

  > #### Experimental: Systemic submission {: .warning}
  >
  > Systemic submission of the skattemelding via Altinn 3 (`send_inn/4`)
  > is **untested and highly experimental**. It also requires the
  > submitting end-user to be a registered revisor or regnskapsfører.
  > Enable `Wenche.Systembruker.rights([:skattemelding])` for the
  > validation flow; it has no effect on submission since that goes
  > through ID-porten.
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

    {skattepliktig_inntekt_brutto, skattepliktig_utbytte, fritatt_utbytte} =
      compute_skattepliktig_brutto(
        driftsresultat,
        utbytte,
        andre_finansinntekter,
        fin_kostnader,
        konfig
      )

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

  # When konfig carries a holding-driven `:permanent_forskjeller` breakdown,
  # use it as the source of truth: start from the full regnskapsmessig resultat
  # (which already INCLUDES the utbytte in P&L) and fold in each permanent
  # forskjell. This is what SKD's /valider does, so the wizard's RF-1028 lines
  # up with the post-calculation response.
  #
  # When `:permanent_forskjeller` is not set we fall back to the legacy global
  # eierandel_datterselskap heuristic — backwards-compatible for callers that
  # haven't migrated yet.
  defp compute_skattepliktig_brutto(
         driftsresultat,
         utbytte,
         andre_finansinntekter,
         fin_kostnader,
         %SkattemeldingKonfig{permanent_forskjeller: pf} = _konfig
       )
       when is_list(pf) do
    regnskapsmessig =
      driftsresultat + utbytte + andre_finansinntekter - fin_kostnader

    # Sum each beloep as Decimal with the right sign per type, then round
    # ONCE :half_up to integer. Per-line rounding would drop the cumulative
    # fractional cents that Skatteetaten / Fiken pick up by rounding once.
    {regnskapsmessig + permanent_forskjell_adjustment(pf), 0, 0}
  end

  defp compute_skattepliktig_brutto(
         driftsresultat,
         utbytte,
         andre_finansinntekter,
         fin_kostnader,
         konfig
       ) do
    {skattepliktig_utbytte, fritatt_utbytte} = beregn_fritaksmetoden(konfig, utbytte)

    brutto =
      driftsresultat + skattepliktig_utbytte + andre_finansinntekter - fin_kostnader

    {brutto, skattepliktig_utbytte, fritatt_utbytte}
  end

  # Permanent forskjeller adjust regnskapsmessig → skattemessig.
  # Reversals (utbytte, gevinst) reduce inntekt; add-backs (3 %, tap) raise it.
  # Sums in Decimal and rounds the total :half_up once so per-line rounding
  # noise doesn't drift the brutto by 1 kr.
  defp permanent_forskjell_adjustment(pf) do
    pf
    |> Enum.reduce(Decimal.new(0), fn entry, acc ->
      case entry do
        %{type: :tilbakefoeringAvInntektsfoertUtbytte, beloep: b} ->
          Decimal.sub(acc, to_decimal(b))

        %{type: :skattepliktigDelAvUtbytterOgUtdelinger, beloep: b} ->
          Decimal.add(acc, to_decimal(b))

        %{type: :regnskapsmessigGevinstVedRealisasjonAvFinansielleInstrumenter, beloep: b} ->
          Decimal.sub(acc, to_decimal(b))

        %{type: :regnskapsmessigTapVedRealisasjonAvFinansielleInstrumenter, beloep: b} ->
          Decimal.add(acc, to_decimal(b))

        _ ->
          acc
      end
    end)
    |> Decimal.round(0, :half_up)
    |> Decimal.to_integer()
  end

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)

  @doc """
  Returns `{sum_tillegg, sum_fradrag}` as positive integers from a list of
  permanent forskjeller. Used by the XML emitter to populate the derived
  `<sumTilleggINaeringsinntekt>` / `<sumFradragINaeringsinntekt>` elements
  Skatteetaten flags as missing.
  """
  def permanent_forskjeller_tillegg_fradrag([]), do: {0, 0}

  def permanent_forskjeller_tillegg_fradrag(pf) when is_list(pf) do
    Enum.reduce(pf, {Decimal.new(0), Decimal.new(0)}, fn entry, {t, f} ->
      case entry do
        %{type: :tilbakefoeringAvInntektsfoertUtbytte, beloep: b} ->
          {t, Decimal.add(f, to_decimal(b))}

        %{type: :skattepliktigDelAvUtbytterOgUtdelinger, beloep: b} ->
          {Decimal.add(t, to_decimal(b)), f}

        %{type: :regnskapsmessigGevinstVedRealisasjonAvFinansielleInstrumenter, beloep: b} ->
          {t, Decimal.add(f, to_decimal(b))}

        %{type: :regnskapsmessigTapVedRealisasjonAvFinansielleInstrumenter, beloep: b} ->
          {Decimal.add(t, to_decimal(b)), f}

        _ ->
          {t, f}
      end
    end)
    |> then(fn {t, f} ->
      {t |> Decimal.round(0, :half_up) |> Decimal.to_integer(),
       f |> Decimal.round(0, :half_up) |> Decimal.to_integer()}
    end)
  end

  @doc """
  Computes the skattepliktig næringsinntekt brutto (the "skattemessig
  resultat") for a given regnskap and permanent_forskjeller list.

  Used by the XML emitter to populate `<beregnetNaeringsinntekt>` /
  `<skattemessigResultat>` and the underskudd-derived elements
  Skatteetaten flags as missing. Mirrors what `beregn/2` already
  computes internally for `rf_1028.skattepliktig_inntekt_brutto`.
  """
  def derive_skattepliktig_brutto(%Aarsregnskap{} = regnskap, permanent_forskjeller)
      when is_list(permanent_forskjeller) do
    r = regnskap.resultatregnskap
    driftsresultat = Resultatregnskap.driftsresultat(r)
    utbytte = r.finansposter.utbytte_fra_datterselskap
    andre_finansinntekter = r.finansposter.andre_finansinntekter
    fin_kostnader = Finansposter.sum_kostnader(r.finansposter)

    regnskapsmessig = driftsresultat + utbytte + andre_finansinntekter - fin_kostnader
    regnskapsmessig + permanent_forskjell_adjustment(permanent_forskjeller)
  end

  def derive_skattepliktig_brutto(regnskap, _), do: derive_skattepliktig_brutto(regnskap, [])

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

  @doc """
  Builds the data needed for `<egenkapitalavstemming>` in
  næringsspesifikasjonen.

  Returns a map with:

    * `:inngaaende_ek` — IB total egenkapital in whole kroner.
    * `:utgaaende_ek` — UB total egenkapital in whole kroner.
    * `:endringer` — list of `%{id, type, kategori, beloep}` rows describing
      each årets endring. `beloep` is always emitted as a positive integer;
      `kategori` (`:tillegg` or `:fradrag`) tells the consumer which sign
      to apply. `type` is a kode from the `2025_egenkapitalendringstype`
      kodeliste.
    * `:sum_tillegg`, `:sum_fradrag` — derived sums for the optional XSD
      elements.

  When the regnskap has no fjoraar data, IB is `0` and årsresultat is
  treated as the entire build-up of EK.
  """
  def beregn_egenkapitalavstemming(%Aarsregnskap{} = regnskap) do
    rf_1028 = beregn_skattemelding(regnskap.resultatregnskap, %SkattemeldingKonfig{})

    aarsresultat =
      Resultatregnskap.resultat_foer_skatt(regnskap.resultatregnskap) - rf_1028.beregnet_skatt

    ek_ub = regnskap.balanse.egenkapital_og_gjeld.egenkapital
    utgaaende_ek = ek_ub.aksjekapital + ek_ub.overkursfond + ek_ub.annen_egenkapital

    har_fjoraar =
      regnskap.foregaaende_aar_resultat != %Resultatregnskap{} or
        regnskap.foregaaende_aar_balanse != %Balanse{}

    {inngaaende_ek, kapital_delta, annen_residual} =
      if har_fjoraar do
        ek_ib = regnskap.foregaaende_aar_balanse.egenkapital_og_gjeld.egenkapital
        ib = ek_ib.aksjekapital + ek_ib.overkursfond + ek_ib.annen_egenkapital

        kap_delta =
          ek_ub.aksjekapital - ek_ib.aksjekapital +
            (ek_ub.overkursfond - ek_ib.overkursfond)

        residual =
          ek_ub.annen_egenkapital -
            (ek_ib.annen_egenkapital + aarsresultat - regnskap.utbytte_utbetalt)

        {ib, kap_delta, residual}
      else
        {0, 0, ek_ub.annen_egenkapital - (aarsresultat - regnskap.utbytte_utbetalt)}
      end

    endringer =
      []
      |> maybe_add_endring(aarsresultat > 0, "aaretsOverskudd", :tillegg, aarsresultat)
      |> maybe_add_endring(aarsresultat < 0, "aaretsUnderskudd", :fradrag, -aarsresultat)
      |> maybe_add_endring(
        regnskap.utbytte_utbetalt > 0,
        "avsattEllerForventetUtbytte",
        :fradrag,
        regnskap.utbytte_utbetalt
      )
      |> maybe_add_endring(kapital_delta > 0, "kontantinnskudd", :tillegg, kapital_delta)
      |> maybe_add_endring(
        kapital_delta < 0,
        "nedsettelseAvAksjekapitalOgUtdelingAvOverkursKontanter",
        :fradrag,
        -kapital_delta
      )
      |> maybe_add_endring(
        annen_residual > 0,
        "annenPositivEndringIEgenkapital",
        :tillegg,
        annen_residual
      )
      |> maybe_add_endring(
        annen_residual < 0,
        "annenNegativEndringIEgenkapital",
        :fradrag,
        -annen_residual
      )
      |> Enum.with_index(1)
      |> Enum.map(fn {row, i} -> Map.put(row, :id, Integer.to_string(i)) end)

    sum_tillegg =
      endringer |> Enum.filter(&(&1.kategori == :tillegg)) |> Enum.map(& &1.beloep) |> Enum.sum()

    sum_fradrag =
      endringer |> Enum.filter(&(&1.kategori == :fradrag)) |> Enum.map(& &1.beloep) |> Enum.sum()

    %{
      inngaaende_ek: inngaaende_ek,
      utgaaende_ek: utgaaende_ek,
      endringer: endringer,
      sum_tillegg: sum_tillegg,
      sum_fradrag: sum_fradrag
    }
  end

  defp maybe_add_endring(list, false, _type, _kategori, _beloep), do: list

  defp maybe_add_endring(list, true, type, kategori, beloep),
    do: list ++ [%{type: type, kategori: kategori, beloep: beloep}]

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
  Parses Skatteetaten's `/valider` response and extracts the SKD-computed
  values from the embedded `skattemeldingUpersonligEtterBeregning` document.

  SKD echoes back the skattemelding with derived (`skatt:erAvledet="true"`)
  elements populated — those are the numbers callers want to display alongside
  a successful validation, since they're what Skatteetaten will use for tax
  assessment.

  Returns a map with the extracted fields. Fields that aren't present in the
  response (which is normal — many are optional and only emitted when
  applicable) come back as `nil`.

  ## Extracted fields

    * `:partsnummer` — SKD's resolved partsnummer
    * `:inntektsaar`
    * `:inntekt_foer_fradrag_for_eventuelt_avgitt_konsernbidrag` — taxable
      income before group contribution deduction (negative on a loss year)
    * `:samlet_inntekt` — total income after deductions (zero on a loss year)
    * `:samlet_underskudd` — year-loss
    * `:fremfoert_underskudd_fra_tidligere_aar` — prior-year carryforward used
    * `:fremfoerbart_underskudd_i_inntekt` — total loss available for future
      carryforward (prior + this year's added)
    * `:netto_formue` — net wealth
    * `:samlet_formuesverdi_etter_verdsettingsrabatt`
    * `:samlet_gjeld`

  Pass the raw response body from `valider/4`'s `{:ok, body}` tuple.
  """
  @spec parse_etter_beregning(binary()) :: map()
  def parse_etter_beregning(body) when is_binary(body) do
    case extract_etter_beregning_xml(body) do
      nil ->
        %{}

      inner ->
        %{
          partsnummer: extract_int(inner, "partsnummer"),
          inntektsaar: extract_int(inner, "inntektsaar"),
          inntekt_foer_fradrag_for_eventuelt_avgitt_konsernbidrag:
            extract_beloep_som_heltall(inner, "inntektFoerFradragForEventueltAvgittKonsernbidrag"),
          samlet_inntekt: extract_wrapped_beloep(inner, "samletInntekt"),
          samlet_underskudd: extract_wrapped_beloep(inner, "samletUnderskudd"),
          fremfoert_underskudd_fra_tidligere_aar:
            extract_beloep_som_heltall(inner, "fremfoertUnderskuddFraTidligereAar"),
          fremfoerbart_underskudd_i_inntekt:
            extract_wrapped_beloep(inner, "fremfoerbartUnderskuddIInntekt"),
          netto_formue: extract_wrapped_beloep(inner, "nettoformue"),
          samlet_formuesverdi_etter_verdsettingsrabatt:
            extract_wrapped_beloep(inner, "samletFormuesverdiEtterVerdsettingsrabatt"),
          samlet_gjeld: extract_wrapped_beloep(inner, "samletGjeld")
        }
    end
  end

  def parse_etter_beregning(_), do: %{}

  # The response envelope wraps the EtterBeregning XML base64-encoded inside
  # <dokument><type>skattemeldingUpersonligEtterBeregning</type>...<content>.
  defp extract_etter_beregning_xml(body) do
    pattern =
      ~r{<(?:\w+:)?dokument>\s*<(?:\w+:)?type>\s*skattemeldingUpersonligEtterBeregning\s*</(?:\w+:)?type>\s*<(?:\w+:)?encoding>[^<]*</(?:\w+:)?encoding>\s*<(?:\w+:)?content>\s*([^<]+?)\s*</(?:\w+:)?content>}s

    case Regex.run(pattern, body) do
      [_, b64] ->
        case Base.decode64(String.replace(b64, ~r/\s+/, "")) do
          {:ok, xml} -> xml
          :error -> nil
        end

      _ ->
        nil
    end
  end

  # Plain "<tag>123</tag>" — for partsnummer, inntektsaar, fremfoertUnderskudd...
  defp extract_int(xml, tag) do
    case Regex.run(~r{<#{tag}>\s*([-0-9]+)\s*</#{tag}>}, xml) do
      [_, num] -> String.to_integer(num)
      _ -> nil
    end
  end

  # "<tag><beloepSomHeltall>123</beloepSomHeltall></tag>"
  defp extract_beloep_som_heltall(xml, tag) do
    case Regex.run(
           ~r{<#{tag}>\s*<beloepSomHeltall>\s*([-0-9]+)\s*</beloepSomHeltall>\s*</#{tag}>},
           xml
         ) do
      [_, num] -> String.to_integer(num)
      _ -> nil
    end
  end

  # "<tag><beloep><beloepSomHeltall>123</beloepSomHeltall></beloep></tag>" or
  # variant with extra <overstyrtBeloep> wrappers — match the innermost number.
  defp extract_wrapped_beloep(xml, tag) do
    case Regex.run(
           ~r{<#{tag}>.*?<beloepSomHeltall>\s*([-0-9]+)\s*</beloepSomHeltall>.*?</#{tag}>}s,
           xml
         ) do
      [_, num] -> String.to_integer(num)
      _ -> nil
    end
  end

  # ── Submission ──────────────────────────────────────────────────────

  @doc """
  Submits the tax return to Skatteetaten via Altinn 3.

  Generates XML documents from the given `Aarsregnskap` and `SkattemeldingKonfig`,
  then submits via the Altinn 3 skattemelding app.

  To inspect the generated XML without submitting, call
  `Wenche.SkattemeldingXml.generer_skattemelding_xml/3`,
  `generer_naeringsspesifikasjon_xml/2`, and `generer_request_xml/3` directly.

  ## Options

  - `:skd_client` — `SkdSkattemeldingClient` used to fetch the real partsnummer
    and dokumentreferanse from SKD. Strongly recommended; without it the request
    envelope falls back to using the org number as partsnummer and emits no
    `<dokumentreferanseTilGjeldendeDokument>`, which causes SKD to reject the
    submission with `innkommendeForespoerselManglerSporTilUtfoerende`.
  - `:dokumentidentifikator` — reference to draft (from `hent_utkast`); used
    only when `:skd_client` is not supplied.
  - `:opprettet_av` — text emitted in `<opprettetAv>` to identify the
    originating end-user system (default `"Wenche"`).
  - `:innsendingstype`, `:innsendingsformaal` — envelope overrides; see
    `SkattemeldingXml.generer_request_xml/3`.

  Returns `{:ok, inbox_url}` or `{:error, reason}`.
  """
  def send_inn(
        %Aarsregnskap{} = regnskap,
        %SkattemeldingKonfig{} = konfig,
        %AltinnClient{} = client,
        opts \\ []
      ) do
    org = regnskap.selskap.org_nummer
    aar = regnskap.regnskapsaar

    skd_client = Keyword.get(opts, :skd_client)

    case resolve_utkast_referanse(opts, skd_client, aar, org) do
      {:ok, ref} ->
        do_send_inn(regnskap, konfig, client, opts, ref)

      {:error, reason} ->
        {:error, {:utkast_referanse_failed, reason}}
    end
  end

  defp do_send_inn(regnskap, konfig, client, opts, ref) do
    org = regnskap.selskap.org_nummer
    aar = regnskap.regnskapsaar

    xml_opts =
      [partsnummer: ref.partsnummer]
      |> maybe_forward_opt(opts, :aksjespesifikasjon)
      |> maybe_forward_opt(opts, :permanent_forskjeller)

    skattemelding_xml = SkattemeldingXml.generer_skattemelding_xml(regnskap, konfig, xml_opts)
    naering_xml = SkattemeldingXml.generer_naeringsspesifikasjon_xml(regnskap, xml_opts)

    request_xml =
      SkattemeldingXml.generer_request_xml(
        skattemelding_xml,
        naering_xml,
        request_envelope_opts(opts, aar, org, ref)
      )

    # SKD's formueinntekt-skattemelding-v2 expects (mirrors the Python reference):
    #   1. POST /instances                                  → opprett_instans
    #   2. PUT  /data/<Skattemeldingsapp_v2>  (JSON inntektsaar)
    #   3. POST /data?dataType=skattemeldingOgNaeringsspesifikasjon (XML envelope)
    #   4. PUT  /process/next                               → neste_prosesssteg
    #   5. PUT  /process/next                               → fullfoor_instans
    with {:ok, instans} <- AltinnClient.opprett_instans(client, "skattemelding", org),
         {:ok, _} <-
           AltinnClient.oppdater_data_element(
             client,
             "skattemelding",
             instans,
             "Skattemeldingsapp_v2",
             Jason.encode!(%{inntektsaar: aar}),
             "application/json"
           ),
         {:ok, _} <-
           AltinnClient.last_opp_skattemelding_konvolutt(client, instans, request_xml),
         {:ok, _} <- AltinnClient.neste_prosesssteg(client, "skattemelding", instans) do
      AltinnClient.fullfoor_instans(client, "skattemelding", instans)
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
        xml_opts =
          [partsnummer: ref.partsnummer]
          |> maybe_forward_opt(opts, :aksjespesifikasjon)
          |> maybe_forward_opt(opts, :permanent_forskjeller)

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
    base =
      [inntektsaar: aar, tin: org]
      |> maybe_put(:opprettet_av, Keyword.get(opts, :opprettet_av))
      |> maybe_put(:innsendingstype, Keyword.get(opts, :innsendingstype))
      |> maybe_put(:innsendingsformaal, Keyword.get(opts, :innsendingsformaal))

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

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, key, value), do: Keyword.put(kw, key, value)

  defp maybe_forward_opt(target, source_opts, key) do
    case Keyword.get(source_opts, key) do
      nil -> target
      [] -> target
      value -> Keyword.put(target, key, value)
    end
  end

  defp append_ref(acc, _type, nil), do: acc
  defp append_ref(acc, _type, ""), do: acc
  defp append_ref(acc, type, id), do: acc ++ [{type, id}]
end
