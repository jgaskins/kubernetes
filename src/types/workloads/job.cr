require "../pods/pod_spec"

module Kubernetes
  # https://github.com/kubernetes/kubernetes/blob/2dede1d4d453413da6fd852e00fc7d4c8784d2a8/staging/src/k8s.io/client-go/applyconfigurations/batch/v1/jobspec.go#L29-L40
  struct Job
    include Serializable

    field parallelism : Int32?
    field completions : Int32?
    field active_deadline_seconds : Int64?
    field backoff_limit : Int32?
    # TODO: Should Selector be extracted to a higher layer?
    field selector : Deployment::Spec::Selector?
    field? manual_selector : Bool?
    # TODO: ditto?
    field template : PodTemplate?
    field ttl_seconds_after_finished : Int32?
    field completion_mode : String?
    field? suspend : Bool?
  end

  define_resource "jobs",
    group: "batch",
    type: Resource(Job),
    kind: "Job"
end
