defmodule PrivacyMail.Proxy.Cache do
  @moduledoc """
  Local ETS image cache with TTL and stale-while-revalidate metadata.

  Reads are lock-free. Simultaneous misses for the same URL are coalesced by
  `PrivacyMail.Proxy.SingleFlight`; this module only stores their result.
  Multi-node deployments can put a CDN/Redis in front using the same signed
  URL and cache key semantics.
  """

  use GenServer

  @table __MODULE__.Table

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    table =
      :ets.new(@table, [
        :named_table,
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    state = %{
      table: table,
      max_entries: Keyword.get(opts, :max_entries, config(:cache_max_entries, 5_000)),
      max_bytes: Keyword.get(opts, :max_bytes, config(:cache_max_bytes, 256 * 1024 * 1024)),
      sweep_ms: Keyword.get(opts, :sweep_ms, :timer.minutes(2))
    }

    schedule_sweep(state.sweep_ms)
    {:ok, state}
  end

  @doc "Fresh entries return `{:hit, entry}`; expired entries return `{:stale, entry}`."
  def get(key) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, entry}] ->
        cond do
          entry.expires_at > now ->
            {:hit, entry}

          entry.stale_until > now ->
            {:stale, entry}

          true ->
            :ets.delete(@table, key)
            :miss
        end

      _ ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  def put_success(key, response, ttl_ms \\ nil) do
    now = System.monotonic_time(:millisecond)

    case ttl_ms || success_ttl(response.headers) do
      :no_store ->
        {:ok, transient_entry(key, response, now)}

      ttl ->
        ttl = ttl || config(:cache_default_ttl_ms, 1_800_000)

        entry = %{
          key: key,
          outcome: :ok,
          status: response.status,
          headers: sanitize_headers(response.headers),
          content_type: response.content_type,
          body: response.body,
          etag: get_header(response.headers, "etag"),
          expires_at: now + ttl,
          stale_until: now + ttl + :timer.hours(1),
          size: byte_size(response.body),
          cached_at: System.system_time(:second)
        }

        :ets.insert(@table, {key, entry})
        enforce_capacity!(@table)
        {:ok, entry}
    end
  rescue
    ArgumentError -> {:error, :cache_unavailable}
  end

  def put_failure(key, reason, ttl_ms \\ nil) do
    ttl = ttl_ms || config(:cache_negative_ttl_ms, 300_000)
    now = System.monotonic_time(:millisecond)

    entry = %{
      key: key,
      outcome: :error,
      reason: normalize_reason(reason),
      expires_at: now + ttl,
      stale_until: now,
      size: 0,
      cached_at: System.system_time(:second)
    }

    :ets.insert(@table, {key, entry})
    enforce_capacity!(@table)
    {:ok, entry}
  rescue
    ArgumentError -> {:error, :cache_unavailable}
  end

  def delete(key), do: :ets.delete(@table, key)

  def stats do
    info = :ets.info(@table)

    %{
      entries: Keyword.get(info, :size, 0),
      memory_words: Keyword.get(info, :memory, 0),
      memory_bytes: Keyword.get(info, :memory, 0) * :erlang.system_info(:wordsize)
    }
  rescue
    ArgumentError -> %{entries: 0, memory_words: 0, memory_bytes: 0}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep(state)
    schedule_sweep(state.sweep_ms)
    {:noreply, state}
  end

  defp sweep(state) do
    now = System.monotonic_time(:millisecond)

    expired =
      :ets.foldl(
        fn {key, entry}, acc ->
          if entry.stale_until <= now, do: [key | acc], else: acc
        end,
        [],
        state.table
      )

    Enum.each(expired, &:ets.delete(state.table, &1))

    size = :ets.info(state.table, :size)

    if is_integer(size) and size > state.max_entries do
      evict_oldest(state.table, size - state.max_entries)
    end

    if cache_bytes(state.table) > state.max_bytes do
      evict_until_bytes(state.table, state.max_bytes)
    end
  rescue
    ArgumentError -> :ok
  end

  defp evict_oldest(table, count) when count > 0 do
    oldest =
      :ets.foldl(
        fn {key, entry}, acc ->
          [{entry.expires_at, key} | acc]
        end,
        [],
        table
      )
      |> Enum.sort()
      |> Enum.take(count)

    Enum.each(oldest, fn {_time, key} -> :ets.delete(table, key) end)
  end

  defp enforce_capacity!(table) do
    max_entries = config(:cache_max_entries, 5_000)
    max_bytes = config(:cache_max_bytes, 256 * 1024 * 1024)
    entries = :ets.info(table, :size)

    if is_integer(entries) and entries > max_entries do
      evict_oldest(table, entries - max_entries)
    end

    if cache_bytes(table) > max_bytes do
      evict_until_bytes(table, max_bytes)
    end
  rescue
    ArgumentError -> :ok
  end

  defp cache_bytes(table) do
    case :ets.info(table, :memory) do
      words when is_integer(words) -> words * :erlang.system_info(:wordsize)
      _ -> 0
    end
  end

  defp evict_until_bytes(table, max_bytes) do
    # ETS memory includes table overhead, so target 90% of the configured body
    # budget. Sorting is acceptable because this only runs after an over-budget
    # insert, not on the read path.
    target = trunc(max_bytes * 0.9)

    oldest =
      :ets.foldl(
        fn {key, entry}, acc -> [{entry.expires_at, key, entry.size} | acc] end,
        [],
        table
      )
      |> Enum.sort()

    Enum.reduce_while(oldest, cache_bytes(table), fn {_time, key, _size}, _bytes ->
      :ets.delete(table, key)
      bytes = cache_bytes(table)

      if bytes <= target do
        {:halt, bytes}
      else
        {:cont, bytes}
      end
    end)
  end

  defp schedule_sweep(ms), do: Process.send_after(self(), :sweep, ms)

  defp success_ttl(headers) do
    cc = get_header(headers, "cache-control") || ""
    ttl = Regex.run(~r/max-age=(\d+)/i, cc)

    cond do
      String.contains?(cc, "no-store") -> :no_store
      String.contains?(cc, "private") -> nil
      match?([_, _], ttl) -> ttl |> Enum.at(1) |> String.to_integer() |> :timer.seconds()
      true -> nil
    end
  end

  defp transient_entry(key, response, now) do
    %{
      key: key,
      outcome: :ok,
      status: response.status,
      headers: sanitize_headers(response.headers),
      content_type: response.content_type,
      body: response.body,
      etag: get_header(response.headers, "etag"),
      expires_at: now,
      stale_until: now,
      size: byte_size(response.body),
      cached_at: System.system_time(:second),
      transient: true
    }
  end

  defp sanitize_headers(headers) do
    headers
    |> Enum.filter(fn {k, _v} ->
      String.downcase(k) in ~w(content-type cache-control etag last-modified expires)
    end)
    |> Enum.map(fn {k, v} -> {String.downcase(k), v} end)
  end

  defp get_header(headers, name) do
    name = String.downcase(name)

    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(k) == name, do: v
    end)
  end

  defp normalize_reason(reason) when is_atom(reason), do: reason
  defp normalize_reason({reason, _}), do: normalize_reason(reason)
  defp normalize_reason(reason) when is_binary(reason), do: :upstream_error
  defp normalize_reason(_), do: :upstream_error

  defp config(key, default), do: Application.get_env(:privacy_mail, key, default)
end
