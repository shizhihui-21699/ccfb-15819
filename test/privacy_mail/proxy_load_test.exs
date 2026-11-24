defmodule PrivacyMail.ProxyLoadTest do
  use ExUnit.Case, async: false

  alias PrivacyMail.Proxy.Loader

  test "coalesces concurrent misses into one upstream fetch and then serves cache hits" do
    id = System.unique_integer([:positive])
    url = "https://campaign-#{id}.example/hero.gif"
    counter = :counters.new(1, [:atomics])

    results =
      1..24
      |> Enum.map(fn _ ->
        Task.async(fn ->
          Loader.load(url, fetcher: PrivacyMail.Test.StubFetcher, counter_ref: counter, delay: 75)
        end)
      end)
      |> Task.await_many(5_000)

    assert Enum.all?(results, &match?({:ok, _entry, _source}, &1))
    assert :counters.get(counter, 1) == 1

    assert {:ok, _entry, :hit} =
             Loader.load(url, fetcher: PrivacyMail.Test.StubFetcher, counter_ref: counter)

    assert :counters.get(counter, 1) == 1
  end

  test "caches upstream failures briefly" do
    id = System.unique_integer([:positive])
    url = "https://fail-#{id}.example/image.png"
    counter = :counters.new(1, [:atomics])

    assert {:error, :upstream_status} =
             Loader.load(url, fetcher: PrivacyMail.Test.StubFetcher, counter_ref: counter)

    assert {:error, :upstream_status} =
             Loader.load(url, fetcher: PrivacyMail.Test.StubFetcher, counter_ref: counter)

    assert :counters.get(counter, 1) == 1
  end
end
