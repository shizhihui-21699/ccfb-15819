defmodule PrivacyMailWeb.Router do
  @moduledoc """
  HTTP API and privacy proxy endpoints.
  """

  use Plug.Router

  alias PrivacyMail.Email
  alias PrivacyMail.Proxy.Loader
  alias PrivacyMail.Proxy.Token
  alias PrivacyMail.WebURL

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason,
    length: 10_000_000
  )

  plug(:match)
  plug(:dispatch)

  get "/healthz" do
    send_json(conn, 200, %{status: "ok"})
  end

  get "/" do
    send_json(conn, 200, %{
      service: "privacy_mail",
      endpoints: %{
        analyze: "POST /api/analyze",
        privatize: "POST /api/privatize",
        image_proxy: "/proxy/image?token=...",
        redirect_gateway: "/redirect?token=..."
      }
    })
  end

  get "/proxy/image" do
    handle_proxy(conn)
  end

  get "/redirect" do
    handle_redirect(conn)
  end

  post "/api/analyze" do
    with {:ok, params} <- json_body(conn),
         html when is_binary(html) <- params["html"] do
      report = Email.analyze(html, opts_from_params(params))
      send_json(conn, 200, public_report(report))
    else
      _ -> send_json(conn, 400, %{error: "expected JSON body with string field `html`"})
    end
  end

  post "/api/privatize" do
    with {:ok, params} <- json_body(conn),
         html when is_binary(html) <- params["html"],
         {:ok, safe_html, report} <- Email.privatize(html, opts_from_params(params)) do
      send_json(conn, 200, %{
        html: safe_html,
        counts: report.counts,
        trackers: public_findings(report.trackers),
        personalized_links: public_findings(report.personalized_links)
      })
    else
      {:error, reason} -> send_json(conn, 422, %{error: "invalid HTML", reason: inspect(reason)})
      _ -> send_json(conn, 400, %{error: "expected JSON body with string field `html`"})
    end
  end

  match _ do
    proxy_path = Application.get_env(:privacy_mail, :proxy_route_path, "/proxy/image")
    redirect_path = Application.get_env(:privacy_mail, :redirect_route_path, "/redirect")

    cond do
      conn.method == "GET" and conn.request_path == proxy_path -> handle_proxy(conn)
      conn.method == "GET" and conn.request_path == redirect_path -> handle_redirect(conn)
      true -> send_json(conn, 404, %{error: "not found"})
    end
  end

  defp handle_proxy(conn) do
    with {:ok, token} <- fetch_token(conn),
         {:ok, url} <- Token.verify_image(token),
         true <- WebURL.http_url?(url) do
      case Loader.load(url) do
        {:ok, entry, source} ->
          conn
          |> put_resp_header("content-type", entry.content_type || "application/octet-stream")
          |> put_resp_header("cache-control", public_cache_control(entry))
          |> put_resp_header("x-content-type-options", "nosniff")
          |> put_resp_header("content-security-policy", image_csp(entry.content_type))
          |> put_resp_header("referrer-policy", "no-referrer")
          |> put_resp_header("x-pm-cache", Atom.to_string(source))
          |> send_resp(200, entry.body)

        {:error, reason} ->
          conn
          |> put_resp_header("content-type", "image/gif")
          |> put_resp_header("cache-control", "no-store")
          |> put_resp_header("x-pm-proxy-error", error_code(reason))
          |> send_resp(200, transparent_pixel())
      end
    else
      _ ->
        conn
        |> put_resp_header("content-type", "image/gif")
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(400, transparent_pixel())
    end
  end

  defp handle_redirect(conn) do
    with {:ok, token} <- fetch_token(conn),
         {:ok, url} <- Token.verify_redirect(token),
         true <- WebURL.http_url?(url) do
      destination =
        if Application.get_env(:privacy_mail, :strip_tracking_params, true) do
          WebURL.strip_tracking_params(url)
        else
          url
        end

      conn
      |> put_resp_header("location", destination)
      |> put_resp_header("referrer-policy", "no-referrer")
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(302, "")
    else
      _ -> send_resp(conn, 400, "invalid or expired link capability")
    end
  end

  defp fetch_token(conn) do
    conn = Plug.Conn.fetch_query_params(conn)

    case conn.params do
      %{"token" => token} when is_binary(token) and token != "" -> {:ok, token}
      _ -> :error
    end
  end

  defp json_body(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} -> {:error, :invalid_json}
      params when is_map(params) -> {:ok, params}
    end
  end

  defp opts_from_params(params) do
    []
    |> maybe_opt(params, "base_url", :base_url)
    |> maybe_bool(params, "proxy_images", :proxy_images)
    |> maybe_bool(params, "strip_tracking_params", :strip_tracking_params)
    |> maybe_int(params, "block_threshold", :block_threshold)
    |> maybe_rewrite_links(params)
  end

  defp maybe_opt(opts, params, key, opt) do
    if is_binary(params[key]), do: Keyword.put(opts, opt, params[key]), else: opts
  end

  defp maybe_bool(opts, params, key, opt) do
    if Map.has_key?(params, key) and is_boolean(params[key]) do
      Keyword.put(opts, opt, params[key])
    else
      opts
    end
  end

  defp maybe_int(opts, params, key, opt) do
    if is_integer(params[key]), do: Keyword.put(opts, opt, params[key]), else: opts
  end

  defp maybe_rewrite_links(opts, %{"rewrite_links" => value})
       when value in ["off", "sanitize", "redirect_all"] do
    Keyword.put(opts, :rewrite_links, String.to_existing_atom(value))
  end

  defp maybe_rewrite_links(opts, _), do: opts

  defp public_report(report) do
    %{
      counts: report.counts,
      trackers: public_findings(report.trackers),
      proxied_images: public_findings(report.proxied_images),
      personalized_links: public_findings(report.personalized_links),
      sanitized_links: public_findings(report.sanitized_links)
    }
  end

  defp public_findings(findings) do
    Enum.map(findings, fn f ->
      %{
        type: f.type,
        kind: f[:kind],
        action: f.action,
        score: f.score,
        confidence: f.confidence,
        url: f.url,
        reasons: f.reasons,
        location: f[:location],
        tag: f[:tag]
      }
    end)
  end

  defp send_json(conn, status, body) do
    body = Jason.encode!(body)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
  end

  defp public_cache_control(%{transient: true}), do: "no-store"

  defp public_cache_control(_entry) do
    "public, max-age=1800, stale-while-revalidate=3600"
  end

  defp image_csp("image/svg+xml"), do: "default-src 'none'; style-src 'unsafe-inline'; sandbox"
  defp image_csp(_), do: "default-src 'none'; sandbox"

  defp transparent_pixel do
    uri = Application.get_env(:privacy_mail, :transparent_pixel_uri)
    [_, base64] = String.split(uri, ",", parts: 2)
    Base.decode64!(base64)
  end

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code({reason, _}) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_), do: "fetch_failed"
end
