defmodule PrivacyMail.SSRFTest do
  use ExUnit.Case, async: true

  alias PrivacyMail.Proxy.SSRF

  test "blocks IPv4 local and metadata ranges" do
    assert SSRF.private?({127, 0, 0, 1})
    assert SSRF.private?({10, 0, 0, 8})
    assert SSRF.private?({192, 168, 1, 1})
    assert SSRF.private?({169, 254, 169, 254})
    assert SSRF.private?({172, 16, 0, 1})
    refute SSRF.private?({8, 8, 8, 8})
    refute SSRF.private?({104, 20, 30, 40})
  end

  test "blocks IPv6 loopback, ULA and link-local" do
    assert SSRF.private?({0, 0, 0, 0, 0, 0, 0, 1})
    assert SSRF.private?({0xFC00, 0, 0, 0, 0, 0, 0, 1})
    assert SSRF.private?({0xFE80, 0, 0, 0, 0, 0, 0, 1})
    refute SSRF.private?({0x2606, 0x4700, 0, 0, 0, 0, 0, 0x1111})
  end

  test "validates literal private URL when protection enabled" do
    assert {:error, {:blocked_address, "127.0.0.1"}} =
             SSRF.validate("http://127.0.0.1/latest/meta-data", block_private_networks?: true)
  end

  test "rejects non-http schemes" do
    assert {:error, :unsupported_scheme} = SSRF.validate("file:///etc/passwd")
    assert {:error, :unsupported_scheme} = SSRF.validate("gopher://internal/")
  end
end
