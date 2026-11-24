defmodule PrivacyMail.Proxy.Token do
  @moduledoc """
  HMAC-signed capabilities for the image proxy and redirect gateway.

  The token prevents ordinary clients from turning this service into an open
  proxy. It does not hide the destination from the recipient's mail server;
  server-side token storage can be added for deployments that need opaque IDs.
  """

  @version "v1"

  def sign_image(url, secret \\ secret()) when is_binary(url) do
    sign("img", url, secret)
  end

  def sign_redirect(url, secret \\ secret()) when is_binary(url) do
    sign("go", url, secret)
  end

  def verify_image(token, secret \\ secret()) do
    verify(token, "img", secret)
  end

  def verify_redirect(token, secret \\ secret()) do
    verify(token, "go", secret)
  end

  def sign(purpose, url, secret) when purpose in ["img", "go"] and is_binary(url) do
    encoded = Base.url_encode64(url, padding: false)
    body = [@version, purpose, encoded] |> Enum.join(".")
    sig = secret |> hmac(body) |> Base.url_encode64(padding: false)
    body <> "." <> sig
  end

  def verify(token, expected_purpose, secret) when is_binary(token) do
    with [@version, purpose, encoded, sig] <- String.split(token, ".", parts: 4),
         expected_sig <- secret |> hmac([@version, purpose, encoded] |> Enum.join(".")),
         provided_sig <- decode_sig(sig),
         true <-
           is_binary(provided_sig) and Plug.Crypto.secure_compare(expected_sig, provided_sig),
         ^expected_purpose <- purpose,
         {:ok, url} <- Base.url_decode64(encoded, padding: false) do
      {:ok, url}
    else
      _ -> {:error, :invalid_token}
    end
  end

  def verify(_token, _purpose, _secret), do: {:error, :invalid_token}

  def proxy_path(url, opts \\ []) do
    token = sign_image(url, Keyword.get(opts, :secret, secret()))
    route = Keyword.get(opts, :proxy_route_path, config(:proxy_route_path, "/proxy/image"))
    route <> "?token=" <> URI.encode_www_form(token)
  end

  def redirect_path(url, opts \\ []) do
    token = sign_redirect(url, Keyword.get(opts, :secret, secret()))
    route = Keyword.get(opts, :redirect_route_path, config(:redirect_route_path, "/redirect"))
    route <> "?token=" <> URI.encode_www_form(token)
  end

  def absolute_proxy_url(url, opts \\ []) do
    case Keyword.get(opts, :base_url, config(:proxy_base_url)) do
      nil -> proxy_path(url, opts)
      base -> String.trim_trailing(base, "/") <> proxy_path(url, opts)
    end
  end

  def absolute_redirect_url(url, opts \\ []) do
    case Keyword.get(opts, :base_url, config(:proxy_base_url)) do
      nil -> redirect_path(url, opts)
      base -> String.trim_trailing(base, "/") <> redirect_path(url, opts)
    end
  end

  def secret do
    case Application.get_env(:privacy_mail, :proxy_secret) do
      secret when is_binary(secret) and byte_size(secret) >= 16 ->
        secret

      secret when is_binary(secret) ->
        raise "PrivacyMail proxy_secret must be at least 16 bytes"

      nil ->
        case :persistent_term.get({__MODULE__, :secret}, nil) do
          nil ->
            secret = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
            :persistent_term.put({__MODULE__, :secret}, secret)
            secret

          secret ->
            secret
        end
    end
  end

  defp hmac(secret, body), do: :crypto.mac(:hmac, :sha256, secret, body)

  defp decode_sig(sig) do
    case Base.url_decode64(sig, padding: false) do
      {:ok, bytes} -> bytes
      :error -> nil
    end
  end

  defp config(key), do: Application.get_env(:privacy_mail, key)
  defp config(key, default), do: Application.get_env(:privacy_mail, key, default)
end
