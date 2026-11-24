import Config

config :privacy_mail,
  # Scores >= block_threshold are replaced with a local transparent beacon.
  block_threshold: 6,
  # Scores in [proxy_threshold, block_threshold) are proxied and sanitized.
  proxy_threshold: 2,
  strip_tracking_params: true,
  rewrite_links: :sanitize,
  proxy_route_path: "/proxy/image",
  redirect_route_path: "/redirect",
  # Set this for absolute URLs when webmail and the proxy are on different origins.
  proxy_base_url: nil,
  transparent_pixel_uri: "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==",
  max_image_bytes: 5 * 1024 * 1024,
  max_redirects: 3,
  fetch_timeout_ms: 10_000,
  cache_default_ttl_ms: :timer.minutes(30),
  cache_negative_ttl_ms: :timer.minutes(5),
  cache_max_entries: 5_000,
  cache_max_bytes: 256 * 1024 * 1024,
  block_private_networks: true,
  allowed_image_types: ~w(image/gif image/png image/jpeg image/webp image/avif image/svg+xml),
  user_agent: "PrivacyMail Image Proxy/0.1 (+enterprise privacy gateway)"

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

import_config "#{config_env()}.exs"
