defmodule PrivacyMail.WebURL do
  @moduledoc """
  URL parsing, canonicalization and tracking-parameter removal.
  """

  alias PrivacyMail.Tracking.Rules

  @safe_schemes ~w[http https]

  @type parsed :: URI.t()

  @doc "Returns true for absolute HTTP(S) URLs that the proxy may fetch."
  def http_url?(url) when is_binary(url) do
    match?(
      %URI{scheme: scheme, host: host}
      when scheme in @safe_schemes and is_binary(host) and host != "",
      URI.parse(url)
    )
  rescue
    _ -> false
  end

  def http_url?(_), do: false

  @doc """
  Resolves a possibly protocol-relative URL against the email's base URL.
  Email usually has no base, so only HTTP(S) and protocol-relative URLs are
  transformed. `cid:`, `data:` and fragment URLs are left untouched.
  """
  def absolute(url, base \\ nil)

  def absolute("#" <> _ = url, _base), do: url

  def absolute("//" <> rest, base) do
    scheme = if base && URI.parse(base).scheme == "http", do: "http", else: "https"
    scheme <> "://" <> rest
  end

  def absolute(url, base) when is_binary(url) do
    cond do
      String.starts_with?(url, ["http://", "https://"]) -> url
      is_binary(base) and base != "" -> URI.merge(base, url) |> URI.to_string()
      true -> url
    end
  rescue
    _ -> url
  end

  def absolute(other, _base), do: other

  @doc """
  Removes fragment and known campaign/tracking parameters.

  The returned URL is also used as the signed proxy input. Functional
  identifiers such as invoice or password-reset tokens are not removed here;
  doing so could break the destination page.
  """
  def strip_tracking_params(url, extra_names \\ []) when is_binary(url) do
    uri = URI.parse(url)
    names = Enum.map(Rules.tracking_param_names() ++ extra_names, &String.downcase/1)

    query =
      (uri.query || "")
      |> URI.decode_query()
      |> Enum.reject(fn {k, _v} -> String.downcase(k) in names end)
      |> case do
        [] -> nil
        pairs -> URI.encode_query(pairs, :rfc3986)
      end

    %{uri | fragment: nil, query: query}
    |> URI.to_string()
  rescue
    _ -> url
  end

  @doc "Canonical cache key: scheme/host lower-cased, fragment removed, params sorted."
  def canonical(url, opts \\ []) when is_binary(url) do
    strip? = Keyword.get(opts, :strip_tracking_params, true)

    url = if strip?, do: strip_tracking_params(url), else: url
    uri = URI.parse(url)

    query =
      (uri.query || "")
      |> URI.decode_query()
      |> Enum.sort()
      |> case do
        [] -> nil
        pairs -> URI.encode_query(pairs, :rfc3986)
      end

    host = uri.host && String.downcase(uri.host)
    scheme = uri.scheme && String.downcase(uri.scheme)

    %{uri | host: host, scheme: scheme, query: query, fragment: nil}
    |> URI.to_string()
  rescue
    _ -> url
  end

  @doc "Returns query parameter names/values that look recipient-specific."
  def identifier_signals(url) when is_binary(url) do
    uri = URI.parse(url)
    query = URI.decode_query(uri.query || "")
    names = Rules.identifier_param_names()

    query_signals =
      Enum.flat_map(query, fn {key, value} ->
        key_l = String.downcase(key)

        cond do
          looks_like_email?(value) ->
            [%{param: key, kind: :email_value, evidence: "query value is an email address"}]

          encoded_email?(value) ->
            [
              %{
                param: key,
                kind: :encoded_email,
                evidence: "query value contains an encoded email address"
              }
            ]

          key_l in names and not generic_campaign_id?(key_l, value) ->
            [%{param: key, kind: :named_identifier, evidence: identifier_evidence(key_l, value)}]

          long_opaque_token?(key_l, value) ->
            [%{param: key, kind: :opaque_token, evidence: "long hex/base64/JWT-like token"}]

          true ->
            []
        end
      end)

    query_signals ++ path_identifier_signals(uri.path)
  rescue
    _ -> []
  end

  def identifier_signals(_), do: []

  @doc false
  def path_identifier_signals(path) when is_binary(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.flat_map(fn segment ->
      stem =
        segment
        |> Path.basename()
        |> String.replace(~r/\.(?:jpe?g|png|gif|webp|avif)$/i, "")

      down = String.downcase(stem)

      cond do
        Regex.match?(~r/^[0-9a-f]{16,}$/i, stem) ->
          [%{param: segment, kind: :path_token, evidence: "long hexadecimal path token"}]

        Regex.match?(
          ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i,
          stem
        ) ->
          [%{param: segment, kind: :path_token, evidence: "UUID path token"}]

        Regex.match?(~r/^[A-Za-z0-9_-]{24,}$/, stem) and
            not String.contains?(down, ["banner", "logo", "hero", "image"]) ->
          [%{param: segment, kind: :path_token, evidence: "long opaque path token"}]

        true ->
          []
      end
    end)
  end

  def path_identifier_signals(_), do: []

  def tracking_params(url) when is_binary(url) do
    names = Rules.tracking_param_names()

    (URI.parse(url).query || "")
    |> URI.decode_query()
    |> Enum.filter(fn {k, _} -> String.downcase(k) in names end)
    |> Enum.map(&elem(&1, 0))
  rescue
    _ -> []
  end

  def tracking_params(_), do: []

  def looks_like_email?(value) when is_binary(value) do
    Regex.match?(~r/^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$/i, String.trim(value))
  end

  def looks_like_email?(_), do: false

  def encoded_email?(value) when is_binary(value) do
    decoded =
      try do
        URI.decode_www_form(value)
      rescue
        _ -> value
      end

    looks_like_email?(decoded) or
      Regex.match?(~r/[A-Z0-9._%+-]+(?:%40|=40|_at_|\[at\])[A-Z0-9.-]+\.[A-Z]{2,}/i, value)
  end

  def encoded_email?(_), do: false

  def long_opaque_token?(key, value) when is_binary(value) do
    String.downcase(key) in Rules.identifier_param_names() and
      (String.length(value) >= 24 and
         Regex.match?(~r/^[A-Za-z0-9+_=\-._~%]+$/, value)) and
      not generic_campaign_id?(key, value)
  end

  def long_opaque_token?(_, _), do: false

  defp identifier_evidence(key, value) do
    cond do
      String.contains?(key, "email") ->
        "email-named parameter"

      String.contains?(key, "recipient") ->
        "recipient-named parameter"

      String.contains?(key, "subscriber") ->
        "subscriber-named parameter"

      String.contains?(key, "user") or key in ~w[uid] ->
        "user identifier parameter"

      String.contains?(key, "contact") ->
        "contact identifier parameter"

      String.contains?(key, "token") or key in ~w[sig signature] ->
        "capability/signature parameter"

      String.length(value) >= 32 ->
        "long opaque recipient token"

      true ->
        "identifier-like parameter"
    end
  end

  defp generic_campaign_id?(key, value) do
    key in ~w[mc_cid campaign_id] and Regex.match?(~r/^[0-9a-z]+$/i, value) and
      String.length(value) <= 12
  end
end
