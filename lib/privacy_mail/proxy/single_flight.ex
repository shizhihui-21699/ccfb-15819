defmodule PrivacyMail.Proxy.SingleFlight do
  @moduledoc """
  Coalesces concurrent misses for one cache key into a single upstream fetch.

  If many recipients open the same marketing campaign at once, only the first
  request fetches the image; concurrent requests share that result.
  """

  use GenServer

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{}, name: name)
  end

  @doc """
  Runs `fun` once for `key` while concurrent callers receive the same result.

  `fun` runs as a task spawned by the leader caller, so slow upstreams never
  block the coordination GenServer. A leader crash releases all waiters.
  """
  def run(key, fun, timeout \\ 20_000, server \\ __MODULE__) when is_function(fun, 0) do
    case GenServer.call(server, {:join, key}, 5_000) do
      :leader ->
        execute_leader(key, fun, timeout, server)

      {:wait, ref} ->
        receive do
          {^ref, result} -> result
        after
          timeout -> {:error, :timeout}
        end
    end
  end

  defp execute_leader(key, fun, timeout, server) do
    task = Task.async(fun)

    result =
      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        nil -> {:error, :timeout}
      end

    safe_complete(server, key, result)
    result
  catch
    kind, reason ->
      result = {:error, normalize_failure(kind, reason)}
      safe_complete(server, key, result)
      result
  end

  defp safe_complete(server, key, result) do
    GenServer.call(server, {:complete, key, result}, 5_000)
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:join, key}, from, state) do
    waiter_pid = elem(from, 0)

    case Map.fetch(state, key) do
      :error ->
        ref = Process.monitor(waiter_pid)
        {:reply, :leader, Map.put(state, key, %{waiters: [], monitor: ref})}

      {:ok, flight} ->
        ref = make_ref()
        flight = Map.update!(flight, :waiters, &[{waiter_pid, ref} | &1])
        {:reply, {:wait, ref}, put_in(state[key], flight)}
    end
  end

  @impl true
  def handle_call({:complete, key, result}, _from, state) do
    case Map.pop(state, key) do
      {nil, state} ->
        {:reply, :ok, state}

      {flight, state} ->
        Process.demonitor(flight.monitor, [:flush])

        Enum.each(flight.waiters, fn {pid, ref} ->
          send(pid, {ref, result})
        end)

        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Enum.find(state, fn {_key, flight} -> flight.monitor == ref end) do
      {key, flight} ->
        Enum.each(flight.waiters, fn {waiter_pid, waiter_ref} ->
          send(waiter_pid, {waiter_ref, {:error, :fetch_failed}})
        end)

        {:noreply, Map.delete(state, key)}

      nil ->
        # A waiting process exited. Prune it from waiter lists lazily on the
        # next completion; no per-waiter monitor is needed for correctness.
        state = prune_waiter(state, pid)
        {:noreply, state}
    end
  end

  defp prune_waiter(state, pid) do
    Map.new(state, fn {key, flight} ->
      waiters = Enum.reject(flight.waiters, fn {waiter_pid, _ref} -> waiter_pid == pid end)
      {key, %{flight | waiters: waiters}}
    end)
  end

  defp normalize_failure(:error, reason), do: reason
  defp normalize_failure(:throw, reason), do: {:throw, reason}
  defp normalize_failure(:exit, reason), do: {:exit, reason}
end
