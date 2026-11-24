defmodule PrivacyMail.Email do
  @moduledoc """
  Scans and rewrites HTML email to neutralize passive tracking.

  The policy is signal-based rather than "all remote images are trackers":
  invisible/hidden/known-beacon images are replaced with a local transparent
  pixel and never fetched; ordinary marketing and notification images are
  rewritten to signed proxy URLs and fetched only when the recipient renders
  them.
  """

  alias PrivacyMail.HTMLSignals
  alias PrivacyMail.Proxy.Token
  alias PrivacyMail.Srcset
  alias PrivacyMail.Tracking.Classifier
  alias PrivacyMail.WebCSS
  alias PrivacyMail.WebURL

  @lazy_url_attrs ~w[data-src data-original data-lazy-src data-echo data-defer-src data-lazy data-url]
  @url_attrs ~w[src srcset poster background href xlink:href] ++ @lazy_url_attrs
  @image_url_attrs ~w[src srcset poster background href xlink:href] ++ @lazy_url_attrs
  @image_tags ~w[img source image input]

  @type option :: atom() | {atom(), term()}

  @doc "Analyzes an HTML email without changing it."
  def analyze(html, opts \\ []) when is_binary(html) do
    case process(html, Keyword.put(opts, :rewrite, false)) do
      {:ok, report} -> report
      {:error, reason} -> build_report([], nil, opts) |> Map.put(:error, inspect(reason))
    end
  end

  @doc "Rewrites HTML and returns `{:ok, safe_html, report}`."
  def privatize(html, opts \\ []) when is_binary(html) do
    with {:ok, report} <- process(html, Keyword.put(opts, :rewrite, true)) do
      {:ok, report.html, report}
    end
  end

  @doc "Bang variant of `privatize/2`."
  def privatize!(html, opts \\ []) do
    {:ok, safe, _report} = privatize(html, opts)
    safe
  end

  defp process(html, opts) do
    with {:ok, tree} <- Floki.parse_fragment(html) do
      acc = %{findings: [], rewrite?: Keyword.get(opts, :rewrite, true), opts: opts}
      {tree, acc} = Floki.traverse_and_update(tree, acc, &traverse_node/2)
      output = if acc.rewrite?, do: Floki.raw_html(tree), else: nil
      {:ok, build_report(acc.findings, output, opts)}
    end
  end

  defp traverse_node({tag, attrs, children}, acc) when is_binary(tag) do
    tag = String.downcase(tag)

    cond do
      Keyword.get(acc.opts, :strip_scripts, true) and tag in ~w[script iframe object embed] ->
        {nil, add_finding(acc, %{type: :removed_active_content, tag: tag, action: :remove})}

      true ->
        {attrs, acc} = process_attrs(tag, attrs, acc)
        {children, acc} = process_style_children(tag, attrs, children, acc)
        node = {tag, attrs, children}
        {node, acc}
    end
  end

  defp traverse_node(other, acc), do: {other, acc}

  defp process_attrs(tag, attrs, acc) do
    {attrs, acc} = harden_attrs(attrs, acc)

    {attrs, acc} =
      Enum.reduce(@url_attrs, {attrs, acc}, fn name, {attrs, acc} ->
        case List.keyfind(attrs, name, 0) do
          {^name, value} when is_binary(value) and value != "" ->
            process_url_attr(tag, name, value, attrs, acc)

          _ ->
            {attrs, acc}
        end
      end)

    process_inline_style(tag, attrs, acc)
  end

  defp harden_attrs(attrs, acc) do
    if Keyword.get(acc.opts, :strip_scripts, true) do
      Enum.reduce(attrs, {[], acc}, fn {name, value}, {kept, acc} ->
        lower = String.downcase(name)

        cond do
          String.starts_with?(lower, "on") ->
            {kept, add_finding(acc, %{type: :removed_event_handler, attr: name, action: :remove})}

          lower in @url_attrs and dangerous_url?(value) ->
            finding = %{type: :neutralized_dangerous_url, attr: name, action: :neutralize}
            {[{name, "#"} | kept], add_finding(acc, finding)}

          true ->
            {[{name, value} | kept], acc}
        end
      end)
      |> then(fn {attrs, acc} -> {Enum.reverse(attrs), acc} end)
    else
      {attrs, acc}
    end
  end

  defp dangerous_url?(value) when is_binary(value) do
    Regex.match?(~r/^\s*(?:javascript|vbscript|data:text\/html):/i, value)
  end

  defp dangerous_url?(_), do: false

  defp process_url_attr(tag, name, value, attrs, acc) do
    cond do
      tag == "a" and name == "href" ->
        process_link(value, attrs, acc, name)

      tag in @image_tags or name in @image_url_attrs ->
        process_image_attr(tag, name, value, attrs, acc)

      true ->
        {attrs, acc}
    end
  end

  defp process_image_attr(tag, name, value, attrs, acc) do
    cond do
      name == "srcset" ->
        {new_value, acc} =
          Srcset.map_reduce(value, acc, fn url, acc ->
            transform_image_url(url, attrs, tag, :srcset, acc)
          end)

        {put_attr(attrs, "srcset", new_value), acc}

      name in @image_url_attrs and image_context?(tag, name) ->
        {new_value, acc} = transform_image_url(value, attrs, tag, String.to_atom(name), acc)
        attrs = put_attr(attrs, name, new_value)
        attrs = maybe_add_image_hints(tag, name, attrs, new_value, acc)
        {attrs, acc}

      true ->
        {attrs, acc}
    end
  end

  defp image_context?(_tag, name) do
    name in @image_url_attrs
  end

  defp maybe_add_image_hints("img", "src", attrs, new_value, acc) do
    if acc.rewrite? and String.contains?(new_value, proxy_marker(acc.opts)) do
      attrs
      |> put_if_absent("loading", "lazy")
      |> put_if_absent("decoding", "async")
      |> put_if_absent("referrerpolicy", "no-referrer")
    else
      attrs
    end
  end

  defp maybe_add_image_hints(_tag, _name, attrs, _new_value, _acc), do: attrs

  defp process_inline_style(tag, attrs, acc) do
    case List.keyfind(attrs, "style", 0) do
      {"style", style} when is_binary(style) ->
        urls = WebCSS.extract_urls(style)

        {replacements, acc} =
          Enum.reduce(urls, {%{}, acc}, fn url, {map, acc} ->
            {new_url, acc} = transform_image_url(url, attrs, tag, :inline_style, acc)
            {Map.put(map, url, new_url), acc}
          end)

        new_style = WebCSS.rewrite_urls(style, &Map.fetch!(replacements, &1))
        {put_attr(attrs, "style", new_style), acc}

      _ ->
        {attrs, acc}
    end
  end

  defp process_style_children("style", attrs, children, acc) do
    Enum.reduce(children, {[], acc}, fn
      text, {out, acc} when is_binary(text) ->
        urls = WebCSS.extract_urls(text)

        {replacements, acc} =
          Enum.reduce(urls, {%{}, acc}, fn url, {map, acc} ->
            {new_url, acc} = transform_image_url(url, attrs, "style", :style_tag, acc)
            {Map.put(map, url, new_url), acc}
          end)

        text = WebCSS.rewrite_urls(text, &Map.fetch!(replacements, &1))
        {[text | out], acc}

      node, {out, acc} ->
        {[node | out], acc}
    end)
    |> then(fn {children, acc} -> {Enum.reverse(children), acc} end)
  end

  defp process_style_children(_tag, _attrs, children, acc), do: {children, acc}

  defp transform_image_url(raw_url, html_attrs, tag, location, acc) do
    url = WebURL.absolute(String.trim(raw_url), Keyword.get(acc.opts, :base_url))

    if remote_url?(url) do
      finding =
        url
        |> Classifier.classify_image(html_attrs, acc.opts)
        |> Map.merge(%{type: :image, tag: tag, location: location})

      acc = add_finding(acc, finding)

      replacement =
        cond do
          not acc.rewrite? ->
            raw_url

          finding.action == :block ->
            pixel(acc.opts)

          Keyword.get(acc.opts, :proxy_images, true) ->
            proxied_url(url, acc.opts)

          true ->
            url
        end

      {replacement, acc}
    else
      {raw_url, acc}
    end
  end

  defp process_link(raw_href, attrs, acc, attr_name) do
    url = WebURL.absolute(String.trim(raw_href), Keyword.get(acc.opts, :base_url))

    if remote_url?(url) do
      finding =
        url
        |> Classifier.classify_link(attrs, acc.opts)
        |> Map.merge(%{type: :link, tag: "a", location: :href})

      acc = add_finding(acc, finding)

      if acc.rewrite? do
        policy = Keyword.get(acc.opts, :rewrite_links, config(:rewrite_links, :sanitize))
        action = link_action(policy, finding)
        new_href = rewrite_link_href(action, url, acc.opts)

        attrs =
          attrs
          |> put_attr(attr_name, new_href)
          |> merge_rel("noopener noreferrer")
          |> put_if_absent("referrerpolicy", "no-referrer")
          |> put_attr("data-pm-link", Atom.to_string(action))

        {attrs, acc}
      else
        {attrs, acc}
      end
    else
      {attrs, acc}
    end
  end

  defp link_action(:off, _finding), do: :allow
  defp link_action(:redirect_all, _finding), do: :redirect
  defp link_action(:sanitize, finding), do: finding.action
  defp link_action(true, finding), do: finding.action
  defp link_action(false, _finding), do: :allow

  defp rewrite_link_href(:redirect, url, opts) do
    url = maybe_strip(url, opts)
    Token.absolute_redirect_url(url, token_opts(opts))
  end

  defp rewrite_link_href(:sanitize, url, opts), do: maybe_strip(url, opts)
  defp rewrite_link_href(_allow, url, _opts), do: url

  defp maybe_strip(url, opts) do
    if Keyword.get(opts, :strip_tracking_params, config(:strip_tracking_params, true)) do
      extra = Keyword.get(opts, :extra_tracking_params, [])
      WebURL.strip_tracking_params(url, extra)
    else
      url
    end
  end

  defp proxied_url(url, opts) do
    url = maybe_strip(url, opts)
    Token.absolute_proxy_url(url, token_opts(opts))
  end

  defp token_opts(opts) do
    # NB: `:base_url` is the email content base used for resolving relative
    # links and must not be reused as the public proxy origin.
    opts
    |> Keyword.take([:secret, :proxy_base_url])
    |> Keyword.put(:proxy_route_path, config(:proxy_route_path, "/proxy/image"))
    |> Keyword.put(:redirect_route_path, config(:redirect_route_path, "/redirect"))
    |> then(fn kw ->
      case Keyword.pop(kw, :proxy_base_url) do
        {nil, rest} -> rest
        {proxy_base, rest} -> Keyword.put(rest, :base_url, proxy_base)
      end
    end)
  end

  defp proxy_marker(opts) do
    Keyword.get(opts, :proxy_route_path, config(:proxy_route_path, "/proxy/image"))
  end

  defp remote_url?(url) when is_binary(url) do
    String.starts_with?(url, "//") or WebURL.http_url?(url)
  end

  defp remote_url?(_), do: false

  defp pixel(opts), do: Keyword.get(opts, :transparent_pixel_uri, config(:transparent_pixel_uri))

  defp add_finding(acc, finding) do
    %{acc | findings: [finding | acc.findings]}
  end

  defp put_attr(attrs, name, value) do
    if List.keyfind(attrs, name, 0) do
      Enum.map(attrs, fn
        {^name, _old} -> {name, value}
        other -> other
      end)
    else
      [{name, value} | attrs]
    end
  end

  defp put_if_absent(attrs, name, value) do
    if HTMLSignals.attr(attrs, name), do: attrs, else: put_attr(attrs, name, value)
  end

  defp merge_rel(attrs, values) do
    existing = HTMLSignals.attr(attrs, "rel") || ""

    merged =
      existing
      |> String.split(~r/\s+/, trim: true)
      |> Kernel.++(String.split(values))
      |> Enum.uniq()
      |> Enum.join(" ")

    put_attr(attrs, "rel", merged)
  end

  defp build_report(findings_reversed, html, opts) do
    findings = Enum.reverse(findings_reversed)
    images = Enum.filter(findings, &(&1.type == :image))
    links = Enum.filter(findings, &(&1.type == :link))
    active = Enum.filter(findings, &(&1.type == :removed_active_content))

    trackers = Enum.filter(images, &(&1.action == :block))
    proxied = Enum.filter(images, &(&1.action == :proxy))
    personalized_links = Enum.filter(links, &match?(%{identifiers: [_ | _]}, &1))
    redirected_links = Enum.filter(links, &(&1.action == :redirect))
    sanitized_links = Enum.filter(links, &(&1.action == :sanitize))

    %{
      html: html,
      findings: findings,
      images: images,
      links: links,
      trackers: trackers,
      proxied_images: proxied,
      personalized_links: personalized_links,
      redirected_links: redirected_links,
      sanitized_links: sanitized_links,
      removed_active_content: active,
      counts: %{
        images: length(images),
        trackers_blocked: length(trackers),
        images_proxied: length(proxied),
        links: length(links),
        personalized_links: length(personalized_links),
        links_redirected: length(redirected_links),
        links_sanitized: length(sanitized_links),
        active_content_removed: length(active)
      },
      opts: Keyword.drop(opts, [:secret])
    }
  end

  defp config(key), do: Application.get_env(:privacy_mail, key)
  defp config(key, default), do: Application.get_env(:privacy_mail, key, default)
end
