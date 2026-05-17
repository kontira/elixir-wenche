# Wenche (Elixir)

[![Hex.pm](https://img.shields.io/hexpm/v/wenche.svg)](https://hex.pm/packages/wenche)

Elixir library for Norwegian small business filings — Maskinporten authentication,
Altinn 3 API client, BRG XML/iXBRL generation, tax calculation, and shareholder
register XML generation.

Ported from the Python CLI tool [Wenche](https://github.com/olefredrik/Wenche).

## Modules

| Module | Description | Origin |
|---|---|---|
| `Wenche.Maskinporten` | JWT-based auth against Maskinporten + Altinn token exchange | `wenche/auth.py` |
| `Wenche.Systembruker` | System user registration and management for Altinn 3 | `wenche/systembruker.py` |
| `Wenche.AltinnClient` | Altinn 3 API client (instances, data upload, completion) | `wenche/altinn_client.py` |
| `Wenche.Aarsregnskap` | Annual accounts submission flow (config, validation, submission) | `wenche/aarsregnskap.py` |
| `Wenche.BrgXml` | BRG annual statement XML (hovedskjema/underskjema) | `wenche/brg_xml.py` |
| `Wenche.Ixbrl` | Inline XBRL (iXBRL) HTML document generation | `wenche/xbrl.py` |
| `Wenche.Noter` | Notes (noter) for small enterprises — structured XML + iXBRL text | `wenche/noter.py` |
| `Wenche.Skattemelding` | Tax calculation, structured `beregn/2`, and Altinn 3 submission orchestration for skattemelding (RF-1028/RF-1167) | `wenche/skattemelding.py` |
| `Wenche.SkattemeldingXml` | Skattemelding XML (`skattemeldingUpersonlig` v5, `naeringsspesifikasjon` v6, request envelope v2) against Skatteetaten XSDs | — |
| `Wenche.SkdSkattemeldingClient` | Skatteetaten REST API client for skattemelding (pre-filled draft, valider) | — |
| `Wenche.MvaMelding` | VAT return (MVA-melding) submission via Altinn 3. **Experimental.** | — |
| `Wenche.MvaMeldingXml` | MVA-melding XML generation (`mvaMeldingInnsending` + `mvaMeldingDto`) | — |
| `Wenche.Aksjonaerregister` | RF-1086 shareholder register XML generation | `wenche/aksjonaerregister.py` |
| `Wenche.SkdClient` | Skatteetaten REST API client for RF-1086 (1086H / 1086U / bekreft) | — |
| `Wenche.Models` | Data structures (Selskap, Aarsregnskap, Resultatregnskap, Balanse, SkattemeldingKonfig, etc.) | `wenche/models.py` |

## Installation

Add `wenche` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:wenche, "~> 0.2.0"}
  ]
end
```

## Usage

### Maskinporten Authentication

```elixir
config = [
  client_id: "your-client-id",
  kid: "your-key-id",
  private_key_pem: File.read!("maskinporten_privat.pem"),
  env: "prod"
]

# Standard token for instance operations
{:ok, token} = Wenche.Maskinporten.get_altinn_token(config)

# System user token for organization-specific operations
{:ok, token} = Wenche.Maskinporten.get_systemuser_token(config, "912345678")

# Admin token for system register operations
{:ok, admin_token} = Wenche.Maskinporten.get_admin_token(config)
```

### Submitting Annual Statement

```elixir
alias Wenche.Models.{
  Aarsregnskap, Selskap, Resultatregnskap, Balanse,
  Driftsinntekter, Driftskostnader, Finansposter,
  Eiendeler, Anleggsmidler, Omloepmidler,
  EgenkapitalOgGjeld, Egenkapital, LangsiktigGjeld, KortsiktigGjeld
}

# Build company data
selskap = %Selskap{
  navn: "Mitt Selskap AS",
  org_nummer: "912345678",
  daglig_leder: "Ola Nordmann",
  styreleder: "Kari Nordmann",
  forretningsadresse: "Storgata 1, 0001 Oslo",
  stiftelsesaar: 2020,
  aksjekapital: 30000
}

# Build financial data
resultatregnskap = %Resultatregnskap{
  driftsinntekter: %Driftsinntekter{
    salgsinntekter: 0,
    andre_driftsinntekter: 0
  },
  driftskostnader: %Driftskostnader{
    loennskostnader: 0,
    avskrivninger: 0,
    andre_driftskostnader: 5000
  },
  finansposter: %Finansposter{
    utbytte_fra_datterselskap: 100000,
    andre_finansinntekter: 500,
    rentekostnader: 0,
    andre_finanskostnader: 0
  }
}

balanse = %Balanse{
  eiendeler: %Eiendeler{
    anleggsmidler: %Anleggsmidler{
      aksjer_i_datterselskap: 500000,
      andre_aksjer: 0,
      langsiktige_fordringer: 0
    },
    omloepmidler: %Omloepmidler{
      kortsiktige_fordringer: 0,
      bankinnskudd: 125500
    }
  },
  egenkapital_og_gjeld: %EgenkapitalOgGjeld{
    egenkapital: %Egenkapital{
      aksjekapital: 30000,
      overkursfond: 0,
      annen_egenkapital: 595500
    },
    langsiktig_gjeld: %LangsiktigGjeld{
      laan_fra_aksjonaer: 0,
      andre_langsiktige_laan: 0
    },
    kortsiktig_gjeld: %KortsiktigGjeld{
      leverandoergjeld: 0,
      skyldige_offentlige_avgifter: 0,
      annen_kortsiktig_gjeld: 0
    }
  }
}

regnskap = %Aarsregnskap{
  selskap: selskap,
  regnskapsaar: 2025,
  resultatregnskap: resultatregnskap,
  balanse: balanse
}

# Generate XML documents
hovedskjema = Wenche.BrgXml.generer_hovedskjema(regnskap)
underskjema = Wenche.BrgXml.generer_underskjema(regnskap)
ixbrl_html = Wenche.Ixbrl.generer_ixbrl(regnskap)

# Or submit directly via Altinn
client = Wenche.AltinnClient.new(altinn_token, env: "prod")
{:ok, inbox_url} = Wenche.Aarsregnskap.send_inn(regnskap, client)
```

### Tax Calculation

`Wenche.Skattemelding.beregn/2` returns the computed tax return as a structured
map (RF-1167 næringsoppgave, RF-1028 skattemelding, balance overview, equity
note, sammenligning, warnings). Render it however you like.

```elixir
alias Wenche.Models.SkattemeldingKonfig

konfig = %SkattemeldingKonfig{
  anvend_fritaksmetoden: true,
  eierandel_datterselskap: 100,
  underskudd_til_fremfoering: 0
}

beregning = Wenche.Skattemelding.beregn(regnskap, konfig)
# %{
#   selskap: %{navn: ..., org_nummer: ...},
#   regnskapsaar: 2025,
#   rf_1167: %{driftsinntekter: %{...}, driftskostnader: %{...}, ...},
#   rf_1028: %{utbytte: ..., beregnet_skatt: ..., ...},
#   balanse: %{i_balanse: true, differanse: 0, ...},
#   sammenligning: %{...} | nil,
#   egenkapitalnote: %{...} | nil,
#   advarsler: [...]
# }
```

### Shareholder Register (RF-1086)

```elixir
alias Wenche.Models.{Aksjonaerregisteroppgave, Aksjonaer}

aksjonaerer = [
  %Aksjonaer{
    navn: "Ola Nordmann",
    fodselsnummer: "12345678901",
    antall_aksjer: 100,
    aksjeklasse: "A",
    utbytte_utbetalt: 50000,
    innbetalt_kapital_per_aksje: 300
  }
]

oppgave = %Aksjonaerregisteroppgave{
  selskap: selskap,
  regnskapsaar: 2025,
  aksjonaerer: aksjonaerer
}

:ok = Wenche.Aksjonaerregister.valider(oppgave)
xml = Wenche.Aksjonaerregister.generer_xml(oppgave)
```

### System User Setup (One-time)

By default, the system user requests rights for årsregnskap and aksjonærregisteroppgaven.
The skattemelding scope is **not included by default** because systemic submission requires
being a registered revisor or regnskapsfører. Enable it explicitly via the `:features` option
if you have the appropriate authorization.

```elixir
# Get admin token
{:ok, admin_token} = Wenche.Maskinporten.get_admin_token(config)

# Register system with default rights (årsregnskap + aksjonærregister)
{:ok, _} = Wenche.Systembruker.registrer_system(admin_token, vendor_orgnr, client_id,
  name: "my_system", description: %{"nb" => "Mitt system", "nn" => "Mitt system", "en" => "My system"})

# Or include skattemelding scope (requires revisor/regnskapsfører authorization)
{:ok, _} = Wenche.Systembruker.registrer_system(admin_token, vendor_orgnr, client_id,
  name: "my_system", description: %{"nb" => "...", "nn" => "...", "en" => "..."},
  features: [:skattemelding])

# Create system user request for an organization
{:ok, request} = Wenche.Systembruker.opprett_forespoersel(admin_token, vendor_orgnr, org_nummer,
  name: "my_system")

# Check approval status
{:ok, status} = Wenche.Systembruker.hent_forespoersel_status(admin_token, request["id"])

# List all approved system users
{:ok, users} = Wenche.Systembruker.hent_systembrukere(admin_token, vendor_orgnr,
  name: "my_system")
```

## License

MIT — see [LICENSE](LICENSE).

This project is an Elixir port of the Python tool
[Wenche](https://github.com/olefredrik/Wenche), originally licensed under the MIT License.
