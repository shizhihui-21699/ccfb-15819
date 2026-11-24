defmodule PrivacyMail.WebCSS do
  @moduledoc false

  @url_re ~r/url\(\s*['"]?([^'")]+)['"]?\s*\)/i

  def extract_urls(css) when is_binary(css) do
    @url_re
    |> Regex.scan(css)
    |> Enum.map(fn
      [_full, url] -> String.trim(url)
      _ -> nil
    end)
    |> Enum.filter(&is_binary/1)
  end

  def extract_urls(_), do: []

  @doc "Rewrites each CSS url() with `fun.(url)`; returning the original leaves it unchanged."
  def rewrite_urls(css, fun) when is_binary(css) and is_function(fun, 1) do
    Regex.replace(@url_re, css, fn full, url ->
      url = String.trim(url)

      case fun.(url) do
        ^url -> full
        new_url -> ~s|url("#{new_url}")|
      end
    end)
  end

  def rewrite_urls(other, _fun), do: other
end
