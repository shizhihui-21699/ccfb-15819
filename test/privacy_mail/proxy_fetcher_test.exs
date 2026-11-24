defmodule PrivacyMail.ProxyFetcherTest do
  use ExUnit.Case, async: true

  alias PrivacyMail.Proxy.Fetcher

  @gif PrivacyMail.Test.StubFetcher.gif()

  test "streams and sniffs a real HTTP image response" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 2_000)
        _ = :gen_tcp.recv(socket, 0, 1_000)

        response =
          [
            "HTTP/1.1 200 OK\r\n",
            "Content-Type: image/gif\r\n",
            "Content-Length: #{byte_size(@gif)}\r\n",
            "Cache-Control: public, max-age=60\r\n",
            "Connection: close\r\n\r\n",
            @gif
          ]
          |> IO.iodata_to_binary()

        :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
        :gen_tcp.close(listener)
      end)

    assert {:ok, response} =
             Fetcher.fetch("http://127.0.0.1:#{port}/pixel.gif", validate_ssrf?: false)

    assert response.status == 200
    assert response.content_type == "image/gif"
    assert response.body == @gif
    Task.await(server)
  end

  test "rejects non-image bodies" do
    assert {:error, :not_an_image} =
             Fetcher.sniff_content_type("<html><script>alert(1)</script>", [
               {"content-type", "text/html"}
             ])
  end
end
