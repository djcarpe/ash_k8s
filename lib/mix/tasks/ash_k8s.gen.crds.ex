defmodule Mix.Tasks.AshK8s.Gen.Crds do
  @shortdoc "Generate CRD YAML manifests from AshK8s resources"

  @moduledoc """
  Generates Kubernetes CRD manifests for all Ash resources using the
  `AshK8s.Resource` extension.

  ## Usage

      mix ash_k8s.gen.crds

  By default, CRD files are written to `priv/k8s/crds/`. Pass `--output` to
  change the directory:

      mix ash_k8s.gen.crds --output manifests/crds

  To generate for a specific domain only:

      mix ash_k8s.gen.crds --domain MyApp.Widgets

  ## Options

    * `--output`, `-o` — output directory (default: `priv/k8s/crds`)
    * `--domain`, `-d` — generate CRDs only for the given domain module
    * `--dry-run` — print YAML to stdout without writing files
  """

  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [output: :string, domain: :string, dry_run: :boolean],
        aliases: [o: :output, d: :domain]
      )

    output_dir = opts[:output] || "priv/k8s/crds"
    dry_run? = opts[:dry_run] || false

    resources =
      case opts[:domain] do
        nil ->
          Mix.Project.apps_paths()
          |> Enum.flat_map(fn {_app, path} ->
            load_resources_from_path(path)
          end)

        domain_str ->
          domain = Module.concat([domain_str])

          domain
          |> Ash.Domain.Info.resources()
          |> Enum.filter(&uses_ash_k8s?/1)
      end

    if resources == [] do
      Mix.shell().info("No AshK8s resources found.")
    else
      unless dry_run?, do: File.mkdir_p!(output_dir)

      Enum.each(resources, fn resource ->
        yaml = AshK8s.CRD.generate_yaml(resource)
        filename = crd_filename(resource)

        if dry_run? do
          Mix.shell().info("# CRD for #{inspect(resource)}\n#{yaml}")
        else
          path = Path.join(output_dir, filename)
          File.write!(path, yaml)
          Mix.shell().info("  Generated #{path}")
        end
      end)

      unless dry_run? do
        Mix.shell().info("\nGenerated #{length(resources)} CRD(s) in #{output_dir}/")
      end
    end
  end

  defp load_resources_from_path(_path) do
    # Walk all loaded modules and find AshK8s resources.
    :code.all_loaded()
    |> Enum.map(fn {mod, _} -> mod end)
    |> Enum.filter(&uses_ash_k8s?/1)
  end

  defp uses_ash_k8s?(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :spark_dsl_config, 0) and
      AshK8s.Resource in Spark.extensions(module)
  rescue
    _ -> false
  end

  defp crd_filename(resource) do
    group = AshK8s.Resource.Info.group!(resource)
    plural = AshK8s.Resource.Info.plural!(resource)
    "#{plural}.#{group}.yaml"
  end
end
