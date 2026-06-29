defmodule AshK8s.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/ash-project/ash_k8s"

  def project do
    [
      app: :ash_k8s,
      version: @version,
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      docs: docs(),
      package: package(),
      aliases: aliases(),
      description: "Kubernetes operator and CRD framework built on Ash"
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ash, "~> 3.0"},
      {:spark, "~> 2.0"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.9"},
      {:ymlr, "~> 5.0"},
      {:x509, "~> 0.8"},

      # Dev/test
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mox, "~> 1.1", only: :test}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md"],
      groups_for_modules: [
        "DSL Extensions": [AshK8s.Resource, AshK8s.Operator],
        "Controller": [AshK8s.Controller, AshK8s.Controller.Behaviour, AshK8s.Controller.Server],
        "Data Layer": [AshK8s.DataLayer],
        "Kubernetes Client": [AshK8s.Client, AshK8s.Client.Config, AshK8s.Client.Watch],
        "CRD Generation": [AshK8s.CRD],
        "Introspection": [AshK8s.Resource.Info, AshK8s.Operator.Info]
      ]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp aliases do
    [
      "test.setup": ["deps.get", "compile"],
      lint: ["credo --strict", "dialyzer"]
    ]
  end
end
