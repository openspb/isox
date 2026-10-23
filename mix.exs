defmodule Isox.MixProject do
  use Mix.Project

  @source_url "https://github.com/openspb/isox"
  @version "0.3.0"

  def project do
    [
      app: :isox,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      description: description(),
      package: package(),
      name: "Isox",
      source_url: @source_url,
      docs: docs(),
      dialyzer: [plt_add_apps: [:mix]]
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test, credo: :test, dialyzer: :test]]
  end

  def application do
    [
      extra_applications: [:logger, :xmerl, :crypto, :public_key]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp description do
    "Codec ISO 20022 do catálogo de mensagens do SPI (Pix): encode e decode " <>
      "genéricos por envelope, dicionário de campos com o nome de cada um no " <>
      "catálogo do BCB, e assinatura XMLDSig no perfil do Manual de Segurança " <>
      "do SFN."
  end

  defp package do
    [
      files: ~w(lib mix.exs .formatter.exs README.md CHANGELOG.md LICENSE),
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md", "LICENSE"],
      source_url: @source_url,
      source_ref: "v#{@version}",
      groups_for_modules: [
        Modelos: [
          Isox.AppHdr,
          Isox.Envelope
        ],
        "Dicionário de campos": [
          Isox.Dictionary,
          Isox.Dictionary.Entry
        ],
        "Mensagens (API de baixo nível)": [
          Isox.Registry,
          Isox.Admi002,
          Isox.Admi004,
          Isox.Camt014,
          Isox.Camt025,
          Isox.Camt029,
          Isox.Camt052,
          Isox.Camt053,
          Isox.Camt054,
          Isox.Camt055,
          Isox.Camt060,
          Isox.Pacs002,
          Isox.Pacs004,
          Isox.Pacs008,
          Isox.Pain009,
          Isox.Pain011,
          Isox.Pain012,
          Isox.Pain013,
          Isox.Pain014,
          Isox.Pibr001,
          Isox.Pibr002,
          Isox.Reda014,
          Isox.Reda016,
          Isox.Reda017,
          Isox.Reda022,
          Isox.Reda031,
          Isox.Reda041,
          Isox.Trck002
        ],
        "Assinatura digital (avançado)": [
          Isox.Xmldsig.Signer,
          Isox.Xmldsig.Verifier,
          Isox.Xmldsig.TestCA
        ]
      ]
    ]
  end

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "credo --strict",
        "test"
      ]
    ]
  end
end
