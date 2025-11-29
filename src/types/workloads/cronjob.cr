module Kubernetes
  struct CronJob
    include Serializable

    field schedule : String
    field job_template : JobTemplate

    struct JobTemplate
      include Serializable

      field spec : Spec

      struct Spec
        include Serializable

        field template : Job
      end
    end
  end

  define_resource "cronjobs",
    group: "batch",
    type: Resource(CronJob),
    kind: "CronJob"
end
