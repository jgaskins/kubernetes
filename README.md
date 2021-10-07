# Kubernetes

A Kubernetes client that allows you to manage Kubernetes resources programmatically, similarly to how you might with `kubectl`.

## Installation

Add this to your `shards.yml`:

```yaml
dependencies:
  kubernetes:
    github: jgaskins/kubernetes
```

## Usage

First, instantiate your Kubernetes client:

```crystal
require "kubernetes"

k8s = Kubernetes::Client.new(
  server: URI.parse("https://#{ENV["KUBERNETES_SERVICE_HOST"]}:#{ENV["KUBERNETES_SERVICE_PORT"]}"),
  token: File.read("/var/run/secrets/kubernetes.io/serviceaccount/token"),
  certificate_file: "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt",
)
```

When you're running this inside a Kubernetes cluster, it will automatically find the Kubernetes API server, token, and cert file, so you can simplify even more:

```crystal
require "kubernetes"

k8s = Kubernetes::Client.new
```

Then you can fetch information about your deployments or pods:

```crystal
pp k8s.deployments
pp k8s.pods
```

### `CustomResourceDefinition`s

You can import a CRD directly from YAML. Let's say you have this CRD (taken from [the example in the Kubernetes CRD docs](https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/)):

```yaml
# k8s/crd-crontab.yaml
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: crontabs.stable.example.com
spec:
  group: stable.example.com
  versions:
    - name: v1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                cronSpec:
                  type: string
                image:
                  type: string
                replicas:
                  type: integer
  scope: Namespaced
  names:
    plural: crontabs
    singular: crontab
    kind: CronTab
    shortNames:
    - ct
```

When you run `Kubernetes.import_crd("k8s/crd-crontab.yaml")`, the CRD will provide the following:

1. A `CronTab` struct
   - Represents the `spec` of the top-level `CronTab` resource in Kubernetes
   - The top-level resource is a `Kubernetes::Resource(CronTab)`
   - Has the following `getter` methods:
     - `cron_spec : String`
     - `image : String`
     - `replicas : Int64`
2. The following methods added to `Kubernetes::Client`:
   - `crontabs(namespace : String? = nil) : Array(Kubernetes::Resource(CronTab))`
     - When `namespace` is `nil`, _all_ `CronTab`s are returned
   - `crontab(name : String, namespace : String = "default") : Kubernetes::Resource(CronTab)`
   - `apply_crontab(api_version : String, kind : String, metadata, spec, force = false)`
     - Allows you to specify a complete Kubernetes manifest programmatically
     - On success, returns a `Kubernetes::Resource(CronTab)` representing the applied configuration
     - On failure, returns a `Kubernetes::Status` with information about the failure
   - `delete_crontab(name : String, namespace : String)`
   - `watch_crontabs(namespace : String, &on_change : Kubernetes::Watch(Kubernetes::Resource(CronTab)) ->)`
     - Allows you to define controllers that respond to changes in your custom resources

### Building a Controller

Kubernetes controllers respond to changes in resources, often by making changes to other resources. For example, you might deploy a service that needs the following:

- `Deployment` for a web app
- `Service` to direct requests to that web app
- `Ingress` to bring web requests to that service

All of these things can be configured with a `ServiceApp` CRD. Let's say we have the following CRD:

```yaml
# k8s/crd-serviceapp.yaml
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: serviceapps.example.com
spec:
  group: example.com
  versions:
    - name: v1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                domain:
                  type: string
                command:
                  type: array
                  items:
                    type: string
                  minItems: 1
                image:
                  type: string
                replicas:
                  type: integer
  scope: Namespaced
  names:
    plural: serviceapps
    singular: serviceapp
    kind: ServiceApp
    shortNames:
    - svcapp
```

And whenever someone creates, updates, or deletes a `ServiceApp` resource, it needs to create, update, or delete the `Deployment`, `Service`, and `Ingress` resources accordingly:

```crystal
require "kubernetes"

Kubernetes.import_crd "k8s/crd-serviceapps.yaml"
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
          spec: {
            containers: [
              {
                image:   svcapp.spec.image,
                command: svcapp.spec.command,
                name:    "web",
                env:     [
                  { name: "VAR_NAME", value: "var value" },
                  # ...
                ],
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
        type: "ClusterIP",
        selector: labels,
        ports: [{ port: 3000 }],
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
                      port: { number: 3000 },
                    },
                  },
                  path: "/",
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
```

## Contributing

1. Fork it (<https://github.com/jgaskins/kubernetes/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Jamie Gaskins](https://github.com/jgaskins) - creator and maintainer
