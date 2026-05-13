defmodule Wenche.BrgXml do
  @moduledoc """
  Generates BRG XML documents for annual statement submission to Bronnøysundregistrene.

  Ported from `wenche/brg_xml.py` in the original Python Wenche project.

  Two separate XML documents are required:
  - **Hovedskjema** (dataFormatId=1266): company info, fiscal year, accounting principles
  - **Underskjema** (dataFormatId=758): income statement and balance sheet figures

  Namespace and orid values are from BRG's official documentation:
  https://brreg.github.io/docs/apidokumentasjon/regnskapsregisteret/maskinell-innrapportering/
  """

  alias Wenche.Models.{
    Aarsregnskap,
    Anleggsmidler,
    Driftsinntekter,
    Driftskostnader,
    Egenkapital,
    Eiendeler,
    Finansposter,
    KortsiktigGjeld,
    LangsiktigGjeld,
    Omloepmidler,
    Resultatregnskap
  }

  @doc """
  Generates Hovedskjema XML (dataFormatId=1266) for BRG annual statement.
  Contains company info, accounting period, principles, and confirmation.

  ## Options

    * `:system_navn` — system name reported to BRG (default: `"Wenche"`)

  Returns UTF-8 encoded XML bytes.
  """
  def generer_hovedskjema(%Aarsregnskap{} = regnskap, opts \\ []) do
    s = regnskap.selskap
    aar = regnskap.regnskapsaar
    fastsettelsesdato = regnskap.fastsettelsesdato || Date.utc_today()
    signatar = regnskap.signatar || s.daglig_leder
    ikke_revideres = if regnskap.revideres, do: "nei", else: "ja"
    system_navn = Keyword.get(opts, :system_navn, "Wenche")

    morselskap =
      if regnskap.balanse.eiendeler.anleggsmidler.aksjer_i_datterselskap > 0,
        do: "ja",
        else: "nei"

    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <melding xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
             xmlns:xsd="http://www.w3.org/2001/XMLSchema"
             xmlns="http://schema.brreg.no/regnsys/aarsregnskap_vanlig"
             dataFormatId="1266"
             dataFormatVersion="51820"
             tjenestehandling="aarsregnskap_vanlig"
             tjeneste="regnskap">
      <Innsender>
        <enhet>
          <organisasjonsnummer orid="18">#{escape(s.org_nummer)}</organisasjonsnummer>
          <organisasjonsform orid="756">AS</organisasjonsform>
          <navn orid="1">#{escape(s.navn)}</navn>
        </enhet>
        <opplysningerInnsending>
          <noteMaskinellBehandling orid="37499">10</noteMaskinellBehandling>
          <systemNavn orid="39007">#{escape(system_navn)}</systemNavn>
        </opplysningerInnsending>
      </Innsender>
      <Skjemainnhold>
        <regnskapsperiode>
          <regnskapsaar orid="17102">#{aar}</regnskapsaar>
          <regnskapsstart orid="17103">#{aar}-01-01</regnskapsstart>
          <regnskapsslutt orid="17104">#{aar}-12-31</regnskapsslutt>
        </regnskapsperiode>
        <konsern>
          <morselskap orid="4168">#{morselskap}</morselskap>
          <konsernregnskap orid="25943">nei</konsernregnskap>
        </konsern>
        <regnskapsprinsipper>
          <smaaForetak orid="8079">ja</smaaForetak>
          <regnskapsreglerSelskap orid="25021">nei</regnskapsreglerSelskap>
          <forenkletIFRS orid="36639">nei</forenkletIFRS>
        </regnskapsprinsipper>
        <fastsettelse>
          <fastsettelsedato orid="17105">#{Date.to_iso8601(fastsettelsesdato)}</fastsettelsedato>
          <bekreftendeSelskapsrepresentant orid="19023">#{escape(signatar)}</bekreftendeSelskapsrepresentant>
        </fastsettelse>
        <revisjonRegnskapsfoerer>
          <aarsregnskapIkkeRevideres orid="34669">#{ikke_revideres}</aarsregnskapIkkeRevideres>
          <aarsregnskapUtarbeidetAutorisertRegnskapsfoerer orid="34670">nei</aarsregnskapUtarbeidetAutorisertRegnskapsfoerer>
          <tjenestebistandEksternAutorisertRegnskapsfoerer orid="34671">nei</tjenestebistandEksternAutorisertRegnskapsfoerer>
        </revisjonRegnskapsfoerer>
        <aarsberetning/>
      </Skjemainnhold>
    </melding>
    """

    String.trim(xml)
  end

  @doc """
  Generates Underskjema XML (dataFormatId=758) — income statement and balance sheet.

  Returns UTF-8 encoded XML bytes.
  """
  def generer_underskjema(%Aarsregnskap{} = regnskap) do
    r = regnskap.resultatregnskap
    b = regnskap.balanse
    fr = regnskap.foregaaende_aar_resultat
    fb = regnskap.foregaaende_aar_balanse

    # Current year
    di = r.driftsinntekter
    dk = r.driftskostnader
    fp = r.finansposter
    ei = b.eiendeler
    am = ei.anleggsmidler
    om = ei.omloepmidler
    ek = b.egenkapital_og_gjeld.egenkapital
    lg = b.egenkapital_og_gjeld.langsiktig_gjeld
    kg = b.egenkapital_og_gjeld.kortsiktig_gjeld

    # Prior year
    fdi = fr.driftsinntekter
    fdk = fr.driftskostnader
    ffp = fr.finansposter
    fei = fb.eiendeler
    fam = fei.anleggsmidler
    fom = fei.omloepmidler
    fek = fb.egenkapital_og_gjeld.egenkapital
    flg = fb.egenkapital_og_gjeld.langsiktig_gjeld
    fkg = fb.egenkapital_og_gjeld.kortsiktig_gjeld

    netto_finans = Finansposter.sum_inntekter(fp) - Finansposter.sum_kostnader(fp)
    sum_gjeld = LangsiktigGjeld.sum(lg) + KortsiktigGjeld.sum(kg)
    sum_innskutt_ek = ek.aksjekapital + ek.overkursfond

    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <melding xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
             xmlns:xsd="http://www.w3.org/2001/XMLSchema"
             xmlns="http://schema.brreg.no/regnsys/aarsregnskap_vanlig/underskjema"
             dataFormatId="758"
             dataFormatVersion="51980"
             tjenestehandling="aarsregnskap_vanlig_underskjema"
             tjeneste="regnskap">
      <Rapport-RR0002U>
        <aarsregnskap>
          <regnskapstype orid="25942">S</regnskapstype>
          <valuta orid="34984">NOK</valuta>
          <valoer orid="28974">H</valoer>
        </aarsregnskap>
      </Rapport-RR0002U>
      <Skjemainnhold-RR0002U>

        <resultatregnskapDriftsresultat>
          <driftsresultat>
            <aarets orid="146">#{Resultatregnskap.driftsresultat(r)}</aarets>
            <fjoraarets orid="7026">#{Resultatregnskap.driftsresultat(fr)}</fjoraarets>
          </driftsresultat>
          <inntekt>
    #{linje("salgsinntekt", di.salgsinntekter, "Salgsinntekter", "28998", "1340", "7965", fdi.salgsinntekter)}
    #{linje("driftsinntekt", di.andre_driftsinntekter, "Andre driftsinntekter", "28999", "7709", "7966", fdi.andre_driftsinntekter)}
            <driftsinntektSum>
              <aarets orid="72">#{Driftsinntekter.sum(di)}</aarets>
              <fjoraarets orid="6972">#{Driftsinntekter.sum(fdi)}</fjoraarets>
            </driftsinntektSum>
          </inntekt>
          <kostnad>
    #{linje("loennskostnad", dk.loennskostnader, "Lønnskostnader", "29001", "81", "6979", fdk.loennskostnader)}
    #{linje("avskrivning", dk.avskrivninger, "Avskrivninger", "29002", "2139", "10181", fdk.avskrivninger)}
    #{linje("annenDriftskostnad", dk.andre_driftskostnader, "Andre driftskostnader", "29003", "82", "7023", fdk.andre_driftskostnader)}
            <sumDriftskostnad>
              <aarets orid="17126">#{Driftskostnader.sum(dk)}</aarets>
              <fjoraarets orid="17127">#{Driftskostnader.sum(fdk)}</fjoraarets>
            </sumDriftskostnad>
          </kostnad>
        </resultatregnskapDriftsresultat>

        <resultatregnskapFinansinntekt>
          <nettoFinans>
            <aarets orid="158">#{netto_finans}</aarets>
            <fjoraarets orid="7999">#{Finansposter.sum_inntekter(ffp) - Finansposter.sum_kostnader(ffp)}</fjoraarets>
          </nettoFinans>
          <finansinntekt>
    #{linje("investeringDatterforetakTilknyttetSelskap", fp.utbytte_fra_datterselskap, "Utbytte fra datterselskap", "29004", "27934", "27935", ffp.utbytte_fra_datterselskap)}
    #{linje_enkel("annenRenteinntekt", fp.andre_finansinntekter, "150", "7030", ffp.andre_finansinntekter)}
            <sumFinansinntekter>
              <aarets orid="153">#{Finansposter.sum_inntekter(fp)}</aarets>
              <fjoraarets orid="7993">#{Finansposter.sum_inntekter(ffp)}</fjoraarets>
            </sumFinansinntekter>
          </finansinntekt>
          <finanskostnad>
    #{linje_enkel("rentekostnad", fp.rentekostnader, "7037", "7038", ffp.rentekostnader)}
    #{linje("annenFinanskostnad", fp.andre_finanskostnader, "Andre finanskostnader", "29011", "156", "7041", ffp.andre_finanskostnader)}
            <sumFinanskostnader>
              <aarets orid="17130">#{Finansposter.sum_kostnader(fp)}</aarets>
              <fjoraarets orid="17131">#{Finansposter.sum_kostnader(ffp)}</fjoraarets>
            </sumFinanskostnader>
          </finanskostnad>
        </resultatregnskapFinansinntekt>

        <resultatregnskapResultat>
          <resultat>
            <resultatFoerSkattekostnad>
              <aarets orid="167">#{Resultatregnskap.resultat_foer_skatt(r)}</aarets>
              <fjoraarets orid="7042">#{Resultatregnskap.resultat_foer_skatt(fr)}</fjoraarets>
            </resultatFoerSkattekostnad>
            <aarsresultat>
              <aarets orid="172">#{Resultatregnskap.aarsresultat(r)}</aarets>
              <fjoraarets orid="7054">#{Resultatregnskap.aarsresultat(fr)}</fjoraarets>
            </aarsresultat>
          </resultat>
          <overfoeringer>
            <sumOverfoeringerOgDisponeringer>
              <aarets orid="7071">#{Resultatregnskap.aarsresultat(r)}</aarets>
              <fjoraarets orid="7072">#{Resultatregnskap.aarsresultat(fr)}</fjoraarets>
            </sumOverfoeringerOgDisponeringer>
          </overfoeringer>
        </resultatregnskapResultat>

        <balanseAnleggsmidlerOmloepsmidler>
          <sumEiendeler>
            <aarets orid="219">#{Eiendeler.sum(ei)}</aarets>
            <fjoraarets orid="7127">#{Eiendeler.sum(fei)}</fjoraarets>
          </sumEiendeler>
          <balanseAnleggsmidler>
            <sumAnleggsmidler>
              <aarets orid="217">#{Anleggsmidler.sum(am)}</aarets>
              <fjoraarets orid="7108">#{Anleggsmidler.sum(fam)}</fjoraarets>
            </sumAnleggsmidler>
            <balanseFinansielleAnleggsmidler>
              <investeringDatterselskap>
                <aarets orid="9686">#{am.aksjer_i_datterselskap}</aarets>
                <fjoraarets orid="10289">#{fam.aksjer_i_datterselskap}</fjoraarets>
              </investeringDatterselskap>
    #{linje("investeringAksjerAndeler", am.andre_aksjer, "Andre aksjer", "29024", "7100", "7101", fam.andre_aksjer)}
    #{linje("annenFordring", am.langsiktige_fordringer, "Langsiktige fordringer", "29025", "203", "27585", fam.langsiktige_fordringer)}
              <sumFinansielleAnleggsmidler>
                <aarets orid="5267">#{Anleggsmidler.sum(am)}</aarets>
                <fjoraarets orid="8014">#{Anleggsmidler.sum(fam)}</fjoraarets>
              </sumFinansielleAnleggsmidler>
            </balanseFinansielleAnleggsmidler>
          </balanseAnleggsmidler>
          <balanseOmloepsmidler>
            <sumOmloepsmidler>
              <aarets orid="194">#{Omloepmidler.sum(om)}</aarets>
              <fjoraarets orid="7126">#{Omloepmidler.sum(fom)}</fjoraarets>
            </sumOmloepsmidler>
            <balanseOmloepsmidlerVarerFordringer>
              <fordringer>
    #{linje("andreFordringer", om.kortsiktige_fordringer, "Kortsiktige fordringer", "29028", "282", "7112", fom.kortsiktige_fordringer)}
                <sumFordringer>
                  <aarets orid="80">#{om.kortsiktige_fordringer}</aarets>
                  <fjoraarets orid="8015">#{fom.kortsiktige_fordringer}</fjoraarets>
                </sumFordringer>
              </fordringer>
            </balanseOmloepsmidlerVarerFordringer>
            <balanseOmloepsmidlerInvesteringerBankinnskuddKontanter>
              <bankinnskuddKontanter>
    #{linje("bankinnskuddKontanter", om.bankinnskudd, "Bankinnskudd", "29031", "786", "8019", fom.bankinnskudd)}
                <sumBankinnskuddKontanter>
                  <aarets orid="29042">#{om.bankinnskudd}</aarets>
                  <fjoraarets orid="29043">#{fom.bankinnskudd}</fjoraarets>
                </sumBankinnskuddKontanter>
              </bankinnskuddKontanter>
            </balanseOmloepsmidlerInvesteringerBankinnskuddKontanter>
          </balanseOmloepsmidler>
        </balanseAnleggsmidlerOmloepsmidler>

        <balanseEgenkapitalGjeld>
          <sumEgenkapitalGjeld>
            <aarets orid="251">#{Egenkapital.sum(ek) + sum_gjeld}</aarets>
            <fjoraarets orid="7185">#{Egenkapital.sum(fek) + LangsiktigGjeld.sum(flg) + KortsiktigGjeld.sum(fkg)}</fjoraarets>
          </sumEgenkapitalGjeld>
          <balanseEgenkapitalInnskuttOpptjentEgenkapital>
            <innskuttEgenkapital>
    #{linje("selskapskapital", ek.aksjekapital, "Aksjekapital", "29032", "20488", "20489", fek.aksjekapital)}
    #{linje_enkel("overkursfond", ek.overkursfond, "2585", "7135", fek.overkursfond)}
              <sumInnskuttEgenkapital>
                <aarets orid="3730">#{sum_innskutt_ek}</aarets>
                <fjoraarets orid="9984">#{fek.aksjekapital + fek.overkursfond}</fjoraarets>
              </sumInnskuttEgenkapital>
            </innskuttEgenkapital>
            <opptjentEgenkaiptal>
    #{linje("annenEgenkapital", ek.annen_egenkapital, "Annen egenkapital", "29034", "3274", "7140", fek.annen_egenkapital)}
              <sumOpptjentEgenkapital>
                <aarets orid="9702">#{ek.annen_egenkapital}</aarets>
                <fjoraarets orid="9985">#{fek.annen_egenkapital}</fjoraarets>
              </sumOpptjentEgenkapital>
              <sumEgenkapital>
                <aarets orid="250">#{Egenkapital.sum(ek)}</aarets>
                <fjoraarets orid="7142">#{Egenkapital.sum(fek)}</fjoraarets>
              </sumEgenkapital>
            </opptjentEgenkaiptal>
          </balanseEgenkapitalInnskuttOpptjentEgenkapital>
          <balanseGjeldOversikt>
            <sumGjeld>
              <aarets orid="1119">#{sum_gjeld}</aarets>
              <fjoraarets orid="7184">#{LangsiktigGjeld.sum(flg) + KortsiktigGjeld.sum(fkg)}</fjoraarets>
            </sumGjeld>
            <balanseGjeldAvsetningerForpliktelserAnnenLangsiktigGjeld>
              <sumLangsiktigGjeld>
                <aarets orid="86">#{LangsiktigGjeld.sum(lg)}</aarets>
                <fjoraarets orid="7156">#{LangsiktigGjeld.sum(flg)}</fjoraarets>
              </sumLangsiktigGjeld>
              <annenLangsiktigGjeld>
    #{linje_enkel("langsiktigKonserngjeld", lg.laan_fra_aksjonaer, "2256", "7152", flg.laan_fra_aksjonaer)}
    #{linje("oevrigLangsiktigGjeld", lg.andre_langsiktige_laan, "Andre langsiktige lån", "29036", "242", "7155", flg.andre_langsiktige_laan)}
                <sumAnnenLangsiktigGjeld>
                  <aarets orid="25019">#{LangsiktigGjeld.sum(lg)}</aarets>
                  <fjoraarets orid="25020">#{LangsiktigGjeld.sum(flg)}</fjoraarets>
                </sumAnnenLangsiktigGjeld>
              </annenLangsiktigGjeld>
            </balanseGjeldAvsetningerForpliktelserAnnenLangsiktigGjeld>
            <balanseKortsiktigGjeld>
    #{linje_enkel("leverandoergjeld", kg.leverandoergjeld, "220", "7162", fkg.leverandoergjeld)}
    #{linje("skyldigeOffentligeAvgifter", kg.skyldige_offentlige_avgifter, "Skyldige offentlige avgifter", "29039", "225", "7170", fkg.skyldige_offentlige_avgifter)}
    #{linje("annenKortsiktigGjeld", kg.annen_kortsiktig_gjeld, "Annen kortsiktig gjeld", "29040", "236", "7182", fkg.annen_kortsiktig_gjeld)}
              <sumKortsiktigGjeld>
                <aarets orid="85">#{KortsiktigGjeld.sum(kg)}</aarets>
                <fjoraarets orid="7183">#{KortsiktigGjeld.sum(fkg)}</fjoraarets>
              </sumKortsiktigGjeld>
            </balanseKortsiktigGjeld>
          </balanseGjeldOversikt>
        </balanseEgenkapitalGjeld>

    #{Wenche.Noter.generer_noter_xml(regnskap)}

      </Skjemainnhold-RR0002U>
    </melding>
    """

    String.trim(xml)
  end

  # Repeatable line element with `<beskrivelse>`. Only emitted when value or
  # prior-year value is non-zero. `altinnRowId` is intentionally NOT emitted —
  # the BRG RR-0002 underskjema XSD does not allow it. Earlier ports (Python +
  # this Elixir port pre-fix) emitted it because Altinn-Studio-style models
  # carry it, but BRG's validator silently discards it. Removing it makes
  # output strict-XSD-conformant.
  defp linje(tag, verdi, besk, orid_besk, orid_aarets, orid_fjor, fjor_verdi) do
    if verdi == 0 and fjor_verdi == 0 do
      ""
    else
      """
              <#{tag}>
                <beskrivelse orid="#{orid_besk}">#{escape(besk)}</beskrivelse>
                <aarets orid="#{orid_aarets}">#{verdi}</aarets>
                <fjoraarets orid="#{orid_fjor}">#{fjor_verdi}</fjoraarets>
              </#{tag}>
      """
    end
  end

  # Single-occurrence elements that XSD defines without altinnRowId/beskrivelse
  # (e.g. rentekostnad, langsiktigKonserngjeld, overkursfond, leverandoergjeld,
  # annenRenteinntekt). Only emitted when value or prior-year value is non-zero.
  defp linje_enkel(tag, verdi, orid_aarets, orid_fjor, fjor_verdi) do
    if verdi == 0 and fjor_verdi == 0 do
      ""
    else
      """
              <#{tag}>
                <aarets orid="#{orid_aarets}">#{verdi}</aarets>
                <fjoraarets orid="#{orid_fjor}">#{fjor_verdi}</fjoraarets>
              </#{tag}>
      """
    end
  end

  defp escape(nil), do: ""

  defp escape(str) when is_binary(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp escape(val), do: to_string(val)
end
