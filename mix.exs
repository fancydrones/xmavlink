defmodule XMAVLink.Mixfile do
  use Mix.Project

  def project do
    [
      app: :xmavlink,
      version: "0.14.2",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      description: description(),
      package: package(),
      docs: docs(),
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
  config :xmavlink, connections: ["udpout:192.168.0.10:14550"]
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
        # Default registered router name
        router_name: XMAVLink.Router,
        # Utility processes are opt-in because CacheManager actively subscribes
        # to MAVLink traffic and requests vehicle parameter lists.
        utilities: false,
        # Keep router behavior by default. Set false for endpoint/GCS use cases
        # that should receive remote traffic without bridging remote links.
        remote_forwarding: true,
        connections: []
      ],
      mod: {XMAVLink.Application, []},
      extra_applications: [:logger, :xmerl]
    ]
  end

  defp deps do
    [
      {:circuits_uart, "~> 1.5"},
      {:poolboy, "~> 1.5"},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp description() do
    "An elixir library for MAVLink,
    an application that enables communication with other systems
    using the MAVLink protocol over serial, UDP and TCP
    connections, and utility modules for performing common MAVLink
    commands and tasks with one or more remote vehicles."
  end

  defp package() do
    [
      name: "xmavlink",
      files: [
        "lib",
        "priv",
        "mix.exs",
        "README.md",
        "CHANGELOG.md",
        "MIGRATING_0_14.md",
        "LICENSE",
        "SECURITY.md",
        "MAVLINK_SPEC_ALIGNMENT.md"
      ],
      exclude_patterns: [".DS_Store"],
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/fancydrones/xmavlink"},
      maintainers: ["Roy Veshovda"]
    ]
  end

  defp docs() do
    [
      main: "readme",
      extras: [
        "README.md",
        "MIGRATING_0_14.md",
        "CHANGELOG.md",
        "SECURITY.md",
        "MAVLINK_SPEC_ALIGNMENT.md"
      ],
      groups_for_extras: [
        Guides: [
          "MIGRATING_0_14.md",
          "SECURITY.md",
          "MAVLINK_SPEC_ALIGNMENT.md"
        ],
        Release: [
          "CHANGELOG.md"
        ]
      ],
      groups_for_modules: [
        "Core Runtime": [
          XMAVLink.Router,
          XMAVLink.Frame,
          XMAVLink.Frame.Signature,
          XMAVLink.Message,
          XMAVLink.Signing,
          XMAVLink.Heartbeat
        ],
        Utilities: ~r/^XMAVLink\.Util\./,
        "Dialect And Generator Support": [
          XMAVLink.Dialect,
          XMAVLink.Parser,
          XMAVLink.Types,
          XMAVLink.Utils,
          Mix.Tasks.Xmavlink
        ],
        "Generated Common Dialect": [
          Common,
          ~r/^Common\./,
          ~r/^XMAVLink\.Message\.Common\./
        ]
      ]
    ]
  end
end
