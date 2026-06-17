defmodule Wenche.SkdClient do
  @moduledoc """
  SKD API client for aksjonærregisteroppgave (RF-1086).

  Skatteetaten has its own REST API for reporting — independent of Altinn instance flow.
  Authentication uses a Maskinporten token directly (not exchanged for Altinn token).

  Submission flow:
    1. POST /{year}/1086H        — send Hovedskjema, get back hovedskjemaid
    2. POST /{year}/{id}/1086U   — send Underskjema for each shareholder
    3. POST /{year}/{id}/bekreft — confirm all sub-forms submitted
  """

  @bases %{
    "test" => "https://api-test.sits.no/api/aksjonaerregister/v1",
    "prod" => "https://api.sits.no/api/aksjonaerregister/v1"
  }

  @doc """
  Creates a new SKD client config.

  Returns a map with base URL, token, and req_options for use in other functions.

  ## Options

  - `:env` — `"test"` or `"prod"` (default: `"prod"`)
  - `:req_options` — extra options passed to `Req` (default: `[]`)
  """
  def new(maskinporten_token, opts \\ []) do
    env = Keyword.get(opts, :env, "prod")
    req_options = Keyword.get(opts, :req_options, [])

    base =
      Map.get(@bases, env) ||
        raise ArgumentError, "invalid env: #{inspect(env)}. Use \"prod\" or \"test\"."

    %{base: base, token: maskinporten_token, req_options: req_options}
  end

  @doc """
  Sends Hovedskjema (RF-1086) to SKD.

  Returns `{:ok, hovedskjemaid}` or `{:error, reason}`.
  """
  def send_hovedskjema(%{base: base, token: token} = client, regnskapsaar, xml) do
    url = "#{base}/#{regnskapsaar}/1086H"
    req_options = Map.get(client, :req_options, [])

    case Req.post(
           url,
           Keyword.merge(
             [body: xml, headers: headers(token), receive_timeout: 30_000],
             req_options
           )
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        # SKD returns the id as "hovedskjemaId" (camelCase); accept the
        # lowercase variant too for robustness.
        case body["hovedskjemaId"] || body["hovedskjemaid"] do
          nil -> {:error, {:hovedskjema_failed, status, body}}
          id -> {:ok, id}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:hovedskjema_failed, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @doc """
  Sends Underskjema (RF-1086-U) for one shareholder.

  Returns `:ok` or `{:error, reason}`.
  """
  def send_underskjema(%{base: base, token: token} = client, regnskapsaar, hovedskjemaid, xml) do
    url = "#{base}/#{regnskapsaar}/#{hovedskjemaid}/1086U"
    req_options = Map.get(client, :req_options, [])

    case Req.post(
           url,
           Keyword.merge(
             [body: xml, headers: headers(token), receive_timeout: 30_000],
             req_options
           )
         ) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:underskjema_failed, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @doc """
  Confirms that all sub-forms have been submitted.

  Returns `{:ok, response_map}` with forsendelse-ID and dialog-ID, or `{:error, reason}`.
  """
  def bekreft(
        %{base: base, token: token} = client,
        regnskapsaar,
        hovedskjemaid,
        antall_underskjema
      ) do
    url =
      "#{base}/#{regnskapsaar}/#{hovedskjemaid}/bekreft?antall_underskjema=#{antall_underskjema}"

    req_options = Map.get(client, :req_options, [])

    case Req.post(
           url,
           Keyword.merge(
             [body: "", headers: headers(token), receive_timeout: 30_000],
             req_options
           )
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:bekreft_failed, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp headers(token) do
    [
      {"authorization", "Bearer #{token}"},
      {"content-type", "application/xml"},
      {"accept", "application/json"},
      {"idempotencyKey", UUID.uuid4()}
    ]
  end
end
