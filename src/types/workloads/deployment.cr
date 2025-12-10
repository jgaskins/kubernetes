require "../pods/pod_spec"

module Kubernetes
  struct Deployment
    include Serializable

    field metadata : Metadata
    field spec : Spec
    field status : Status?

    def initialize(*, @metadata, @spec, @status = nil)
    end

    struct Status
      include Serializable

      field observed_generation : Int32 = -1
      field replicas : Int32 = -1
      field updated_replicas : Int32 = -1
      field ready_replicas : Int32 = -1
      field available_replicas : Int32 = -1
      field conditions : Array(Condition) = [] of Condition

      struct Condition
        include Serializable

        field type : String
        field status : String
        field last_update_time : Time
        field last_transition_time : Time
        field reason : String
        field message : String
      end
    end

    struct Spec
      include Serializable

      field replicas : Int32
      field selector : Selector
      field template : PodTemplate
      field strategy : Strategy
      field revision_history_limit : Int32
      field progress_deadline_seconds : Int32

      def initialize(
        *,
        @replicas = 1,
        @selector = Selector.new,
        @template,
        @strategy = Strategy.new,
        @revision_history_limit = 10,
        @progress_deadline_seconds = 600,
      )
      end

      struct Strategy
        include Serializable

        field type : String
        field rolling_update : RollingUpdate?

        struct RollingUpdate
          include Serializable

          field max_unavailable : String | Int32
          field max_surge : String | Int32
        end
      end

      struct Selector
        include Serializable

        field match_labels : Hash(String, String) = {} of String => String
      end
    end

    struct Metadata
      include Serializable

      field name : String = ""
      field namespace : String = ""
      field uid : UUID = UUID.empty
      field resource_version : String = ""
      field generation : Int64 = -1
      field creation_timestamp : Time = Time::UNIX_EPOCH
      field labels : Hash(String, String) = {} of String => String
      field annotations : Hash(String, String) = {} of String => String
    end
  end

  define_resource "deployments",
    group: "apps",
    type: Deployment
end
