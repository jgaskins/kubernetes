module Kubernetes
  define_resource "persistentvolumeclaims",
    group: "",
    type: Resource(JSON::Any), # TODO: Write PVC struct,
    prefix: "api",
    kind: "PersistentVolumeClaim"
end
