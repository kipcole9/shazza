defmodule Shazza.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/kipcole9/shazza"

  def project do
    [
      app: :shazza,
      version: @version,
      elixir: "~> 1.20.0-rc.4 or ~> 1.20",
      name: "Shazza",
      description: description(),
      source_url: @source_url,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: docs(),
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_targets: ["all"],
      make_clean: ["clean"],
      dialyzer: [
        plt_add_apps: ~w(mix)a
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Shazza.Application, []}
    ]
  end

  defp description do
    """
    Audio fingerprinting and recognition for Elixir — a Wang/Shazam-style
    pipeline built on Nx, NxSignal, Xav, and SQLite, with mix tasks for
    bulk ingest, file identification, and live mic capture.
    """
  end

  defp package do
    [
      maintainers: ["Kip Cole"],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/v#{@version}/CHANGELOG.md"
      },
      files: [
        "lib",
        "c_src",
        "Makefile",
        "mix.exs",
        "README*",
        "CHANGELOG*",
        "LICENSE*"
      ]
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      logo: "logo.png",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "LICENSE.md",
        "notebooks/how_it_works.livemd"
      ],
      groups_for_extras: [
        Guides: ~r/notebooks\/.+/
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:nx, "~> 0.10"},
      {:exla, "~> 0.10"},
      {:nx_signal, "~> 0.2"},
      {:xav, "~> 0.11"},
      {:exqlite, "~> 0.30"},
      {:elixir_make, "~> 0.9", runtime: false},
      {:ex_doc, "~> 0.34", only: [:dev, :release], optional: true, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
    ]
  end
end
