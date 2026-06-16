defmodule Wenche.SubmissionResult do
  @moduledoc """
  Bundles the documents that were sent and the response that was received for a
  filing, so callers can persist an audit trail of exactly what was transmitted
  to (and returned from) Altinn / Skatteetaten / BRREG.

  Returned by the `send_inn/*` (submission) and `valider/*` (validation)
  functions across the filing modules.

    * `documents` — the XML payloads that were sent, as a list of
      `%{name: String.t(), content: String.t()}` (e.g. `"skattemelding"`,
      `"naering"`, `"request"`, `"hovedskjema"`, `"underskjema"`).
    * `response` — the raw external response (an XML/JSON string, or a parsed
      map), or `nil` when the service returns no body.
    * `reference` — the Altinn inbox URL for a submission; `nil` for validation.
  """

  @type document :: %{name: String.t(), content: String.t()}

  @type t :: %__MODULE__{
          documents: [document()],
          response: String.t() | map() | nil,
          reference: String.t() | nil
        }

  defstruct documents: [], response: nil, reference: nil
end
