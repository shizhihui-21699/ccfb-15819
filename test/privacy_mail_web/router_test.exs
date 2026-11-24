defmodule PrivacyMailWeb.RouterTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias PrivacyMail.Proxy.Token
  alias PrivacyMailWeb.Router

  @opts Router.init([])

  test "proxies a signed image and returns safe image headers" do
    id = System.unique_integer([:positive])
    url = "https://cdn-#{id}.example/logo.gif"
    token = Token.sign_image(url)

    conn =
      conn(:get, "/proxy/image?token=#{URI.encode_www_form(token)}")
      |> Router.call(@opts)

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/gif"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    assert conn.resp_body == PrivacyMail.Test.StubFetcher.gif()
  end

  test "rejects unsigned proxy requests" do
    conn = conn(:get, "/proxy/image?token=not-valid") |> Router.call(@opts)
    assert conn.status == 400
    assert get_resp_header(conn, "content-type") == ["image/gif"]
  end

  test "returns transparent pixel when upstream fails so layout does not break" do
    token = Token.sign_image("https://fail.example/broken.png")
    conn = conn(:get, "/proxy/image?token=#{URI.encode_www_form(token)}") |> Router.call(@opts)

    assert conn.status == 200
    assert get_resp_header(conn, "x-pm-proxy-error") != []
    assert get_resp_header(conn, "content-type") == ["image/gif"]
  end

  test "signed redirect strips campaign parameters" do
    target = "https://example.com/path?utm_source=email&id=42"
    token = Token.sign_redirect(target)

    conn = conn(:get, "/redirect?token=#{URI.encode_www_form(token)}") |> Router.call(@opts)

    assert conn.status == 302
    [location] = get_resp_header(conn, "location")
    assert location =~ "id=42"
    refute location =~ "utm_source"
  end

  test "POST /api/privatize returns rewritten html and counts" do
    body =
      Jason.encode!(%{
        html: ~s(<img src="https://cdn.example/a.jpg" width="400" height="200" alt="A">)
      })

    conn =
      conn(:post, "/api/privatize", body)
      |> put_req_header("content-type", "application/json")
      |> Router.call(@opts)

    assert conn.status == 200
    response = Jason.decode!(conn.resp_body)
    assert response["counts"]["images_proxied"] == 1
    assert response["html"] =~ "/proxy/image?token="
  end

  test "health endpoint" do
    conn = conn(:get, "/healthz") |> Router.call(@opts)
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["status"] == "ok"
  end
end
