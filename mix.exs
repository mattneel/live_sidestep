defmodule LiveSidestep.MixProject do
  use Mix.Project

  def project do
    [
      app: :live_sidestep,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      compilers: [:live_sidestep] ++ Mix.compilers(),
      deps: deps(),
      description:
        "Native desktop views for Elixir: LiveView-style callbacks rendering Sidestep/AppKit through Rustler.",
      source_url: "https://github.com/mattneel/live_sidestep",
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/mattneel/live_sidestep"},
        files:
          ~w(lib native docs/images mix.exs mix.lock Cargo.toml Cargo.lock README.md LICENSE CHANGELOG.md)
      ],
      docs: [
        main: "readme",
        extras: ["README.md", "CHANGELOG.md", "LICENSE"],
        assets: %{"docs/images" => "docs/images"}
      ],
      dialyzer: [plt_add_apps: [:ex_unit]],
      aliases: aliases()
    ]
  end

  def application do
    [
      mod: {LiveSidestep.Application, []},
      extra_applications: [:logger, :crypto]
    ]
  end

  def cli do
    [
      preferred_envs: [ci: :test]
    ]
  end

  defp deps do
    [
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.0", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.0", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.0", only: [:dev, :test], runtime: false},
      {:usage_rules, "~> 1.0", only: [:dev]},
      {:phoenix_live_view, "~> 1.0"},
      {:rustler, "~> 0.38"},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:vibe_kit, "~> 0.1", only: [:dev, :test], runtime: false},
      {:igniter, "~> 0.6", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases() do
    [
      ci: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "cmd cargo fmt -p live_sidestep_protocol -p live_sidestep_native -p live_sidestep_host -- --check",
        "cmd cargo clippy --workspace --all-targets --target-dir _build/native -- -D warnings",
        "cmd cargo test --workspace --locked --target-dir _build/native",
        "test",
        "credo --strict",
        "dialyzer",
        "ex_dna --max-clones 0",
        "reach.check --arch --smells"
      ]
    ]
  end
end

defmodule Mix.Tasks.Compile.LiveSidestep do
  @moduledoc false
  use Mix.Task.Compiler

  @impl true
  def run(_arguments) do
    unless :os.type() in [{:unix, :linux}, {:unix, :darwin}] do
      Mix.raise("live_sidestep supports Linux/Wayland and macOS/AppKit source builds only")
    end

    cargo =
      System.find_executable("cargo") || Mix.raise("live_sidestep requires Rust 1.95+ (cargo)")

    root = __DIR__
    overlay = Path.join(root, "_build/objc2-overlay")

    run!(
      cargo,
      [
        "run",
        "--release",
        "--locked",
        "--manifest-path",
        Path.join(root, "native/objc2-overlay/Cargo.toml"),
        "--target-dir",
        Path.join(root, "_build/objc2-tool"),
        "--",
        "--out",
        overlay,
        "--quiet"
      ],
      root
    )

    profile = if Mix.env() == :prod, do: "release", else: "debug"
    arguments = ["build", "--workspace", "--locked"]
    arguments = if profile == "release", do: arguments ++ ["--release"], else: arguments
    target = Path.join(root, "_build/native")
    run!(cargo, arguments ++ ["--target-dir", target], root)

    library =
      if :os.type() == {:unix, :darwin},
        do: "liblive_sidestep_native.dylib",
        else: "liblive_sidestep_native.so"

    install!(
      Path.join([target, profile, library]),
      Path.join(root, "priv/native/live_sidestep_native.so")
    )

    install!(
      Path.join([target, profile, "live_sidestep_host"]),
      Path.join(root, "priv/native/live_sidestep_host")
    )

    Mix.Project.build_structure()
    {:ok, []}
  end

  defp run!(command, arguments, root) do
    case System.cmd(command, arguments, cd: root, into: IO.stream(), stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {_, status} ->
        Mix.raise("native build failed (exit #{status}): #{command} #{Enum.join(arguments, " ")}")
    end
  end

  defp install!(source, destination) do
    if !File.exists?(destination) || File.read!(source) != File.read!(destination) do
      File.mkdir_p!(Path.dirname(destination))
      temporary = destination <> ".new"
      File.cp!(source, temporary)
      File.chmod!(temporary, 0o755)
      File.rename!(temporary, destination)
    end
  end
end
