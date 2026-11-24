defmodule PrivacyMail.ClassifierTest do
  use ExUnit.Case, async: true

  alias PrivacyMail.Tracking.Classifier

  describe "classify_image/3" do
    test "blocks a hidden 1x1 SendGrid open pixel" do
      finding =
        Classifier.classify_image(
          "https://u123.sendgrid.net/wf/open?upn=abc.def_recipient-456",
          [{"width", "1"}, {"height", "1"}, {"style", "display:none"}]
        )

      assert finding.action == :block
      assert finding.kind == :tracking_pixel
      assert finding.score >= 6
      assert Enum.any?(finding.reasons, &String.contains?(&1, "known"))
    end

    test "blocks a generic invisible beacon with tracking path and recipient id" do
      finding =
        Classifier.classify_image(
          "https://stats.example-mail.net/track/open.gif?recipient_id=8f31c9e2aa7642",
          [{"width", "1"}, {"height", "1"}]
        )

      assert finding.action == :block
      assert finding.score >= 6
    end

    test "proxies but does not block a visible marketing image" do
      finding =
        Classifier.classify_image(
          "https://cdn.shop.example/assets/holiday-banner-1200x400.jpg?utm_campaign=winter",
          [{"width", "600"}, {"height", "200"}, {"alt", "Winter sale"}]
        )

      assert finding.action == :proxy
      assert finding.kind == :remote_image
      assert finding.score < 6
    end

    test "proxies normal notification logo even when hosted on an ESP CDN" do
      finding =
        Classifier.classify_image(
          "https://cdn.mail-provider.example/media/security-alert.png",
          [{"width", "96"}, {"height", "96"}, {"alt", "Security alert"}]
        )

      assert finding.action == :proxy
      refute Enum.any?(finding.reasons, &(&1 =~ "known tracking provider"))
    end

    test "never treats embedded images as remote candidates" do
      finding = Classifier.classify_image("data:image/gif;base64,AAAA", [])
      assert finding.action == :allow
    end
  end

  describe "classify_link/3" do
    test "detects email-valued personal identifiers" do
      finding =
        Classifier.classify_link(
          "https://app.example.com/confirm?email=ceo%40example.com&campaign_id=22"
        )

      assert finding.action == :redirect
      assert Enum.any?(finding.identifiers, &(&1.kind == :email_value))
    end

    test "sanitizes known campaign parameters without blocking destination" do
      finding =
        Classifier.classify_link(
          "https://news.example.com/article?utm_source=mailchimp&utm_campaign=q4&id=42"
        )

      assert finding.action == :sanitize
      assert "utm_source" in finding.tracking_params
    end

    test "recognizes known click tracking endpoints" do
      finding =
        Classifier.classify_link(
          "https://track.example-esp.com/track/click?u=abc&id=xyz&e=recipient%40example.com"
        )

      assert finding.action == :redirect
      assert finding.score >= 6
    end
  end
end
