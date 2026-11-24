defmodule PrivacyMail.Test.StubFetcher do
  @moduledoc false

  @behaviour PrivacyMail.Proxy.Fetcher

  @gif <<71, 73, 70, 56, 57, 97, 1, 0, 1, 0, 128, 0, 0, 0, 0, 0, 255, 255, 255, 33, 249, 4, 1, 0,
         0, 0, 0, 44, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 2, 68, 1, 0, 59>>

  def gif, do: @gif

  @impl true
  def fetch(url, opts \\ []) do
    if ref = opts[:counter_ref], do: :counters.add(ref, 1, 1)
    if delay = opts[:delay], do: Process.sleep(delay)

    cond do
      String.contains?(url, "too-large.example") ->
        {:error, :image_too_large}

      String.contains?(url, "bad-type.example") ->
        {:error, :not_an_image}

      String.contains?(url, "fail") ->
        {:error, :upstream_status}

      true ->
        {:ok,
         %{
           status: 200,
           headers: [{"content-type", "image/gif"}],
           body: @gif,
           content_type: "image/gif"
         }}
    end
  end
end
