defmodule PrivacyMail do
  @moduledoc """
  Privacy-preserving email tracking defense and image proxy.

  Typical integration:

      html
      |> PrivacyMail.Email.privatize!(proxy_base_url: "https://mail.example/privacy")
      |> MyMailbox.render()

  The rewritten message blocks high-confidence beacons without fetching them,
  proxies ordinary images lazily through `PrivacyMailWeb.Router`, strips
  referrer/cookie metadata, and coalesces concurrent cache misses.
  """

  defdelegate analyze(html, opts \\ []), to: PrivacyMail.Email
  defdelegate privatize(html, opts \\ []), to: PrivacyMail.Email
  defdelegate privatize!(html, opts \\ []), to: PrivacyMail.Email

  def analyze_text(text, opts \\ []), do: PrivacyMail.PlainText.analyze(text, opts)
  def privatize_text(text, opts \\ []), do: PrivacyMail.PlainText.privatize(text, opts)
end
