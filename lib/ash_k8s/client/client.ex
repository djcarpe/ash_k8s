defmodule AshK8s.Client do
  @moduledoc """
  HTTP client for the Kubernetes API server.

  Handles bearer-token and client-certificate authentication, TLS verification
  against the cluster CA, and JSON encoding/decoding.

  ## Usage

      {:ok, config} = AshK8s.Client.Config.resolve()
      client = AshK8s.Client.new(config)

      # List resources
      {:ok, list} = AshK8s.Client.list(client, "/apis/example.com/v1/namespaces/default/widgets")

      # Get a single resource
      {:ok, obj} = AshK8s.Client.get(client, "/apis/example.com/v1/namespaces/default/widgets/my-widget")

      # Apply (server-side apply)
      {:ok, obj} = AshK8s.Client.apply(client, obj)
  """

  alias AshK8s.Client.Config

  @type t :: %__MODULE__{
          config: Config.t(),
          req: Req.Request.t()
        }

  defstruct [:config, :req]

  @doc "Builds a new client from the given `AshK8s.Client.Config`."
  @spec new(Config.t()) :: t()
  def new(%Config{} = config) do
    req = build_req(config)
    %__MODULE__{config: config, req: req}
  end

  @doc "Resolves config automatically and returns a client."
  @spec from_env() :: {:ok, t()} | {:error, term()}
  def from_env do
    with {:ok, config} <- Config.resolve() do
      {:ok, new(config)}
    end
  end

  @doc "GETs a single Kubernetes object by path."
  @spec get(t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get(%__MODULE__{req: req}, path) do
    req |> Req.get(url: path) |> handle_response()
  end

  @doc """
  GETs a subresource that serves plain text (e.g. pod `/log`).

  The default client sends `Accept: application/json`, which the API server
  rejects for text-only subresources; this variant accepts anything and
  returns the raw body.
  """
  @spec get_text(t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def get_text(%__MODULE__{req: req}, path) do
    req
    |> Req.merge(headers: [{"accept", "text/plain, */*"}])
    |> Req.get(url: path)
    |> handle_response()
  end

  @doc "Lists Kubernetes objects at a path, with optional label selector."
  @spec list(t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def list(%__MODULE__{req: req}, path, opts \\ []) do
    params = Keyword.take(opts, [:labelSelector, :fieldSelector, :limit, :continue]) |> Map.new()
    req |> Req.get(url: path, params: params) |> handle_response()
  end

  @doc "POSTs a new Kubernetes object."
  @spec create(t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def create(%__MODULE__{req: req}, path, body) do
    req |> Req.post(url: path, json: body) |> handle_response()
  end

  @doc "PUTs (replaces) a Kubernetes object."
  @spec replace(t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def replace(%__MODULE__{req: req}, path, body) do
    req |> Req.put(url: path, json: body) |> handle_response()
  end

  @doc "PATCHes a Kubernetes object using the merge-patch content type."
  @spec patch(t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def patch(%__MODULE__{req: req}, path, body) do
    req
    |> Req.merge(headers: [{"content-type", "application/merge-patch+json"}])
    |> Req.patch(url: path, json: body)
    |> handle_response()
  end

  @doc "PATCHes a Kubernetes object using the strategic merge patch content type."
  @spec strategic_merge_patch(t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def strategic_merge_patch(%__MODULE__{req: req}, path, body) do
    req
    |> Req.merge(headers: [{"content-type", "application/strategic-merge-patch+json"}])
    |> Req.patch(url: path, json: body)
    |> handle_response()
  end

  @doc "Server-side applies a Kubernetes object."
  @spec apply(t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def apply(%__MODULE__{req: req}, path, body, opts \\ []) do
    field_manager = opts[:field_manager] || "ash-k8s"
    force = opts[:force] || false

    req
    |> Req.merge(headers: [{"content-type", "application/apply-patch+yaml"}])
    |> Req.patch(
      url: path,
      params: %{fieldManager: field_manager, force: force},
      json: body
    )
    |> handle_response()
  end

  @doc "DELETEs a Kubernetes object."
  @spec delete(t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def delete(%__MODULE__{req: req}, path, opts \\ []) do
    params =
      if propagation = opts[:propagation_policy], do: %{propagationPolicy: propagation}, else: %{}

    req |> Req.delete(url: path, params: params) |> handle_response()
  end

  @doc """
  Starts a watch stream for the given path.

  Returns an Enumerable that yields `{type, object}` tuples where type is
  `:added`, `:modified`, or `:deleted`.

  The caller should consume events in a dedicated process. Pass the
  `resource_version` from a prior `list/3` call to avoid re-processing history.
  """
  @spec watch(t(), String.t(), keyword()) :: Enumerable.t()
  def watch(%__MODULE__{config: config}, path, opts \\ []) do
    AshK8s.Client.Watch.stream(config, path, opts)
  end

  @doc "Updates only the status subresource of an object."
  @spec patch_status(t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def patch_status(client, path, status_body) do
    patch(client, path <> "/status", status_body)
  end

  defp build_req(%Config{host: host, auth: auth, ca_cert: ca_cert}) do
    base =
      Req.new(
        base_url: host,
        headers: [{"accept", "application/json"}, {"content-type", "application/json"}],
        decode_body: false
      )

    base = apply_tls(base, ca_cert, auth)
    apply_auth(base, auth)
  end

  defp apply_tls(req, ca_cert, {:cert, client_cert, client_key}) when is_binary(ca_cert) do
    Req.merge(req,
      connect_options: [
        transport_opts: [
          cacerts: decode_certs(ca_cert),
          cert: decode_single_cert(client_cert),
          key: decode_key(client_key)
        ]
      ]
    )
  end

  defp apply_tls(req, ca_cert, _auth) when is_binary(ca_cert) do
    Req.merge(req,
      connect_options: [
        transport_opts: [cacerts: decode_certs(ca_cert)]
      ]
    )
  end

  defp apply_tls(req, nil, _auth) do
    Req.merge(req, connect_options: [transport_opts: [verify: :verify_none]])
  end

  defp apply_auth(req, {:bearer, token}) do
    Req.merge(req, headers: [{"authorization", "Bearer #{token}"}])
  end

  defp apply_auth(req, _), do: req

  defp handle_response({:ok, %Req.Response{status: status, body: body}})
       when status in 200..299 do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:ok, body}
    end
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) do
    reason =
      case Jason.decode(body) do
        {:ok, %{"message" => msg}} -> msg
        _ -> body
      end

    {:error, {:k8s_error, status, reason}}
  end

  defp handle_response({:error, reason}), do: {:error, reason}

  defp decode_certs(pem) do
    pem
    |> :public_key.pem_decode()
    |> Enum.flat_map(fn
      {:Certificate, der, _} -> [der]
      _ -> []
    end)
  end

  defp decode_single_cert(pem) do
    [{:Certificate, der, _} | _] = :public_key.pem_decode(pem)
    der
  end

  # Returns {KeyType, DER} so the OTP SSL stack knows how to decode it.
  # Supports RSA, EC (used by k3s/k3d), and PKCS8 private keys.
  defp decode_key(pem) do
    case :public_key.pem_decode(pem) do
      [{:RSAPrivateKey, der, _} | _] -> {:RSAPrivateKey, der}
      [{:ECPrivateKey, der, _} | _] -> {:ECPrivateKey, der}
      [{:PrivateKeyInfo, der, _} | _] -> {:PrivateKeyInfo, der}
      [{type, der, _} | _] -> {type, der}
    end
  end
end
