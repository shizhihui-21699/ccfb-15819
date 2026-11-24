import Config

# Runtime configuration for container/bare-metal deployments.
# PRIVACY_MAIL_PROXY_SECRET must be stable across releases and proxy nodes.
if config_env() == :prod do
  config :privacy_mail,
    proxy_secret: System.fetch_env!("PRIVACY_MAIL_PROXY_SECRET"),
    proxy_base_url: System.get_env("PROXY_BASE_URL")

  bind_ip = System.get_env("BIND_IP", "0.0.0.0")

  http_ip =
    case :inet.parse_address(String.to_charlist(bind_ip)) do
      {:ok, ip} -> ip
      {:error, _} -> {0, 0, 0, 0}
    end

  config :privacy_mail,
    http_ip: http_ip,
    http_port: String.to_integer(System.get_env("PORT", "4000"))
end
