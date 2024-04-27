require "../src/kubernetes"

Kubernetes.import_crd "examples/crd-serviceapps.yaml"
log = Log.for("serviceapps.controller", level: :info)

k8s = Kubernetes::Client.new(
  server: URI.parse(ENV["K8S"]),
  token: ENV["TOKEN"],
  certificate_file: ENV["CA_CERT"],
)

k8s.watch_serviceapps do |watch|
  svcapp = watch.object

  case watch
  when .added?, .modified?
    log.info { "ServiceApp #{svcapp.metadata.namespace}/#{svcapp.metadata.name} updated" }
    labels = {app: svcapp.metadata.name}
    metadata = {
      name:      svcapp.metadata.name,
      namespace: svcapp.metadata.namespace,
    }

    deployment = k8s.apply_deployment(
      api_version: "apps/v1",
      kind: "Deployment",
      metadata: metadata,
      spec: {
        replicas: svcapp.spec.replicas,
        selector: {matchLabels: labels},
        template: {
          metadata: {labels: labels},
          spec:     {
            containers: [
              {
                image:   svcapp.spec.image,
                command: svcapp.spec.command,
                name:    "web",
                # env:     [
                #   # ...
                # ],
              },
            ],
          },
        },
      },
    )
    log.info { "Deployment #{deployment} applied" }

    svc = k8s.apply_service(
      api_version: "v1",
      kind: "Service",
      metadata: metadata,
      spec: {
        type:            "ClusterIP",
        selector:        labels,
        ports:           [{port: 3000}],
        sessionAffinity: "None",
      },
    )
    case svc
    in Kubernetes::Service
      log.info { "Service #{svc.metadata.namespace}/#{svc.metadata.name} applied" }
    in Kubernetes::Status
      log.info { "Service #{svcapp.metadata.namespace}/#{svcapp.metadata.name} could not be applied!" }
    end

    ingress = k8s.apply_ingress(
      api_version: "networking.k8s.io/v1",
      kind: "Ingress",
      metadata: metadata,
      spec: {
        rules: [
          {
            host: svcapp.spec.domain,
            http: {
              paths: [
                {
                  backend: {
                    service: {
                      name: metadata[:name],
                      port: {number: 3000},
                    },
                  },
                  path:     "/",
                  pathType: "Prefix",
                },
              ],
            },
          },
        ],
      },
    )
    case ingress
    in Kubernetes::Resource(Kubernetes::Networking::Ingress)
      log.info { "Ingress #{ingress.metadata.namespace}/#{ingress.metadata.name} applied" }
    in Kubernetes::Status
      log.info { "Ingress #{svcapp.metadata.namespace}/#{svcapp.metadata.name} could not be applied: #{ingress.inspect}" }
    end
  when .deleted?
    name = svcapp.metadata.name
    namespace = svcapp.metadata.namespace

    k8s.delete_ingress(name: name, namespace: namespace)
    log.info { "Ingress #{namespace}/#{name} deleted" }
    k8s.delete_service(name: name, namespace: namespace)
    log.info { "Service #{namespace}/#{name} deleted" }
    k8s.delete_deployment(name: name, namespace: namespace)
    log.info { "Deployment #{namespace}/#{name} deleted" }
  end
end
