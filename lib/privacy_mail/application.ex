defmodule PrivacyMail.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    port = Application.get_env(:privacy_mail, :http_port, 4000)

    children =
      [
        {Finch,
         name: PrivacyMail.Finch,
         pools: %{
           default: [
             size: 32,
             count: max(2, System.schedulers_online()),
             protocols: [:http1, :http2]
           ]
         }},
        PrivacyMail.Proxy.Cache,
        PrivacyMail.Proxy.SingleFlight,
        {Task.Supervisor, name: PrivacyMail.TaskSupervisor}
      ] ++ http_child(port)

    opts = [strategy: :one_for_one, name: PrivacyMail.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp http_child(port) when is_integer(port) and port >= 0 do
    ip = Application.get_env(:privacy_mail, :http_ip, {127, 0, 0, 1})
    [{Bandit, plug: PrivacyMailWeb.Router, port: port, ip: ip}]
  end

  # `false` is useful for library/test usage with Plug.Test.
  defp http_child(false), do: []
  defp http_child(nil), do: []
end
