defmodule PrivacyMail.Proxy.Loader do
  @moduledoc """
  Cache + single-flight orchestration for image requests.

  This is the concurrency boundary: web processes call `load/2`, while at
  most one upstream fetch runs per canonical URL on this node. Fresh cache
  reads do not enter the single-flight GenServer and therefore scale across
  all scheduler cores.
  """

  alias PrivacyMail.Proxy.Cache
  alias PrivacyMail.Proxy.SingleFlight
  alias PrivacyMail.WebURL

  def load(url, opts \\ []) when is_binary(url) do
    strip? = Keyword.get(opts, :strip_tracking_params, config(:strip_tracking_params, true))
    fetch_url = if strip?, do: WebURL.strip_tracking_params(url), else: url
    cache_key = WebURL.canonical(fetch_url, strip_tracking_params: false)

    if Keyword.get(opts, :cache, true) do
      load_cached(cache_key, fetch_url, opts)
    else
      fetch_once(cache_key, fetch_url, opts)
    end
  end

  defp load_cached(key, url, opts) do
    case Cache.get(key) do
      {:hit, entry} ->
        emit(:hit, key)
        return_entry(entry, :hit)

      {:stale, entry} ->
        emit(:stale, key)
        schedule_refresh(key, url, opts)
        return_entry(entry, :stale)

      :miss ->
        emit(:miss, key)

        case SingleFlight.run(
               key,
               fn -> fetch_and_store(key, url, opts) end,
               fetch_timeout(opts) + 2_000
             ) do
          {:ok, entry} -> {:ok, entry, :miss}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp fetch_once(key, url, opts) do
    case fetch_and_store(key, url, opts) do
      {:ok, entry} -> {:ok, entry, :uncached}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_and_store(key, url, opts) do
    fetcher = Keyword.get(opts, :fetcher, fetcher_module())

    case fetcher.fetch(url, opts) do
      {:ok, response} ->
        case Cache.put_success(key, response) do
          {:ok, entry} -> {:ok, entry}
          _ -> {:ok, response_to_entry(response)}
        end

      {:error, reason} = error ->
        Cache.put_failure(key, reason)
        error
    end
  end

  defp schedule_refresh(key, url, opts) do
    supervisor = Keyword.get(opts, :task_supervisor, PrivacyMail.TaskSupervisor)

    result =
      Task.Supervisor.start_child(supervisor, fn ->
        SingleFlight.run(
          key,
          fn -> fetch_and_store(key, url, opts) end,
          fetch_timeout(opts) + 2_000
        )
      end)

    case result do
      {:ok, _pid} -> :ok
      {:error, _} -> Task.start(fn -> fetch_and_store(key, url, opts) end)
    end
  end

  defp return_entry(%{outcome: :ok} = entry, source), do: {:ok, entry, source}
  defp return_entry(%{outcome: :error, reason: reason}, _source), do: {:error, reason}

  defp response_to_entry(response) do
    %{
      outcome: :ok,
      status: response.status,
      headers: response.headers,
      content_type: response.content_type,
      body: response.body
    }
  end

  defp fetch_timeout(opts), do: Keyword.get(opts, :timeout, config(:fetch_timeout_ms, 10_000))

  defp fetcher_module, do: Application.get_env(:privacy_mail, :fetcher, PrivacyMail.Proxy.Fetcher)

  defp emit(kind, key) do
    :telemetry.execute([:privacy_mail, :proxy, :cache], %{count: 1}, %{kind: kind, key: key})
  rescue
    _ -> :ok
  end

  defp config(key, default), do: Application.get_env(:privacy_mail, key, default)
end
