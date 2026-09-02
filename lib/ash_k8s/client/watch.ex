defmodule AshK8s.Client.Watch do
  @moduledoc """
  Streams Kubernetes watch events as an `Enumerable`.

  Uses the Kubernetes watch API (chunked HTTP) to receive a stream of
  `{type, object}` tuples. Handles `BOOKMARK` events and reconnects with
  the latest `resourceVersion` on network errors or `Gone` responses.
  """

  require Logger

  alias AshK8s.Client.Config

  @type event_type :: :added | :modified | :deleted | :bookmark
  @type event :: {event_type(), map()}

  @doc """
  Returns a lazy `Stream` of `{type, object}` tuples for the given path.

  Options:
    - `:resource_version` — start watching from this version (default: `"0"`)
    - `:label_selector` — label selector string
    - `:timeout_seconds` — server-side watch timeout (default: 300)
  """
  @spec stream(Config.t(), String.t(), keyword()) :: Enumerable.t()
  def stream(%Config{} = config, path, opts \\ []) do
    resource_version = opts[:resource_version] || "0"

    Stream.resource(
      fn -> {config, path, opts, resource_version, nil} end,
      &next_events/1,
      &cancel_async/1
    )
  end

  # State: {config, path, opts, resource_version, async_or_nil}
  # When async is nil, open a new watch connection.
  # When async is set, receive the next chunk.

  defp next_events({config, path, opts, resource_version, nil}) do
    params =
      %{
        watch: "true",
        resourceVersion: resource_version,
        allowWatchBookmarks: "true",
        timeoutSeconds: opts[:timeout_seconds] || 300
      }
      |> maybe_put(:labelSelector, opts[:label_selector])

    req = build_req(config)

    case Req.get(req, url: path, params: params, into: :self) do
      {:ok, %Req.Response{status: 200, body: async}} ->
        next_events({config, path, opts, resource_version, async})

      {:ok, %Req.Response{status: 410}} ->
        Process.sleep(1_000)
        {[], {config, path, opts, "0", nil}}

      {:ok, %Req.Response{status: status, body: body}} ->
        raise "Kubernetes watch error #{status}: #{inspect(body)}"

      {:error, reason} ->
        Logger.warning("Kubernetes watch connection failed: #{inspect(reason)}")
        Process.sleep(2_000)
        {[], {config, path, opts, resource_version, nil}}
    end
  end

  defp next_events({config, path, opts, resource_version, async}) do
    ref = async.ref
    timeout_ms = ((opts[:timeout_seconds] || 300) + 60) * 1_000

    receive do
      {^ref, {:data, data}} ->
        {events, new_rv} = parse_watch_lines(data)
        {events, {config, path, opts, new_rv || resource_version, async}}

      {^ref, :done} ->
        {[], {config, path, opts, resource_version, nil}}

      {^ref, {:error, _exception}} ->
        Process.sleep(2_000)
        {[], {config, path, opts, resource_version, nil}}
    after
      timeout_ms ->
        {[], {config, path, opts, resource_version, nil}}
    end
  end

  defp cancel_async({_config, _path, _opts, _rv, nil}), do: :ok

  defp cancel_async({_config, _path, _opts, _rv, async}) do
    try do
      async.cancel_fun.(async.ref)
    rescue
      _ -> :ok
    end
  end

  defp parse_watch_lines(data) do
    lines = String.split(data, "\n", trim: true)

    Enum.reduce(lines, {[], nil}, fn line, {events, last_rv} ->
      case Jason.decode(line) do
        {:ok, %{"type" => type, "object" => object}} ->
          rv = get_in(object, ["metadata", "resourceVersion"])
          event = {parse_type(type), object}
          {events ++ [event], rv || last_rv}

        _ ->
          {events, last_rv}
      end
    end)
  end

  defp parse_type("ADDED"), do: :added
  defp parse_type("MODIFIED"), do: :modified
  defp parse_type("DELETED"), do: :deleted
  defp parse_type("BOOKMARK"), do: :bookmark
  defp parse_type(other), do: String.downcase(other) |> String.to_atom()

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp build_req(%Config{} = config) do
    base =
      Req.new(
        base_url: config.host,
        headers: [{"accept", "application/json"}],
        receive_timeout: :infinity
      )

    apply_auth_and_tls(base, config)
  end

  defp apply_auth_and_tls(req, %{auth: {kind, _value} = auth, ca_cert: ca})
       when kind in [:bearer, :bearer_file] and is_binary(ca) do
    certs = decode_certs(ca)

    req
    |> Req.merge(connect_options: [transport_opts: [cacerts: certs]])
    |> Config.apply_auth(auth)
  end

  defp apply_auth_and_tls(req, %{auth: {kind, _value} = auth, ca_cert: nil})
       when kind in [:bearer, :bearer_file] do
    req
    |> Req.merge(connect_options: [transport_opts: [verify: :verify_none]])
    |> Config.apply_auth(auth)
  end

  defp apply_auth_and_tls(req, %{auth: {:cert, cert_pem, key_pem}, ca_cert: ca}) do
    certs = if is_binary(ca), do: decode_certs(ca), else: []
    client_cert = decode_single_cert(cert_pem)
    key = decode_key(key_pem)

    transport =
      if certs != [],
        do: [cacerts: certs, cert: client_cert, key: key],
        else: [verify: :verify_none, cert: client_cert, key: key]

    Req.merge(req, connect_options: [transport_opts: transport])
  end

  defp apply_auth_and_tls(req, _config), do: req

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

  defp decode_key(pem) do
    case :public_key.pem_decode(pem) do
      [{:RSAPrivateKey, der, _} | _] -> {:RSAPrivateKey, der}
      [{:ECPrivateKey, der, _} | _] -> {:ECPrivateKey, der}
      [{:PrivateKeyInfo, der, _} | _] -> {:PrivateKeyInfo, der}
      [{type, der, _} | _] -> {type, der}
    end
  end
end
