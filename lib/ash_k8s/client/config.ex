defmodule AshK8s.Client.Config do
  @moduledoc """
  Resolves Kubernetes client configuration from in-cluster environment or kubeconfig file.

  Resolution order:
  1. `AshK8s.Client.Config.from_env/0` — checks for `KUBECONFIG` env var
  2. `AshK8s.Client.Config.in_cluster/0` — detects running inside a pod
  3. `AshK8s.Client.Config.from_file/1` — reads `~/.kube/config`
  """

  @in_cluster_token_path "/var/run/secrets/kubernetes.io/serviceaccount/token"
  @in_cluster_ca_path "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
  @in_cluster_namespace_path "/var/run/secrets/kubernetes.io/serviceaccount/namespace"
  @in_cluster_host "https://kubernetes.default.svc"

  @type auth ::
          {:bearer, String.t()} | {:bearer_file, Path.t()} | {:cert, binary(), binary()}

  @type t :: %__MODULE__{
          host: String.t(),
          auth: auth(),
          ca_cert: binary() | nil,
          namespace: String.t()
        }

  defstruct host: "https://localhost:6443",
            auth: nil,
            ca_cert: nil,
            namespace: "default"

  @doc """
  Resolves configuration automatically.

  Tries in-cluster first, then `~/.kube/config`.
  """
  @spec resolve() :: {:ok, t()} | {:error, term()}
  def resolve do
    cond do
      in_cluster?() -> in_cluster()
      kubeconfig_path() -> from_file(kubeconfig_path())
      true -> {:error, :no_k8s_config}
    end
  end

  @doc "Returns a config for running inside a Kubernetes pod."
  @spec in_cluster() :: {:ok, t()} | {:error, term()}
  def in_cluster do
    with {:ok, _token} <- File.read(@in_cluster_token_path),
         {:ok, ca} <- File.read(@in_cluster_ca_path),
         {:ok, ns} <- File.read(@in_cluster_namespace_path) do
      {:ok,
       %__MODULE__{
         host: @in_cluster_host,
         auth: {:bearer_file, @in_cluster_token_path},
         ca_cert: ca,
         namespace: String.trim(ns)
       }}
    end
  end

  @doc false
  @spec apply_auth(Req.Request.t(), auth() | nil) :: Req.Request.t()
  def apply_auth(request, {:bearer_file, path}) do
    Req.Request.append_request_steps(
      request,
      ash_k8s_bearer_file: fn request ->
        case File.read(path) do
          {:ok, token} ->
            case String.trim(token) do
              "" ->
                Req.Request.halt(
                  request,
                  RuntimeError.exception("Kubernetes bearer token file is empty: #{path}")
                )

              token ->
                Req.Request.put_header(request, "authorization", "Bearer #{token}")
            end

          {:error, reason} ->
            Req.Request.halt(
              request,
              RuntimeError.exception(
                "Could not read Kubernetes bearer token file #{path}: #{:file.format_error(reason)}"
              )
            )
        end
      end
    )
  end

  def apply_auth(request, {:bearer, token}) do
    Req.Request.put_header(request, "authorization", "Bearer #{token}")
  end

  def apply_auth(request, _auth), do: request

  @doc """
  Parses a kubeconfig file and returns a config for the given or current context.

  Options:
    - `:context` — use this named context instead of `current-context`
  """
  @spec from_file(Path.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def from_file(path, opts \\ []) do
    with {:ok, content} <- File.read(path),
         {:ok, kubeconfig} <- YamlElixir.read_from_string(content) do
      parse_kubeconfig(kubeconfig, opts)
    end
  end

  @doc "Resolves config for a specific named kubeconfig context."
  @spec from_context(String.t()) :: {:ok, t()} | {:error, term()}
  def from_context(context_name) do
    path = System.get_env("KUBECONFIG") || Path.expand("~/.kube/config")
    from_file(path, context: context_name)
  end

  @doc "Returns true when the in-cluster service-account token is present."
  @spec in_cluster?() :: boolean()
  def in_cluster?, do: File.exists?(@in_cluster_token_path)

  defp kubeconfig_path do
    System.get_env("KUBECONFIG") || Path.expand("~/.kube/config")
  end

  defp parse_kubeconfig(kc, opts) do
    current_context = opts[:context] || kc["current-context"]

    with {:ok, context} <- find_context(kc, current_context),
         {:ok, cluster} <- find_cluster(kc, context["context"]["cluster"]),
         {:ok, user} <- find_user(kc, context["context"]["user"]) do
      cluster_info = cluster["cluster"]
      user_info = user["user"]
      namespace = context["context"]["namespace"] || "default"

      host = cluster_info["server"]

      ca_cert =
        decode_or_read(
          cluster_info["certificate-authority-data"],
          cluster_info["certificate-authority"]
        )

      auth =
        cond do
          token = user_info["token"] ->
            {:bearer, token}

          token_file = user_info["tokenFile"] ->
            {:bearer_file, token_file}

          cert_data = user_info["client-certificate-data"] ->
            key_data = user_info["client-key-data"]
            {:cert, Base.decode64!(cert_data), Base.decode64!(key_data)}

          cert_file = user_info["client-certificate"] ->
            key_file = user_info["client-key"]
            {:cert, File.read!(cert_file), File.read!(key_file)}

          true ->
            nil
        end

      {:ok,
       %__MODULE__{
         host: host,
         auth: auth,
         ca_cert: ca_cert,
         namespace: namespace
       }}
    end
  end

  defp find_context(kc, name) do
    case Enum.find(kc["contexts"] || [], &(&1["name"] == name)) do
      nil -> {:error, {:context_not_found, name}}
      ctx -> {:ok, ctx}
    end
  end

  defp find_cluster(kc, name) do
    case Enum.find(kc["clusters"] || [], &(&1["name"] == name)) do
      nil -> {:error, {:cluster_not_found, name}}
      c -> {:ok, c}
    end
  end

  defp find_user(kc, name) do
    case Enum.find(kc["users"] || [], &(&1["name"] == name)) do
      nil -> {:error, {:user_not_found, name}}
      u -> {:ok, u}
    end
  end

  defp decode_or_read(data, _path) when is_binary(data) and data != "" do
    Base.decode64!(data)
  end

  defp decode_or_read(_data, path) when is_binary(path) and path != "" do
    File.read!(path)
  end

  defp decode_or_read(_, _), do: nil
end
