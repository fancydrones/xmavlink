defmodule XMAVLink.DownstreamSmoke.MixProject do
  use Mix.Project

  def project do
    [
      app: :xmavlink_downstream_smoke,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: deps(),
      consolidate_protocols: false
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:xmavlink, path: "../..", runtime: false}
    ]
  end
end
