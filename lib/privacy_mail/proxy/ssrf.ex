defmodule PrivacyMail.Proxy.SSRF do
  @moduledoc """
  URL and DNS validation for the image proxy.

  The proxy can fetch arbitrary sender-controlled URLs, so it must never
  become a way to reach cloud metadata, router admin pages or an internal
  network. Private-address blocking is enabled outside the test environment.
  """

  alias PrivacyMail.WebURL

  @type ip :: :inet.ip_address()

  def validate(url, opts \\ []) do
    block_private? =
      Keyword.get(opts, :block_private_networks?, config(:block_private_networks, true))

    with true <- WebURL.http_url?(url) || {:error, :unsupported_scheme},
         uri = URI.parse(url),
         {:ok, addresses} <- resolve(uri.host),
         :ok <- check_addresses(addresses, block_private?) do
      {:ok, uri, addresses}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def resolve(host) when is_binary(host) do
    host_charlist = String.to_charlist(host)

    case :inet.parse_address(host_charlist) do
      {:ok, ip} ->
        {:ok, [ip]}

      {:error, _} ->
        case :inet.getaddrs(host_charlist, :inet) do
          {:ok, v4} ->
            v6 =
              case :inet.getaddrs(host_charlist, :inet6) do
                {:ok, addrs} -> addrs
                _ -> []
              end

            {:ok, Enum.uniq(v4 ++ v6)}

          {:error, _} ->
            case :inet.getaddrs(host_charlist, :inet6) do
              {:ok, addrs} -> {:ok, addrs}
              {:error, reason} -> {:error, {:dns_error, reason}}
            end
        end
    end
  end

  def check_addresses(addresses, false) when is_list(addresses), do: :ok

  def check_addresses(addresses, true) when is_list(addresses) do
    case Enum.find(addresses, &private?/1) do
      nil -> :ok
      ip -> {:error, {:blocked_address, format_ip(ip)}}
    end
  end

  @doc "Returns true for loopback, link-local, RFC1918 and similar local ranges."
  def private?({a, _, _, _}) when a in [0, 10, 127], do: true
  def private?({100, b, _, _}) when b in 64..127, do: true
  def private?({169, 254, _, _}), do: true
  def private?({172, b, _, _}) when b in 16..31, do: true
  def private?({192, 168, _, _}), do: true
  def private?({192, 0, 0, _}), do: true
  def private?({198, b, _, _}) when b in 18..19, do: true
  def private?({a, _, _, _}) when a in 224..255, do: true

  # IPv6
  def private?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  def private?({0, 0, 0, 0, 0, 0, 0, 0}), do: true

  def private?({0, 0, 0, 0, 0, 65535, hi, lo}) do
    private?(
      {Bitwise.bsr(hi, 8), Bitwise.band(hi, 255), Bitwise.bsr(lo, 8), Bitwise.band(lo, 255)}
    )
  end

  def private?({first, _, _, _, _, _, _, _}) when first in 0xFC00..0xFDFF, do: true
  def private?({first, _, _, _, _, _, _, _}) when first in 0xFE80..0xFEBF, do: true
  def private?({first, _, _, _, _, _, _, _}) when first in 0xFF00..0xFFFF, do: true
  def private?(_), do: false

  def format_ip(ip), do: ip |> :inet.ntoa() |> List.to_string()

  defp config(key, default), do: Application.get_env(:privacy_mail, key, default)
end
