defmodule PrivacyMail.Tracking.Rules do
  @moduledoc """
  Curated detection rules for common email tracking infrastructure.

  The lists are intentionally conservative. Generic URL words alone never
  block an image; they contribute a score that is combined with rendering
  signals such as a 1x1 box or hidden inline style.
  """

  @tracking_param_names ~w[
    gclid dclid fbclid ttclid twclid msclkid yclid li_fat_id
    mc_cid mc_eid mkt_tok _hsenc _hsmi hsctatracking
    utm_source utm_medium utm_campaign utm_term utm_content utm_id utm_name
    pk_campaign pk_kwd pk_source pk_medium pk_content
    spm scm igshid _branch_match_id
    ml_subscriber ml_subscriber_hash ck_subscriber_id
    _ke _kx _ko _ks
  ]

  @identifier_param_names ~w[
    email e em mail recipient recipient_id rcpt to
    subscriber subscriber_id contact contact_id user user_id uid
    customer customer_id account account_id profile profile_id
    member member_id mc_eid mc_cid ml_subscriber ck_subscriber_id
    token access_token auth signature sig hmac key
    campaign_id mailing_id message_id msg_id mid delivery_id
  ]

  @tracking_url_words ~w[
    track tracking tracker trace beacon beacons pixel pixels
    open opens opened openpixel webhook log logger collect collection
    event events analytics metrics telemetry impression impressions
    read-receipt readreceipt
  ]

  @tracking_file_names ~w[
    pixel.gif pixel.png pixel.jpg pixel.jpeg
    clear.gif blank.gif spacer.gif dot.gif transparent.gif
    open.gif open.png tracker.gif beacon.gif
  ]

  @tracker_host_suffixes ~w[
    google-analytics.com
    googletagmanager.com
    doubleclick.net
    googleadservices.com
    google.com/pagead
    facebook.com/tr
    connect.facebook.net
    analytics.twitter.com
    ads-twitter.com
    ads.linkedin.com
    pixel.linkedin.com
    bat.bing.com
    clarity.ms
    hotjar.com
    hotjar.io
    mixpanel.com
    mxpnl.com
    segment.io
    segment.com
    amplutide.com
    amplitude.com
    heap-api.com
    fullstory.com
    mouseflow.com
    luckyorange.com
    cr-rel.com
    sendgrid.net/wf/open
    sendgrid.com/wf/open
    mailchimp.com/track
    list-manage.com/track
    list-manage.com
    klaviyo.com
    klaviyomail.com
    hubspot.com
    hubspotemail.net
    hs-analytics.net
    hs-banner.com
    inspectlet.com
    mouseflow.com
    pardot.com
    marketo.com
    marketoemail.com
    exacttarget.com
    sfmc.net
    salesforce.com
    dotdigitalmail.com
    dotmailer.com
    campaignmonitor.com
    cmail19.com
    cmail20.com
    cmail21.com
    constantcontact.com
    icontact.com
    aweber.com
    getresponse.com
    mailgun.org
    mailgun.com
    postmarkapp.com
    pstmrk.it
    sparkpostmail.com
    sparkpost.com
  ]

  # Generic cloud/CDN hosts are only weak host signals; path/query evidence is
  # required before treating them as tracking infrastructure.
  @weak_host_suffixes ~w[amazonaws.com cloudfront.net]

  @short_link_hosts ~w[
    bit.ly tinyurl.com t.co ow.ly buff.ly rebrand.ly
    cutt.ly is.gd v.gd rb.gy shorturl.at
  ]

  def tracking_param_names, do: @tracking_param_names
  def identifier_param_names, do: @identifier_param_names
  def tracking_url_words, do: @tracking_url_words
  def tracking_file_names, do: @tracking_file_names
  def tracker_host_suffixes, do: @tracker_host_suffixes
  def weak_host_suffixes, do: @weak_host_suffixes
  def short_link_hosts, do: @short_link_hosts

  def known_tracker_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host, path: path} when is_binary(host) ->
        normalized_host = String.downcase(host)
        path = path || ""
        host_with_path = normalized_host <> path

        Enum.any?(@tracker_host_suffixes, fn suffix ->
          if String.contains?(suffix, "/") do
            String.contains?(host_with_path, suffix)
          else
            host_matches?(normalized_host, suffix) and
              tracker_path_or_query?(path, url)
          end
        end) or exact_tracking_endpoint?(normalized_host, path)

      _ ->
        false
    end
  end

  def known_tracker_url?(_), do: false

  def weak_tracker_host?(host) when is_binary(host) do
    host = String.downcase(host)
    Enum.any?(@weak_host_suffixes, &host_matches?(host, &1))
  end

  def short_link?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) ->
        Enum.any?(@short_link_hosts, &host_matches?(String.downcase(host), &1))

      _ ->
        false
    end
  end

  def host_matches?(host, suffix) do
    host == suffix or String.ends_with?(host, "." <> suffix)
  end

  defp tracker_path_or_query?(path, url) do
    query = URI.parse(url).query || ""
    target = String.downcase(path <> "?" <> query)

    Enum.any?(@tracking_url_words, fn word ->
      escaped = Regex.escape(word)

      Regex.match?(~r{(?:/|^)#{escaped}(?:[/.?=&]|$)}i, target) or
        Regex.match?(~r{[?&]#{escaped}(?:=|&|$)}i, target) or
        String.contains?(target, "/" <> word <> ".")
    end)
  end

  defp exact_tracking_endpoint?(host, path) do
    path = String.downcase(path || "")

    ((host == "www.facebook.com" or host == "facebook.com") and
       String.starts_with?(path, "/tr")) or
      (host == "www.google-analytics.com" and String.starts_with?(path, "/collect")) or
      (host == "www.google.com" and String.starts_with?(path, "/ads/ga-audiences"))
  end
end
