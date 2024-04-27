require "../src/kubernetes"

log = Log.for("florp.controller", level: :info)

Kubernetes.import_crd "examples/crd-florps.yaml"

k8s = Kubernetes::Client.new(
  server: URI.parse(ENV["K8S"]),
  token: ENV["TOKEN"],
  certificate_file: ENV["CA_CERT"],
)

# Start watching for changes in our custom resources
k8s.watch_florps do |watch|
  florp = watch.object

  case watch
  when .added?, .modified?
    log.info { "Florp #{florp.metadata.name} updated" }
    k8s.apply_deployment(
      api_version: "apps/v1",
      kind: "Deployment",
      metadata: {
        name:      florp.metadata.name,
        namespace: florp.metadata.namespace,
      },
      spec: florp_spec(florp),
    )
  when .deleted?
    log.info { "Florp #{florp.metadata.name} deleted" }
    k8s.delete_deployment(
      name: florp.metadata.name,
      namespace: florp.metadata.namespace,
    )
  end
end

def florp_spec(florp : Kubernetes::Resource(Florp))
  labels = {app: florp.metadata.name}

  {
    replicas: florp.spec.count,
    selector: {matchLabels: labels},
    template: {
      metadata: {labels: labels},
      spec:     {
        containers: [
          {
            image:   "busybox:latest",
            command: %w[sleep 10000],
            name:    "sleep",
            env:     env(
              NAME: florp.spec.name,
              ID: florp.spec.id,
            ),
          },
        ],
      },
    },
  }
end

def env(**args)
  array = Array(NamedTuple(name: String, value: String))
    .new(initial_capacity: args.size)

  args.each do |key, value|
    array << {name: key.to_s, value: value}
  end

  array
end
