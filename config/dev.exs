import Config

config :privacy_mail,
  http_port: 4000,
  proxy_secret: System.get_env("PRIVACY_MAIL_PROXY_SECRET", "dev-only-secret-change-me")
