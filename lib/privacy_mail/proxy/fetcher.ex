defmodule PrivacyMail.Proxy.Fetcher do
  @moduledoc """
  Minimal, privacy-preserving upstream image client.

  It never forwards the recipient's cookies, authorization, client IP,
  Referer or User-Agent. Redirect targets are validated again to prevent an
  allowed public URL from redirecting to an internal address.
  """

  @type response :: %{
          status: pos_integer(),
          headers: [{String.t(), String.t()}],
          body: binary(),
          content_type: String.t()
        }

  @callback fetch(String.t(), keyword()) :: {:ok, response()} | {:error, term()}

  @behaviour __MODULE__

  alias PrivacyMail.Proxy.SSRF

  @impl true
  def fetch(url, opts \\ []) do
    max_bytes = Keyword.get(opts, :max_bytes, config(:max_image_bytes, 5_000_000))
    timeout = Keyword.get(opts, :timeout, config(:fetch_timeout_ms, 10_000))
    max_redirects = Keyword.get(opts, :max_redirects, config(:max_redirects, 3))
    validate? = Keyword.get(opts, :validate_ssrf?, true)

    with :ok <- validate_url(url, validate?, opts),
         {:ok, response} <- request(url, max_bytes, timeout),
         {:ok, response} <- maybe_redirect(response, max_redirects, opts) do
      finalize(response, opts)
    end
  end

  defp validate_url(_url, false, _opts), do: :ok

  defp validate_url(url, true, opts) do
    case SSRF.validate(url, opts) do
      {:ok, _uri, _ips} -> :ok
      {:error, reason} -> {:error, {:ssrf_blocked, reason}}
    end
  end

  defp request(url, max_bytes, timeout) do
    headers = [
      {"user-agent", config(:user_agent, "PrivacyMail Image Proxy")},
      {"accept", "image/avif,image/webp,image/png,image/gif,image/jpeg,*/*;q=0.8"},
      {"accept-encoding", "identity"}
    ]

    req = Finch.build(:get, url, headers, nil)

    acc = %{status: 0, headers: [], chunks: [], size: 0, halted: nil}

    result =
      Finch.stream_while(
        req,
        PrivacyMail.Finch,
        acc,
        fn
          {:status, status}, acc ->
            {:cont, %{acc | status: status}}

          {:headers, headers}, acc ->
            {:cont, %{acc | headers: headers}}

          {:data, data}, acc ->
            new_size = acc.size + byte_size(data)

            if new_size > max_bytes do
              {:halt, %{acc | size: new_size, halted: :too_large}}
            else
              {:cont, %{acc | chunks: [data | acc.chunks], size: new_size}}
            end

          _, acc ->
            {:cont, acc}
        end,
        receive_timeout: timeout,
        request_timeout: timeout
      )

    case result do
      {:ok, %{halted: :too_large}} ->
        {:error, :image_too_large}

      {:ok, acc} when acc.status in 200..299 ->
        body = acc.chunks |> Enum.reverse() |> IO.iodata_to_binary()
        {:ok, %{status: acc.status, headers: acc.headers, body: body, url: url}}

      {:ok, acc} when acc.status in 300..399 ->
        body = acc.chunks |> Enum.reverse() |> IO.iodata_to_binary()
        {:ok, %{status: acc.status, headers: acc.headers, body: body, url: url}}

      {:ok, acc} ->
        {:error, {:upstream_status, acc.status}}

      {:error, reason, _acc} ->
        {:error, normalize_finch_error(reason)}
    end
  rescue
    exception -> {:error, {:fetch_failed, Exception.message(exception)}}
  end

  defp maybe_redirect(response, remaining, opts) do
    if response.status in [301, 302, 303, 307, 308] and remaining > 0 do
      location = get_header(response.headers, "location")

      with true <- is_binary(location) and location != "",
           next_url <- URI.merge(response.url, location) |> URI.to_string(),
           :ok <- validate_url(next_url, Keyword.get(opts, :validate_ssrf?, true), opts) do
        fetch(next_url, Keyword.put(opts, :max_redirects, remaining - 1))
      else
        _ -> {:ok, response}
      end
    else
      {:ok, response}
    end
  end

  defp finalize(response, opts) do
    allowed = Keyword.get(opts, :allowed_types, config(:allowed_image_types, []))

    case sniff_content_type(response.body, response.headers) do
      {:ok, content_type} ->
        if allowed == [] or content_type in allowed or allowed_wildcard?(allowed, content_type) do
          {:ok,
           response
           |> Map.put(:content_type, content_type)
           |> Map.delete(:url)}
        else
          {:error, {:unsupported_media_type, content_type}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Sniffs common image magic bytes and falls back to a trustworthy image content type."
  def sniff_content_type(body, headers) when is_binary(body) do
    declared =
      headers
      |> get_header("content-type")
      |> case do
        nil -> nil
        value -> value |> String.split(";") |> hd() |> String.trim() |> String.downcase()
      end

    cond do
      String.starts_with?(body, "GIF87a") or String.starts_with?(body, "GIF89a") ->
        {:ok, "image/gif"}

      match?(<<0x89, ?P, ?N, ?G, 0x0D, 0x0A, 0x1A, 0x0A, _::binary>>, body) ->
        {:ok, "image/png"}

      match?(<<0xFF, 0xD8, 0xFF, _::binary>>, body) ->
        {:ok, "image/jpeg"}

      byte_size(body) >= 12 and binary_part(body, 0, 4) == "RIFF" and
          binary_part(body, 8, 4) == "WEBP" ->
        {:ok, "image/webp"}

      byte_size(body) >= 12 and binary_part(body, 4, 4) == "ftyp" and
          binary_part(body, 8, 4) in ["avif", "avis"] ->
        {:ok, "image/avif"}

      svg?(body) and declared in [nil, "image/svg+xml", "text/xml", "application/xml"] ->
        {:ok, "image/svg+xml"}

      is_binary(declared) and String.starts_with?(declared, "image/") ->
        {:ok, declared}

      true ->
        {:error, :not_an_image}
    end
  end

  defp svg?(body) do
    head = body |> binary_part(0, min(byte_size(body), 512)) |> String.downcase()

    String.contains?(head, "<svg") or
      (String.contains?(head, "<?xml") and String.contains?(head, "<svg"))
  end

  defp allowed_wildcard?(allowed, content_type) do
    Enum.any?(allowed, fn pattern ->
      String.ends_with?(pattern, "/*") and
        String.starts_with?(content_type, String.trim_trailing(pattern, "*"))
    end)
  end

  defp get_header(headers, name) do
    Enum.find_value(headers || [], fn {k, v} ->
      if String.downcase(to_string(k)) == name, do: v
    end)
  end

  defp normalize_finch_error(%Finch.Error{reason: reason}), do: reason
  defp normalize_finch_error(reason) when is_atom(reason), do: reason
  defp normalize_finch_error(reason), do: {:fetch_failed, inspect(reason)}

  defp config(key, default), do: Application.get_env(:privacy_mail, key, default)
end
