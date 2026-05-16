defmodule Wenche.ModelsTest do
  use ExUnit.Case, async: true

  alias Wenche.Models.{
    Aksjonaer,
    Aksjonaerregisteroppgave,
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
    Selskap,
    SkattemeldingKonfig
  }

  describe "Selskap" do
    test "creates a company struct" do
      selskap = %Selskap{
        navn: "Test AS",
        org_nummer: "912345678",
        daglig_leder: "Ola Nordmann",
        styreleder: "Kari Nordmann",
        forretningsadresse: "Storgata 1, 0001 Oslo",
        stiftelsesaar: 2020,
        aksjekapital: 30_000
      }

      assert selskap.navn == "Test AS"
      assert selskap.org_nummer == "912345678"
      assert selskap.aksjekapital == 30_000
    end
  end

  describe "Driftsinntekter" do
    test "calculates sum correctly" do
      di = %Driftsinntekter{salgsinntekter: 100_000, andre_driftsinntekter: 20_000}
      assert Driftsinntekter.sum(di) == 120_000
    end

    test "defaults to zero" do
      di = %Driftsinntekter{}
      assert Driftsinntekter.sum(di) == 0
    end
  end

  describe "Driftskostnader" do
    test "calculates sum correctly" do
      dk = %Driftskostnader{
        loennskostnader: 50_000,
        avskrivninger: 10_000,
        andre_driftskostnader: 15_000
      }

      assert Driftskostnader.sum(dk) == 75_000
    end
  end

  describe "Finansposter" do
    test "calculates sum_inntekter correctly" do
      fp = %Finansposter{utbytte_fra_datterselskap: 100_000, andre_finansinntekter: 5_000}
      assert Finansposter.sum_inntekter(fp) == 105_000
    end

    test "calculates sum_kostnader correctly" do
      fp = %Finansposter{rentekostnader: 3_000, andre_finanskostnader: 1_000}
      assert Finansposter.sum_kostnader(fp) == 4_000
    end
  end

  describe "Resultatregnskap" do
    test "calculates driftsresultat correctly" do
      r = %Resultatregnskap{
        driftsinntekter: %Driftsinntekter{salgsinntekter: 200_000},
        driftskostnader: %Driftskostnader{andre_driftskostnader: 50_000}
      }

      assert Resultatregnskap.driftsresultat(r) == 150_000
    end

    test "calculates resultat_foer_skatt correctly" do
      r = %Resultatregnskap{
        driftsinntekter: %Driftsinntekter{salgsinntekter: 200_000},
        driftskostnader: %Driftskostnader{andre_driftskostnader: 50_000},
        finansposter: %Finansposter{
          andre_finansinntekter: 10_000,
          rentekostnader: 5_000
        }
      }

      # 200000 - 50000 + 10000 - 5000 = 155000
      assert Resultatregnskap.resultat_foer_skatt(r) == 155_000
    end

    test "aarsresultat equals resultat_foer_skatt for holding companies" do
      r = %Resultatregnskap{
        driftsinntekter: %Driftsinntekter{salgsinntekter: 100_000},
        driftskostnader: %Driftskostnader{andre_driftskostnader: 20_000}
      }

      assert Resultatregnskap.aarsresultat(r) == 80_000
    end
  end

  describe "Anleggsmidler" do
    test "calculates sum correctly" do
      am = %Anleggsmidler{
        aksjer_i_datterselskap: 500_000,
        andre_aksjer: 50_000,
        langsiktige_fordringer: 25_000
      }

      assert Anleggsmidler.sum(am) == 575_000
    end
  end

  describe "Omloepmidler" do
    test "calculates sum correctly" do
      om = %Omloepmidler{
        kortsiktige_fordringer: 30_000,
        bankinnskudd: 120_000
      }

      assert Omloepmidler.sum(om) == 150_000
    end
  end

  describe "Eiendeler" do
    test "calculates sum correctly" do
      ei = %Eiendeler{
        anleggsmidler: %Anleggsmidler{aksjer_i_datterselskap: 400_000},
        omloepmidler: %Omloepmidler{bankinnskudd: 100_000}
      }

      assert Eiendeler.sum(ei) == 500_000
    end
  end

  describe "Egenkapital" do
    test "calculates sum correctly" do
      ek = %Egenkapital{
        aksjekapital: 30_000,
        overkursfond: 20_000,
        annen_egenkapital: 200_000
      }

      assert Egenkapital.sum(ek) == 250_000
    end

    test "handles negative annen_egenkapital" do
      ek = %Egenkapital{
        aksjekapital: 30_000,
        overkursfond: 0,
        annen_egenkapital: -10_000
      }

      assert Egenkapital.sum(ek) == 20_000
    end
  end

  describe "Balanse" do
    test "er_i_balanse? returns true when balanced" do
      b = %Balanse{
        eiendeler: %Eiendeler{
          anleggsmidler: %Anleggsmidler{aksjer_i_datterselskap: 400_000},
          omloepmidler: %Omloepmidler{bankinnskudd: 100_000}
        },
        egenkapital_og_gjeld: %EgenkapitalOgGjeld{
          egenkapital: %Egenkapital{aksjekapital: 30_000, annen_egenkapital: 370_000},
          langsiktig_gjeld: %LangsiktigGjeld{},
          kortsiktig_gjeld: %KortsiktigGjeld{leverandoergjeld: 100_000}
        }
      }

      assert Balanse.er_i_balanse?(b)
      assert Balanse.differanse(b) == 0
    end

    test "er_i_balanse? returns false when not balanced" do
      b = %Balanse{
        eiendeler: %Eiendeler{
          anleggsmidler: %Anleggsmidler{aksjer_i_datterselskap: 500_000},
          omloepmidler: %Omloepmidler{bankinnskudd: 100_000}
        },
        egenkapital_og_gjeld: %EgenkapitalOgGjeld{
          egenkapital: %Egenkapital{aksjekapital: 30_000, annen_egenkapital: 370_000},
          langsiktig_gjeld: %LangsiktigGjeld{},
          kortsiktig_gjeld: %KortsiktigGjeld{}
        }
      }

      refute Balanse.er_i_balanse?(b)
      assert Balanse.differanse(b) == 200_000
    end
  end

  describe "Aksjonaerregisteroppgave" do
    test "calculates totalt_antall_aksjer" do
      oppgave = %Aksjonaerregisteroppgave{
        selskap: %Selskap{navn: "Test AS", org_nummer: "912345678"},
        regnskapsaar: 2025,
        aksjonaerer: [
          %Aksjonaer{navn: "Ola", fodselsnummer: "12345678901", antall_aksjer: 100},
          %Aksjonaer{navn: "Kari", fodselsnummer: "98765432101", antall_aksjer: 50}
        ]
      }

      assert Aksjonaerregisteroppgave.totalt_antall_aksjer(oppgave) == 150
    end

    test "calculates totalt_utbytte_utbetalt" do
      oppgave = %Aksjonaerregisteroppgave{
        selskap: %Selskap{navn: "Test AS", org_nummer: "912345678"},
        regnskapsaar: 2025,
        aksjonaerer: [
          %Aksjonaer{
            navn: "Ola",
            fodselsnummer: "12345678901",
            antall_aksjer: 100,
            utbytte_utbetalt: 50_000
          },
          %Aksjonaer{
            navn: "Kari",
            fodselsnummer: "98765432101",
            antall_aksjer: 50,
            utbytte_utbetalt: 25_000
          }
        ]
      }

      assert Aksjonaerregisteroppgave.totalt_utbytte_utbetalt(oppgave) == 75_000
    end
  end

  describe "SkattemeldingKonfig" do
    test "has sensible defaults" do
      konfig = %SkattemeldingKonfig{}

      assert konfig.underskudd_til_fremfoering == 0
      assert konfig.anvend_fritaksmetoden == true
      assert konfig.eierandel_datterselskap == 100
    end
  end

  describe "sum_override on balanse models" do
    # When the caller holds raw decimal source data, mechanically summing
    # rounded integer children can drift by ±1 kr from round-once-on-raw.
    # `:sum_override` lets the caller set the honest grand total.
    # Without an override the mechanical sum is used — back-compatible.

    test "Eiendeler.sum returns mechanical sum when no override" do
      e = %Eiendeler{
        anleggsmidler: %Anleggsmidler{aksjer_i_datterselskap: 4_800},
        omloepmidler: %Omloepmidler{bankinnskudd: 55_594}
      }

      assert Eiendeler.sum(e) == 60_394
    end

    test "Eiendeler.sum returns override when set" do
      e = %Eiendeler{
        anleggsmidler: %Anleggsmidler{aksjer_i_datterselskap: 4_800},
        omloepmidler: %Omloepmidler{bankinnskudd: 55_594},
        sum_override: 60_395
      }

      assert Eiendeler.sum(e) == 60_395
    end

    test "KortsiktigGjeld.sum returns mechanical sum (matches Fiken: -1 + 0 + 0 = -1)" do
      k = %KortsiktigGjeld{
        leverandoergjeld: -1,
        skyldige_offentlige_avgifter: 0,
        annen_kortsiktig_gjeld: 0
      }

      assert KortsiktigGjeld.sum(k) == -1
    end

    test "EgenkapitalOgGjeld.sum returns override over child sum (Fiken parity case)" do
      # Real Hübenthal 2025: 30 000 + 30 395 + (-1) mechanically = 60 394,
      # but round-once raw = 60 395. The override carries the honest total.
      eg = %EgenkapitalOgGjeld{
        egenkapital: %Egenkapital{aksjekapital: 30_000, annen_egenkapital: 30_395},
        kortsiktig_gjeld: %KortsiktigGjeld{leverandoergjeld: -1},
        sum_override: 60_395
      }

      assert EgenkapitalOgGjeld.sum(eg) == 60_395
    end

    test "EgenkapitalOgGjeld.sum falls back to mechanical without override" do
      eg = %EgenkapitalOgGjeld{
        egenkapital: %Egenkapital{aksjekapital: 30_000, annen_egenkapital: 30_395},
        kortsiktig_gjeld: %KortsiktigGjeld{leverandoergjeld: -1}
      }

      assert EgenkapitalOgGjeld.sum(eg) == 60_394
    end
  end
end
