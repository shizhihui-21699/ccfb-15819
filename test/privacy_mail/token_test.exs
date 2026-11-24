defmodule PrivacyMail.TokenTest do
  use ExUnit.Case, async: true

  alias PrivacyMail.Proxy.Token

  @secret "unit-test-secret-at-least-16-bytes"

  test "image tokens round-trip" do
    token = Token.sign_image("https://cdn.example/a.png", @secret)
    assert {:ok, "https://cdn.example/a.png"} = Token.verify_image(token, @secret)
  end

  test "rejects tampered payload and wrong purpose" do
    token = Token.sign_image("https://cdn.example/a.png", @secret)
    [version, purpose, encoded, sig] = String.split(token, ".", parts: 4)
    tampered = Enum.join([version, purpose, encoded <> "x", sig], ".")

    assert {:error, :invalid_token} = Token.verify_image(tampered, @secret)

    redirect = Token.sign_redirect("https://example.com", @secret)
    assert {:error, :invalid_token} = Token.verify_image(redirect, @secret)
  end

  test "proxy path is signed and local by default" do
    path = Token.proxy_path("https://example.com/a.png", secret: @secret)
    assert path =~ "/proxy/image?token=v1.img."
  end
end
