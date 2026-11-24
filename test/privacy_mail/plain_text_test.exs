defmodule PrivacyMail.PlainTextTest do
  use ExUnit.Case, async: true

  alias PrivacyMail.PlainText

  @secret "test-proxy-secret-please-change"

  test "strips tracking parameters from plain text links" do
    text = "Visit https://shop.example/item?utm_campaign=may&id=42, thanks."

    assert {:ok, safe, report} = PlainText.privatize(text, secret: @secret)
    assert safe =~ "https://shop.example/item?id=42"
    refute safe =~ "utm_campaign"
    assert safe =~ ", thanks."
    assert report.counts.links_sanitized == 1
  end

  test "wraps personalized plain text links" do
    text = "Verify: https://login.example/?email=ceo%40example.com&token=abcdef1234567890"

    assert {:ok, safe, report} =
             PlainText.privatize(text, secret: @secret, proxy_base_url: "https://pm.example")

    assert safe =~ "https://pm.example/redirect?token=v1.go."
    assert report.counts.personalized_links == 1
  end
end
