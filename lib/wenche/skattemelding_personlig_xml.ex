defmodule Wenche.SkattemeldingPersonligXml do
  @moduledoc """
  XML generation for the **personlig** skattemelding (ENK — enkeltpersonforetak)
  submission to Skatteetaten.

  An ENK owner files a personal tax return. The business numbers go in the same
  `naeringsspesifikasjon` (v6) used for AS, but the outer document is the
  personlig skattemelding (`skattemelding` v13) rather than
  `skattemeldingUpersonlig`. Skatteetaten pre-fills the personal sections
  (bank, housing, employment) and *derives* the næring figures from the
  næringsspesifikasjon, so the personlig shell is normally minimal:
  `partsreferanse` + `inntektsaar`, which is all the XSD requires.

  Per `skattemelding_v13_ekstern.xsd`
  (`urn:no:skatteetaten:fastsetting:formueinntekt:skattemelding:ekstern:v13`,
  "Skattemelding personlige skattepliktige v13", income year 2025).

  The næringsspesifikasjon and request envelope are produced by
  `Wenche.SkattemeldingXml` with `skattepliktig_type: :personlig` and
  `skattemelding_dokumenttype: "skattemeldingPersonlig"` respectively — see
  `Wenche.SkattemeldingPersonlig` for the full orchestration.

  ## Fremførbar negativ personinntekt (carry-forward of negative personinntekt)

  An ENK is *not* a separate taxpayer, so it has no AS-style corporate loss
  carryforward. Two distinct mechanisms apply to the owner instead:

    * **Underskudd til fremføring (alminnelig inntekt, skatteloven § 14-6).**
      The business loss is first samordnet against the owner's *other* personal
      income the same year; any remainder carries forward against future
      alminnelig inntekt. Skatteetaten assesses and *pre-fills* this — kontio
      does not submit it for an ENK.

    * **Fremførbar negativ personinntekt (skatteloven § 12-13).** Beregnet
      personinntekt (foretaksmodellen — the base for trygdeavgift + trinnskatt)
      can be negative. Negative personinntekt can never offset personinntekt
      *outside* the business; it carries forward only against future positive
      beregnet personinntekt *from the same virksomhet*, and the right lapses if
      not claimed the first year it can be (§ 12-13 second paragraph). This
      value is **not** `erAvledet` in the XSD — i.e. it is a taxpayer *input*,
      not pre-filled — so the filing system must persist the unused balance and
      submit it the following year.

  When `:fremfoerbar_negativ_personinntekt` is supplied (a positive integer —
  the magnitude of the carried-forward negative personinntekt), this generator
  emits the otherwise-minimal shell *plus* a single `naering/naeringsinntektMv`
  entry carrying it at
  `naering/naeringsinntektMv/samordnetPersoninntekt/fremfoerbarNegativPersoninntektFraTidligereAar/beloep/beloepSomHeltall`.
  Skatteetaten derives everything else in `samordnetPersoninntekt`
  (`fordeltBeregnetPersoninntektFraNaeringsspesifikasjon`, the samordning, and
  the final `personinntekt` — all `erAvledet="true"`). The entry is joined to
  the næringsspesifikasjon's `beregnetPersoninntekt/fordeltBeregnetPersoninntekt`
  via `identifikatorForFordeltBeregnetPersoninntekt` (kontio mints `"1"` for the
  single ENK virksomhet — see `Wenche.SkattemeldingXml`). `naeringstype`
  defaults to `"annenNaering"` (the kodeliste code for an ordinary,
  non-primary-industry ENK); SKD overrides it from the næringsspesifikasjon as
  it is `erAvledet`.

  ## Partsreferanse

  `partsreferanse` is Skatteetaten's internal integer ID for the taxpayer. It
  must be fetched from the pre-filled draft API before generating the XML for
  actual submission. When called without `:partsreferanse`, the generator falls
  back to `aarsregnskap.selskap.org_nummer` as a placeholder (passes XSD
  validation, but Skatteetaten rejects the submission unless replaced with the
  real partsreferanse).
  """

  alias Wenche.Models.Aarsregnskap

  @skattemelding_ns "urn:no:skatteetaten:fastsetting:formueinntekt:skattemelding:ekstern:v13"

  # Kodeliste code (2025_naeringstype.xml) for an ordinary, non-primary-industry
  # ENK. SKD overrides this from the næringsspesifikasjon (the field is
  # `erAvledet`), but the XSD requires it to be present.
  @default_naeringstype "annenNaering"

  # Join key to the næringsspesifikasjon's
  # `beregnetPersoninntekt/fordeltBeregnetPersoninntekt`. Must match the
  # `identifikatorForFordeltBeregnetPersoninntekt` minted there — kontio emits
  # `"1"` for the single ENK virksomhet (see `Wenche.SkattemeldingXml`).
  @default_fordeling_identifikator "1"

  @doc """
  Generates the personlig `skattemelding` XML document (v13).

  Minimal by design — `partsreferanse` + `inntektsaar` — unless a
  `:fremfoerbar_negativ_personinntekt` carry-forward is supplied, in which case
  a single `naering/naeringsinntektMv/samordnetPersoninntekt` entry is added
  (see the moduledoc). The rest of the business detail lives in the
  næringsspesifikasjon; the remaining personal sections are pre-filled by
  Skatteetaten.

  ## Options

  - `:partsreferanse` — Skatteetaten's integer ID for the taxpayer. Defaults to
    `aarsregnskap.selskap.org_nummer`.
  - `:fremfoerbar_negativ_personinntekt` — positive integer kroner of negative
    beregnet personinntekt carried forward from earlier years (skatteloven
    § 12-13). When `nil`, `0` (or negative), no `naering` block is emitted and
    the shell stays minimal.
  - `:naeringstype` — kodeliste code for the virksomhet. Defaults to
    `"annenNaering"`.
  - `:fordeling_identifikator` — join key to the næringsspesifikasjon's
    `fordeltBeregnetPersoninntekt`. Defaults to `"1"`.
  """
  @spec generer_skattemelding_personlig_xml(Aarsregnskap.t(), keyword()) :: String.t()
  def generer_skattemelding_personlig_xml(%Aarsregnskap{} = regnskap, opts \\ []) do
    partsreferanse = Keyword.get(opts, :partsreferanse, regnskap.selskap.org_nummer)
    aar = regnskap.regnskapsaar

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <skattemelding xmlns="#{@skattemelding_ns}">
      <partsreferanse>#{partsreferanse}</partsreferanse>
      <inntektsaar>#{aar}</inntektsaar>#{naering_block(opts)}
    </skattemelding>
    """
    |> String.trim()
  end

  # Emits the `naering` block carrying the § 12-13 fremførbar negativ
  # personinntekt, or "" when there is no carry-forward to report. The amount is
  # the positive magnitude of the carried-forward negative personinntekt; SKD
  # treats it as a reduction of this year's beregnet personinntekt.
  defp naering_block(opts) do
    case Keyword.get(opts, :fremfoerbar_negativ_personinntekt) do
      beloep when is_integer(beloep) and beloep > 0 ->
        naeringstype = Keyword.get(opts, :naeringstype, @default_naeringstype)
        ident = Keyword.get(opts, :fordeling_identifikator, @default_fordeling_identifikator)

        "\n" <>
          Enum.join(
            [
              "  <naering>",
              "    <naeringsinntektMv>",
              "      <id>1</id>",
              "      <identifikatorForFordeltBeregnetPersoninntekt>#{ident}</identifikatorForFordeltBeregnetPersoninntekt>",
              "      <naeringstype>#{naeringstype}</naeringstype>",
              "      <samordnetPersoninntekt>",
              "        <fremfoerbarNegativPersoninntektFraTidligereAar>",
              "          <beloep>",
              "            <beloepSomHeltall>#{beloep}</beloepSomHeltall>",
              "          </beloep>",
              "        </fremfoerbarNegativPersoninntektFraTidligereAar>",
              "      </samordnetPersoninntekt>",
              "    </naeringsinntektMv>",
              "  </naering>"
            ],
            "\n"
          )

      _ ->
        ""
    end
  end

  @doc """
  Extracts the `partsreferanse` from a personlig skattemelding XML document.

  Used after fetching the pre-filled draft to learn Skatteetaten's internal ID
  for the taxpayer. The personlig draft uses `<partsreferanse>` where the
  upersonlig draft uses `<partsnummer>`.

  Returns `{:ok, integer}` or `{:error, :partsreferanse_not_found}`.
  """
  @spec hent_partsreferanse(binary()) :: {:ok, integer()} | {:error, :partsreferanse_not_found}
  def hent_partsreferanse(xml) when is_binary(xml) do
    case Regex.run(~r{<(?:\w+:)?partsreferanse[^>]*>\s*(\d+)\s*</(?:\w+:)?partsreferanse>}, xml) do
      [_, value] -> {:ok, String.to_integer(value)}
      _ -> {:error, :partsreferanse_not_found}
    end
  end
end
