defmodule PrivacyMail.Tracking.Classifier do
  @moduledoc """
  Scores images and links using independent, explainable signals.

  A score is deliberately not a binary filename/host allow-list. A normal
  marketing image on an ESP CDN scores low and is proxied; a 1x1 hidden image
  on an unknown host scores high and is neutralized without an upstream fetch.
  """

  alias PrivacyMail.HTMLSignals
  alias PrivacyMail.Tracking.Rules
  alias PrivacyMail.WebURL

  @type finding :: map()

  @doc """
  Classifies an image-like resource.

  Attributes are the HTML attribute list as used by Floki.
  """
  def classify_image(url, attrs \\ [], opts \\ [])

  def classify_image(url, attrs, opts) when is_binary(url) do
    style = HTMLSignals.parse_style(HTMLSignals.attr(attrs, "style"))
    thresholds = thresholds(opts)

    signals = image_signals(url, attrs, style, opts)
    score = signals |> Enum.map(& &1.weight) |> Enum.sum()
    action = image_action(score, signals, thresholds)

    %{
      kind: if(action == :block, do: :tracking_pixel, else: :remote_image),
      action: action,
      score: score,
      confidence: confidence(score),
      url: url,
      reasons: Enum.map(signals, & &1.reason),
      signals: signals
    }
  end

  def classify_image(_url, _attrs, _opts), do: nil

  @doc "Classifies a hyperlink for tracking/recipient identification."
  def classify_link(url, attrs \\ [], opts \\ [])

  def classify_link(url, attrs, opts) when is_binary(url) do
    thresholds = thresholds(opts)
    identifiers = WebURL.identifier_signals(url)
    tracking_params = WebURL.tracking_params(url)
    uri = URI.parse(url)

    signals =
      []
      |> add_if(Rules.known_tracker_url?(url), %{
        weight: 6,
        reason: "known email/web analytics tracking endpoint"
      })
      |> add_if(tracking_word_in_path?(String.downcase(uri.path || ""), uri.query), %{
        weight: 3,
        reason: "path/query contains tracking endpoint word"
      })
      |> add_if(Rules.short_link?(url), %{
        weight: 2,
        reason: "short redirect service hides final destination"
      })
      |> add_if(tracking_params != [], %{
        weight: 2,
        reason: "campaign tracking parameters: #{Enum.join(tracking_params, ", ")}"
      })
      |> add_if(identifiers != [], %{
        weight: identifier_weight(identifiers),
        reason: "recipient identifier in URL"
      })
      |> add_if(HTMLSignals.attr(attrs, "data-track") != nil, %{
        weight: 2,
        reason: "element has data-track attribute"
      })

    score = signals |> Enum.map(& &1.weight) |> Enum.sum()

    action =
      cond do
        Rules.known_tracker_url?(url) or score >= thresholds.block -> :redirect
        tracking_params != [] -> :sanitize
        identifiers != [] -> Keyword.get(opts, :identified_link_action, :redirect)
        score >= thresholds.proxy -> :redirect
        true -> :allow
      end

    %{
      kind:
        if(identifiers != [] or score >= thresholds.proxy, do: :personalized_link, else: :link),
      action: action,
      score: score,
      confidence: confidence(score),
      url: url,
      reasons: Enum.map(signals, & &1.reason),
      identifiers: identifiers,
      tracking_params: tracking_params,
      signals: signals
    }
  end

  def classify_link(_url, _attrs, _opts), do: nil

  defp image_signals(url, attrs, style, opts) do
    uri = URI.parse(url)
    path = String.downcase(uri.path || "")
    haystack = String.downcase(url)

    []
    |> add_if(Rules.known_tracker_url?(url), %{
      weight: 6,
      reason: "URL matches a known tracking provider endpoint"
    })
    |> add_if(tracking_word_in_path?(path, uri.query), %{
      weight: 3,
      reason: "path/query contains tracking endpoint word"
    })
    |> add_if(HTMLSignals.transparent_image_name?(url), %{
      weight: 2,
      reason: "file name is commonly used for transparent pixels/spacers"
    })
    |> add_if(HTMLSignals.tiny_box?(attrs, style), %{
      weight: 4,
      reason: "rendered box is zero or at most 2x2 pixels"
    })
    |> add_if(HTMLSignals.hidden?(attrs, style), %{
      weight: 4,
      reason: "image is hidden with CSS/ARIA"
    })
    |> add_if(HTMLSignals.offscreen?(attrs, style), %{
      weight: 2,
      reason: "image is positioned off-screen"
    })
    |> add_if(WebURL.identifier_signals(url) != [], %{
      weight: 3,
      reason: "URL contains a recipient-specific identifier"
    })
    |> add_if(WebURL.tracking_params(url) != [], %{
      weight: 1,
      reason: "URL contains campaign tracking parameters"
    })
    |> add_if(String.starts_with?(url, "data:image/"), %{
      weight: -100,
      reason: "embedded data URI"
    })
    |> add_if(cid_url?(url), %{weight: -100, reason: "MIME cid resource"})
    |> add_if(has_normal_dimensions?(attrs, style), %{
      weight: -2,
      reason: "explicit normal display dimensions"
    })
    |> add_if(non_tracking_alt?(attrs), %{weight: -1, reason: "meaningful alt text"})
    |> add_if(marketing_asset_path?(path), %{weight: -1, reason: "marketing/content asset path"})
    |> maybe_add_proxy_all_signal(opts, haystack)
  end

  defp maybe_add_proxy_all_signal(signals, opts, _haystack) do
    if Keyword.get(opts, :proxy_all_remote_images, true) do
      signals
    else
      signals
    end
  end

  defp image_action(score, signals, thresholds) do
    cond do
      Enum.any?(signals, &(&1.weight <= -100)) -> :allow
      score >= thresholds.block -> :block
      true -> :proxy
    end
  end

  defp thresholds(opts) do
    %{
      block: Keyword.get(opts, :block_threshold, config(:block_threshold, 6)),
      proxy: Keyword.get(opts, :proxy_threshold, config(:proxy_threshold, 2))
    }
  end

  defp config(key, default), do: Application.get_env(:privacy_mail, key, default)

  defp add_if(list, true, signal), do: [signal | list]
  defp add_if(list, false, _signal), do: list

  defp confidence(score) when score >= 8, do: :very_high
  defp confidence(score) when score >= 6, do: :high
  defp confidence(score) when score >= 3, do: :medium
  defp confidence(_), do: :low

  defp tracking_word_in_path?(path, query) do
    target = String.downcase(path <> "?" <> (query || ""))

    # Require endpoint-like placement or punctuation boundaries. This avoids
    # treating /blog/best-pixel-art or /open-source-logo as a tracker solely
    # because of a substring match.
    Enum.any?(Rules.tracking_url_words(), fn word ->
      escaped = Regex.escape(word)

      Regex.match?(~r{(?:/|^)#{escaped}(?:[/.?=&]|$)}i, target) or
        Regex.match?(~r{[?&]#{escaped}(?:=|&|$)}i, target)
    end)
  end

  defp cid_url?("cid:" <> _), do: true
  defp cid_url?(_), do: false

  defp has_normal_dimensions?(attrs, style) do
    w = HTMLSignals.attr(attrs, "width") || style["width"]
    h = HTMLSignals.attr(attrs, "height") || style["height"]

    case {parse_dim(w), parse_dim(h)} do
      {w, h} when is_number(w) and is_number(h) and (w >= 80 or h >= 80) -> true
      _ -> false
    end
  end

  defp parse_dim(nil), do: nil

  defp parse_dim(value) do
    case Regex.run(~r/(\d+)/, to_string(value)) do
      [_, n] -> String.to_integer(n)
      _ -> nil
    end
  end

  defp non_tracking_alt?(attrs) do
    alt = HTMLSignals.attr(attrs, "alt")

    is_binary(alt) and String.trim(alt) != "" and
      String.downcase(String.trim(alt)) not in ~w[pixel image spacer blank tracking]
  end

  defp marketing_asset_path?(path) do
    String.contains?(path, ["/images/", "/img/", "/assets/", "/media/", "/static/"]) and
      not String.contains?(path, ["track", "pixel", "beacon", "open"])
  end

  defp identifier_weight([]), do: 0

  defp identifier_weight(identifiers) do
    kinds = MapSet.new(identifiers, & &1.kind)

    cond do
      :email_value in kinds or :encoded_email in kinds -> 5
      length(identifiers) >= 2 -> 5
      true -> 3
    end
  end
end
