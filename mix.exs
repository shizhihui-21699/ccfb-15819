defmodule PrivacyMail.MixProject do
  use Mix.Project

  def project do
    [
      app: :privacy_mail,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_coverage: [summary: [threshold: 70]]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {PrivacyMail.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:bandit, "~> 1.8"},
      {:finch, "~> 0.20"},
      {:floki, "~> 0.38"},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.18"},
      {:mox, "~> 1.2", only: :test}
    ]
  end
end
