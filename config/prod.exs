import Config

# Production must provide a stable HMAC secret, for example:
#   config :privacy_mail, proxy_secret: System.fetch_env!("PRIVACY_MAIL_PROXY_SECRET")
# and a real HTTP port if serving traffic directly.
config :privacy_mail,
  http_port: String.to_integer(System.get_env("PORT", "4000"))
