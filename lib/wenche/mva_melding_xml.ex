defmodule Wenche.MvaMeldingXml do
  @moduledoc """
  XML generation for MVA-melding (VAT return) submission to Skatteetaten via Altinn 3.

  Generates two XML documents:
  1. `mvaMeldingInnsending` — the envelope (konvolutt)
  2. `mvaMeldingDto` — the actual VAT return data
  """

  @melding_ns "no:skatteetaten:fastsetting:avgift:mva:skattemeldingformerverdiavgift:v1.0"
  @konvolutt_ns "no:skatteetaten:fastsetting:avgift:mva:mvameldinginnsending:v1.0"

  @perioder %{
    1 => "januar-februar",
    2 => "mars-april",
    3 => "mai-juni",
    4 => "juli-august",
    5 => "september-oktober",
    6 => "november-desember"
  }

  @doc """
  Maps a termin number (1-6) to the skattleggingsperiodeToMaaneder string.
  """
  def periode_tekst(termin) when termin in 1..6 do
    Map.fetch!(@perioder, termin)
  end

  @doc """
  Generates the `mvaMeldingInnsending` (konvolutt/envelope) XML.

  The `mva_data` map must contain:
  - `:org_nummer` — organization number
  - `:termin` — 1-6
  - `:year` — tax year
  - `:system_name` — name of the submitting system (default "Kontira")
  """
  def generer_konvolutt_xml(mva_data) do
    org_nr = mva_data.org_nummer
    termin = mva_data.termin
    year = mva_data.year
    system_name = Map.get(mva_data, :system_name, "Kontira")
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    periode = periode_tekst(termin)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <mvaMeldingInnsending xmlns="#{@konvolutt_ns}">
      <norskIdentifikator><organisasjonsnummer>#{escape(org_nr)}</organisasjonsnummer></norskIdentifikator>
      <skattleggingsperiode>
        <periode><skattleggingsperiodeToMaaneder>#{periode}</skattleggingsperiodeToMaaneder></periode>
        <aar>#{year}</aar>
      </skattleggingsperiode>
      <meldingskategori>alminnelig</meldingskategori>
      <innsendingstype>komplett</innsendingstype>
      <instansstatus>default</instansstatus>
      <opprettetAv>#{escape(system_name)}</opprettetAv>
      <opprettingstidspunkt>#{now}</opprettingstidspunkt>
      <vedlegg>
        <vedleggstype>mva-melding</vedleggstype>
        <kildegruppe>sluttbrukersystem</kildegruppe>
        <opprettetAv>#{escape(system_name)}</opprettetAv>
        <opprettingstidspunkt>#{now}</opprettingstidspunkt>
        <vedleggsfil>
          <filnavn>melding_xml</filnavn>
          <filekstensjon>xml</filekstensjon>
          <filinnhold>MVA-melding</filinnhold>
        </vedleggsfil>
      </vedlegg>
    </mvaMeldingInnsending>
    """
    |> String.trim()
  end

  @doc """
  Generates the `mvaMeldingDto` (the actual VAT return) XML.

  The `mva_data` map must contain:
  - `:org_nummer` — organization number
  - `:termin` — 1-6
  - `:year` — tax year
  - `:linjer` — list of `%{mva_kode: integer, grunnlag: number, sats: number, merverdiavgift: number}`
  - `:fastsatt_merverdiavgift` — total MVA amount
  - `:system_name` — name of the submitting system (default "Kontira")
  """
  def generer_melding_xml(mva_data) do
    org_nr = mva_data.org_nummer
    termin = mva_data.termin
    year = mva_data.year
    linjer = mva_data.linjer
    fastsatt_mva = mva_data.fastsatt_merverdiavgift
    system_name = Map.get(mva_data, :system_name, "Kontira")
    reference = Map.get(mva_data, :referanse, "mva-#{org_nr}-#{year}-#{termin}")
    periode = periode_tekst(termin)

    linjer_xml =
      linjer
      |> Enum.map_join("\n", &spesifikasjonslinje_xml/1)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <mvaMeldingDto xmlns="#{@melding_ns}">
      <innsending>
        <regnskapssystemsreferanse>#{escape(reference)}</regnskapssystemsreferanse>
        <regnskapssystem>
          <systemnavn>#{escape(system_name)}</systemnavn>
          <systemversjon>1.0</systemversjon>
        </regnskapssystem>
      </innsending>
      <skattegrunnlagOgBeregnetSkatt>
        <skattleggingsperiode>
          <periode><skattleggingsperiodeToMaaneder>#{periode}</skattleggingsperiodeToMaaneder></periode>
          <aar>#{year}</aar>
        </skattleggingsperiode>
        <fastsattMerverdiavgift>#{fastsatt_mva}</fastsattMerverdiavgift>
    #{linjer_xml}
      </skattegrunnlagOgBeregnetSkatt>
      <betalingsinformasjon/>
      <skattepliktig><organisasjonsnummer>#{escape(org_nr)}</organisasjonsnummer></skattepliktig>
      <meldingskategori>alminnelig</meldingskategori>
    </mvaMeldingDto>
    """
    |> String.trim()
  end

  defp spesifikasjonslinje_xml(linje) do
    """
        <mvaSpesifikasjonslinje>
          <mvaKode>#{linje.mva_kode}</mvaKode>
          <grunnlag>#{linje.grunnlag}</grunnlag>
          <sats>#{linje.sats}</sats>
          <merverdiavgift>#{linje.merverdiavgift}</merverdiavgift>
        </mvaSpesifikasjonslinje>
    """
    |> String.trim_trailing()
  end

  defp escape(str) when is_binary(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  defp escape(other), do: to_string(other)
end
