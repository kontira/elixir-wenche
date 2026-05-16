defmodule Wenche.Models do
  @moduledoc """
  Data models for all three submission types: annual accounts, tax return,
  and shareholder register.

  Ported from `wenche/models.py` in the original Python Wenche project.
  """

  # ---------------------------------------------------------------------------
  # Company info
  # ---------------------------------------------------------------------------

  defmodule Selskap do
    @moduledoc "Company information."
    defstruct [
      :navn,
      :org_nummer,
      :daglig_leder,
      :styreleder,
      :forretningsadresse,
      :stiftelsesaar,
      :aksjekapital,
      kontakt_epost: ""
    ]

    @type t :: %__MODULE__{
            navn: String.t(),
            org_nummer: String.t(),
            daglig_leder: String.t(),
            styreleder: String.t(),
            forretningsadresse: String.t(),
            stiftelsesaar: integer(),
            aksjekapital: integer(),
            kontakt_epost: String.t()
          }
  end

  # ---------------------------------------------------------------------------
  # Income statement components
  # ---------------------------------------------------------------------------

  defmodule Driftsinntekter do
    @moduledoc "Operating income."
    defstruct salgsinntekter: 0, andre_driftsinntekter: 0

    @type t :: %__MODULE__{
            salgsinntekter: integer(),
            andre_driftsinntekter: integer()
          }

    def sum(%__MODULE__{} = d), do: d.salgsinntekter + d.andre_driftsinntekter
  end

  defmodule Driftskostnader do
    @moduledoc "Operating costs."
    defstruct loennskostnader: 0, avskrivninger: 0, andre_driftskostnader: 0

    @type t :: %__MODULE__{
            loennskostnader: integer(),
            avskrivninger: integer(),
            andre_driftskostnader: integer()
          }

    def sum(%__MODULE__{} = d),
      do: d.loennskostnader + d.avskrivninger + d.andre_driftskostnader
  end

  defmodule Finansposter do
    @moduledoc "Financial items."
    defstruct utbytte_fra_datterselskap: 0,
              andre_finansinntekter: 0,
              rentekostnader: 0,
              andre_finanskostnader: 0

    @type t :: %__MODULE__{
            utbytte_fra_datterselskap: integer(),
            andre_finansinntekter: integer(),
            rentekostnader: integer(),
            andre_finanskostnader: integer()
          }

    def sum_inntekter(%__MODULE__{} = f),
      do: f.utbytte_fra_datterselskap + f.andre_finansinntekter

    def sum_kostnader(%__MODULE__{} = f),
      do: f.rentekostnader + f.andre_finanskostnader
  end

  defmodule Resultatregnskap do
    @moduledoc "Income statement."
    alias Wenche.Models.{Driftsinntekter, Driftskostnader, Finansposter}

    defstruct driftsinntekter: %Driftsinntekter{},
              driftskostnader: %Driftskostnader{},
              finansposter: %Finansposter{}

    @type t :: %__MODULE__{
            driftsinntekter: Driftsinntekter.t(),
            driftskostnader: Driftskostnader.t(),
            finansposter: Finansposter.t()
          }

    def driftsresultat(%__MODULE__{} = r),
      do: Driftsinntekter.sum(r.driftsinntekter) - Driftskostnader.sum(r.driftskostnader)

    def resultat_foer_skatt(%__MODULE__{} = r) do
      driftsresultat(r) +
        Finansposter.sum_inntekter(r.finansposter) -
        Finansposter.sum_kostnader(r.finansposter)
    end

    # For holding companies without taxable income, tax cost = 0
    def aarsresultat(%__MODULE__{} = r), do: resultat_foer_skatt(r)
  end

  # ---------------------------------------------------------------------------
  # Balance sheet components
  # ---------------------------------------------------------------------------

  # Every balance-sheet section carries an optional `:sum_override`. When
  # set (integer), `sum/1` returns it verbatim instead of mechanically
  # adding the children. Callers that hold the raw decimal source data
  # use this to keep the displayed/emitted grand total = round-once of
  # the raw decimal sum, while individual lines remain rounded to their
  # own honest values. Without an override the historic mechanical sum
  # is used, so existing callers are unaffected.
  defmodule Anleggsmidler do
    @moduledoc "Non-current assets."
    defstruct aksjer_i_datterselskap: 0,
              andre_aksjer: 0,
              langsiktige_fordringer: 0,
              sum_override: nil

    @type t :: %__MODULE__{
            aksjer_i_datterselskap: integer(),
            andre_aksjer: integer(),
            langsiktige_fordringer: integer(),
            sum_override: integer() | nil
          }

    def sum(%__MODULE__{sum_override: o}) when is_integer(o), do: o

    def sum(%__MODULE__{} = a),
      do: a.aksjer_i_datterselskap + a.andre_aksjer + a.langsiktige_fordringer
  end

  defmodule Omloepmidler do
    @moduledoc "Current assets."
    defstruct kortsiktige_fordringer: 0, bankinnskudd: 0, sum_override: nil

    @type t :: %__MODULE__{
            kortsiktige_fordringer: integer(),
            bankinnskudd: integer(),
            sum_override: integer() | nil
          }

    def sum(%__MODULE__{sum_override: o}) when is_integer(o), do: o
    def sum(%__MODULE__{} = o), do: o.kortsiktige_fordringer + o.bankinnskudd
  end

  defmodule Eiendeler do
    @moduledoc "Assets."
    alias Wenche.Models.{Anleggsmidler, Omloepmidler}

    defstruct anleggsmidler: %Anleggsmidler{}, omloepmidler: %Omloepmidler{}, sum_override: nil

    @type t :: %__MODULE__{
            anleggsmidler: Anleggsmidler.t(),
            omloepmidler: Omloepmidler.t(),
            sum_override: integer() | nil
          }

    def sum(%__MODULE__{sum_override: o}) when is_integer(o), do: o

    def sum(%__MODULE__{} = e),
      do: Anleggsmidler.sum(e.anleggsmidler) + Omloepmidler.sum(e.omloepmidler)
  end

  defmodule Egenkapital do
    @moduledoc "Equity. annen_egenkapital can be negative for accumulated losses."
    defstruct aksjekapital: 0, overkursfond: 0, annen_egenkapital: 0, sum_override: nil

    @type t :: %__MODULE__{
            aksjekapital: integer(),
            overkursfond: integer(),
            annen_egenkapital: integer(),
            sum_override: integer() | nil
          }

    def sum(%__MODULE__{sum_override: o}) when is_integer(o), do: o
    def sum(%__MODULE__{} = e), do: e.aksjekapital + e.overkursfond + e.annen_egenkapital
  end

  defmodule LangsiktigGjeld do
    @moduledoc "Long-term liabilities."
    defstruct laan_fra_aksjonaer: 0, andre_langsiktige_laan: 0, sum_override: nil

    @type t :: %__MODULE__{
            laan_fra_aksjonaer: integer(),
            andre_langsiktige_laan: integer(),
            sum_override: integer() | nil
          }

    def sum(%__MODULE__{sum_override: o}) when is_integer(o), do: o
    def sum(%__MODULE__{} = l), do: l.laan_fra_aksjonaer + l.andre_langsiktige_laan
  end

  defmodule KortsiktigGjeld do
    @moduledoc "Short-term liabilities."
    defstruct leverandoergjeld: 0,
              skyldige_offentlige_avgifter: 0,
              annen_kortsiktig_gjeld: 0,
              sum_override: nil

    @type t :: %__MODULE__{
            leverandoergjeld: integer(),
            skyldige_offentlige_avgifter: integer(),
            annen_kortsiktig_gjeld: integer(),
            sum_override: integer() | nil
          }

    def sum(%__MODULE__{sum_override: o}) when is_integer(o), do: o

    def sum(%__MODULE__{} = k),
      do: k.leverandoergjeld + k.skyldige_offentlige_avgifter + k.annen_kortsiktig_gjeld
  end

  defmodule EgenkapitalOgGjeld do
    @moduledoc "Equity and liabilities."
    alias Wenche.Models.{Egenkapital, KortsiktigGjeld, LangsiktigGjeld}

    defstruct egenkapital: %Egenkapital{},
              langsiktig_gjeld: %LangsiktigGjeld{},
              kortsiktig_gjeld: %KortsiktigGjeld{},
              sum_override: nil

    @type t :: %__MODULE__{
            egenkapital: Egenkapital.t(),
            langsiktig_gjeld: LangsiktigGjeld.t(),
            kortsiktig_gjeld: KortsiktigGjeld.t(),
            sum_override: integer() | nil
          }

    def sum(%__MODULE__{sum_override: o}) when is_integer(o), do: o

    def sum(%__MODULE__{} = e) do
      Egenkapital.sum(e.egenkapital) +
        LangsiktigGjeld.sum(e.langsiktig_gjeld) +
        KortsiktigGjeld.sum(e.kortsiktig_gjeld)
    end
  end

  defmodule Balanse do
    @moduledoc "Balance sheet."
    alias Wenche.Models.{EgenkapitalOgGjeld, Eiendeler}

    defstruct eiendeler: %Eiendeler{}, egenkapital_og_gjeld: %EgenkapitalOgGjeld{}

    @type t :: %__MODULE__{
            eiendeler: Eiendeler.t(),
            egenkapital_og_gjeld: EgenkapitalOgGjeld.t()
          }

    def er_i_balanse?(%__MODULE__{} = b),
      do: Eiendeler.sum(b.eiendeler) == EgenkapitalOgGjeld.sum(b.egenkapital_og_gjeld)

    def differanse(%__MODULE__{} = b),
      do: Eiendeler.sum(b.eiendeler) - EgenkapitalOgGjeld.sum(b.egenkapital_og_gjeld)
  end

  # ---------------------------------------------------------------------------
  # Notes (noter)
  # ---------------------------------------------------------------------------

  defmodule LaanTilNaerstaaende do
    @moduledoc "Loan to related party (§7-45)."
    defstruct [:navn, :rolle, :beloep, :rentesats, :avdragsplan]

    @type t :: %__MODULE__{
            navn: String.t(),
            rolle: String.t(),
            beloep: integer(),
            rentesats: float() | nil,
            avdragsplan: String.t() | nil
          }
  end

  defmodule Noter do
    @moduledoc "Notes for annual accounts (regnskapsloven §§ 7-35 to 7-46)."
    alias Wenche.Models.LaanTilNaerstaaende

    defstruct antall_ansatte: 0,
              regnskapsprinsipper: nil,
              laan_til_naerstaaende: [],
              fortsatt_drift_usikkerhet: false,
              fortsatt_drift_beskrivelse: nil

    @type t :: %__MODULE__{
            antall_ansatte: non_neg_integer(),
            regnskapsprinsipper: String.t() | nil,
            laan_til_naerstaaende: [LaanTilNaerstaaende.t()],
            fortsatt_drift_usikkerhet: boolean(),
            fortsatt_drift_beskrivelse: String.t() | nil
          }
  end

  # ---------------------------------------------------------------------------
  # Annual accounts
  # ---------------------------------------------------------------------------

  defmodule Aarsregnskap do
    @moduledoc "Full annual accounts."
    alias Wenche.Models.{Balanse, Noter, Resultatregnskap, Selskap}

    defstruct [
      :selskap,
      :regnskapsaar,
      :resultatregnskap,
      :balanse,
      :fastsettelsesdato,
      :signatar,
      revideres: false,
      foregaaende_aar_resultat: %Resultatregnskap{},
      foregaaende_aar_balanse: %Balanse{},
      utbytte_utbetalt: 0,
      noter: %Noter{}
    ]

    @type t :: %__MODULE__{
            selskap: Selskap.t(),
            regnskapsaar: integer(),
            resultatregnskap: Resultatregnskap.t(),
            balanse: Balanse.t(),
            fastsettelsesdato: Date.t() | nil,
            signatar: String.t() | nil,
            revideres: boolean(),
            foregaaende_aar_resultat: Resultatregnskap.t(),
            foregaaende_aar_balanse: Balanse.t(),
            utbytte_utbetalt: integer(),
            noter: Noter.t()
          }
  end

  # ---------------------------------------------------------------------------
  # Shareholder register
  # ---------------------------------------------------------------------------

  defmodule Aksjonaer do
    @moduledoc """
    Individual shareholder.

    Supports both person shareholders (fodselsnummer - 11 digits) and
    company shareholders (organisasjonsnummer - 9 digits).
    Exactly one of fodselsnummer or organisasjonsnummer should be set.
    """
    defstruct [
      :navn,
      :fodselsnummer,
      :organisasjonsnummer,
      :antall_aksjer,
      :aksjeklasse,
      :utbytte_utbetalt,
      :innbetalt_kapital_per_aksje
    ]

    @type t :: %__MODULE__{
            navn: String.t(),
            fodselsnummer: String.t() | nil,
            organisasjonsnummer: String.t() | nil,
            antall_aksjer: integer(),
            aksjeklasse: String.t(),
            utbytte_utbetalt: integer(),
            innbetalt_kapital_per_aksje: integer()
          }
  end

  defmodule Aksjonaerregisteroppgave do
    @moduledoc "Shareholder register submission (RF-1086)."
    alias Wenche.Models.{Aksjonaer, Selskap}

    defstruct [:selskap, :regnskapsaar, aksjonaerer: []]

    @type t :: %__MODULE__{
            selskap: Selskap.t(),
            regnskapsaar: integer(),
            aksjonaerer: [Aksjonaer.t()]
          }

    def totalt_antall_aksjer(%__MODULE__{} = o),
      do: Enum.reduce(o.aksjonaerer, 0, fn a, acc -> acc + a.antall_aksjer end)

    def totalt_utbytte_utbetalt(%__MODULE__{} = o),
      do: Enum.reduce(o.aksjonaerer, 0, fn a, acc -> acc + (a.utbytte_utbetalt || 0) end)
  end

  # ---------------------------------------------------------------------------
  # Tax return configuration
  # ---------------------------------------------------------------------------

  defmodule SkattemeldingKonfig do
    @moduledoc "Tax return configuration."
    defstruct underskudd_til_fremfoering: 0,
              anvend_fritaksmetoden: true,
              eierandel_datterselskap: 100,
              # When set, beregn/2 uses this list as the authoritative permanent
              # forskjeller — bypasses the global eierandel_datterselskap heuristic.
              #
              # Shape: [%{type: atom, beloep: Decimal.t | integer}]
              #
              # Prefer Decimal beloep: skattepliktig brutto sums them with the
              # correct sign per type and rounds ONCE (:half_up), which matches
              # how Skatteetaten / Fiken compute brutto. Integer beloep is
              # accepted for backwards compatibility but loses the cumulative
              # fractional cents that decimal sums would round up.
              #
              # XML emission rounds each beloep per line (:half_up) so SKD
              # receives integer NOK as required by the kodeliste.
              #
              # Supported types:
              #   :tilbakefoeringAvInntektsfoertUtbytte  (subtract from inntekt)
              #   :skattepliktigDelAvUtbytterOgUtdelinger (add to inntekt)
              #   :regnskapsmessigGevinstVedRealisasjonAvFinansielleInstrumenter (subtract)
              #   :regnskapsmessigTapVedRealisasjonAvFinansielleInstrumenter (add)
              permanent_forskjeller: nil

    @type permanent_forskjell :: %{type: atom(), beloep: Decimal.t() | integer()}

    @type t :: %__MODULE__{
            underskudd_til_fremfoering: integer(),
            anvend_fritaksmetoden: boolean(),
            eierandel_datterselskap: integer(),
            permanent_forskjeller: [permanent_forskjell()] | nil
          }
  end
end
