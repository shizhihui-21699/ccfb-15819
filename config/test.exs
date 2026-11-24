import Config

config :privacy_mail,
  http_port: 0,
  proxy_secret: "test-proxy-secret-please-change",
  block_private_networks: false,
  fetcher: PrivacyMail.Test.StubFetcher

config :logger, level: :warning
