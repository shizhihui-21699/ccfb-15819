defmodule PrivacyMail.PlainText do
  @moduledoc """
  Scans and sanitizes plain-text email links.

  Plain-text trackers cannot load images automatically, but they can contain
  personalized links. We remove known campaign parameters and optionally wrap
  recipient-identifying links in the signed redirect gateway.
  """

  alias PrivacyMail.Proxy.Token
  alias PrivacyMail.Tracking.Classifier
  alias PrivacyMail.WebURL

  @url_re ~r{https?://[^\s<>"']+}i

  def analyze(text, opts \\ []) when is_binary(text) do
    {_text, findings} = process(text, Keyword.put(opts, :rewrite, false))
    build_report(findings)
  end

  def privatize(text, opts \\ []) when is_binary(text) do
    {safe_text, findings} = process(text, Keyword.put(opts, :rewrite, true))
    {:ok, safe_text, build_report(findings)}
  end

  defp process(text, opts) do
    rewrite? = Keyword.get(opts, :rewrite, true)
    matches = Regex.scan(@url_re, text) |> List.flatten()

    {replacements, findings} =
      Enum.reduce(matches, {%{}, []}, fn raw_match, {map, findings} ->
        url = trim_trailing_punctuation(raw_match)

        if WebURL.http_url?(url) do
          trailing = String.replace_prefix(raw_match, url, "")

          finding =
            url
            |> Classifier.classify_link([], opts)
            |> Map.merge(%{type: :plain_text_link, location: :text})

          replacement =
            if rewrite?, do: rewrite(finding.action, url, opts) <> trailing, else: raw_match

          {Map.put(map, raw_match, replacement), [finding | findings]}
        else
          {map, findings}
        end
      end)

    safe_text =
      if rewrite? do
        Regex.replace(@url_re, text, fn match -> Map.get(replacements, match, match) end)
      else
        text
      end

    {safe_text, Enum.reverse(findings)}
  end

  defp rewrite(:redirect, url, opts) do
    url = maybe_strip(url, opts)
    token_opts = opts |> Keyword.take([:secret, :proxy_base_url]) |> token_opts()
    Token.absolute_redirect_url(url, token_opts)
  end

  defp rewrite(:sanitize, url, opts), do: maybe_strip(url, opts)
  defp rewrite(_allow, url, _opts), do: url

  defp maybe_strip(url, opts) do
    if Keyword.get(
         opts,
         :strip_tracking_params,
         Application.get_env(:privacy_mail, :strip_tracking_params, true)
       ) do
      WebURL.strip_tracking_params(url, Keyword.get(opts, :extra_tracking_params, []))
    else
      url
    end
  end

  defp token_opts(opts) do
    case Keyword.pop(opts, :proxy_base_url) do
      {nil, rest} -> rest
      {base, rest} -> Keyword.put(rest, :base_url, base)
    end
  end

  defp trim_trailing_punctuation(match) do
    String.replace(match, ~r/[.,;:!?)}\]>'"]+$/u, "")
  end

  defp build_report(findings) do
    %{
      links: findings,
      personalized_links: Enum.filter(findings, &match?(%{identifiers: [_ | _]}, &1)),
      counts: %{
        links: length(findings),
        personalized_links: Enum.count(findings, &match?(%{identifiers: [_ | _]}, &1)),
        links_redirected: Enum.count(findings, &(&1.action == :redirect)),
        links_sanitized: Enum.count(findings, &(&1.action == :sanitize))
      }
    }
  end
end
