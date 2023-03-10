defmodule XMAVLink.Mixfile do
  use Mix.Project

  def project do
    [
      app: :xmavlink,
      version: "0.4.0",
      elixir: "~> 1.9",
      start_permanent: Mix.env() == :prod,
      description: description(),
      package: package(),
      aliases: aliases(),
      deps: deps(),
      dialyzer: [plt_add_apps: [:mix, :xmerl]],
      source_url: "https://github.com/fancydrones/xmavlink",
      consolidate_protocols: Mix.env() != :test
    ]
  end

  # See https://virviil.github.io/2016/10/26/elixir-testing-without-starting-supervision-tree/
  defp aliases do
    [
      test: "test --no-start"
    ]
  end

  @doc """
  Override environment variables in config.exs e.g:

  config :xmavlink, dialect: Common
  config :xmavlink, system_id: 1
  config :xmavlink, component_id: 1
  config :xmavlink, connections: ["udp:192.168.0.10:14550"]
  """
  def application do
    [
      env: [
        # Dialect module generated using mix xmavlink
        dialect: nil,
        # Default to ground station-ish system id
        system_id: 245,
        # Default to system control
        component_id: 250,
        connections: []
      ],
      mod: {XMAVLink.Application, []},
      extra_applications: [:logger, :xmerl]
    ]
  end

  defp deps do
    [
      {:circuits_uart, "~> 1.5.1"},
      {:poolboy, "~> 1.5"},
      {:dialyzex, "~> 1.3.0", only: :dev, runtime: false},
      {:ex_doc, "~> 0.29.1", only: :dev, runtime: false}
    ]
  end

  defp description() do
    "A Mix task to generate code from a MAVLink xml definition file,
    and an application that enables communication with other systems
    using the MAVLink 1.0 or 2.0 protocol over serial, UDP and TCP
    connections."
  end

  defp package() do
    [
      name: "xmavlink",
      files: ["lib", "mix.exs", "README.md", "LICENSE"],
      exclude_patterns: [".DS_Store"],
      licenses: ["MIT"],
      links: %{"Github" => "https://github.com/fancydrones/xmavlink"},
      maintainers: ["Roy Veshovda"]
    ]
  end
end
