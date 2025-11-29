module Kubernetes
  struct Service
    include Serializable

    field api_version : String = "v1"
    field kind : String = "Service"
    field metadata : Metadata
    field spec : Spec
    field status : Status

    struct Spec
      include Serializable

      field cluster_ip : String = "", key: "clusterIP"
      field cluster_ips : Array(String), key: "clusterIPs" { %w[] }
      field external_ips : Array(String), key: "externalIPs" { %w[] }
      field external_name : String?
      field external_traffic_policy : TrafficPolicy?
      field health_check_node_port : Int32?
      field internal_traffic_policy : TrafficPolicy?
      field ip_families : Array(IPFamily) { [] of IPFamily }
      field ip_family_policy : IPFamilyPolicy
      field load_balancer_ip : String?, key: "loadBalancerIP"
      field load_balancer_source_ranges : String?
      field ports : Array(Port) = [] of Port
      field publish_not_ready_addresses : Bool?
      field selector : Hash(String, String)?
      field session_affinity : SessionAffinity?
      field session_affinity_config : SessionAffinityConfig?
      field type : Type

      def initialize(@ports : Array(Port), @type = :cluster_ip, @ip_family_policy = :single_stack)
      end
    end

    enum Type
      ClusterIP
      ExternalName
      NodePort
      LoadBalancer
    end

    enum TrafficPolicy
      Local
      Cluster
    end

    enum IPFamily
      IPv4
      IPv6
    end

    enum IPFamilyPolicy
      SingleStack
      PreferDualStack
      RequireDualStack
    end

    struct Status
      include Serializable

      field conditions : Array(Condition) { [] of Condition }
      field load_balancer : LoadBalancer::Status?
    end

    module LoadBalancer
      struct Status
        include Serializable

        field ingress : Array(Ingress) { [] of Ingress }
      end

      struct Ingress
        include Serializable

        field hostname : String = ""
        field ip : String = ""
        field ports : Array(PortStatus) { [] of PortStatus }
      end

      struct PortStatus
        include Serializable

        field error : String?
        field port : Int32 = -1
        field protocol : Port::Protocol
      end
    end

    struct Condition
      include Serializable

      field last_transition_time : Time
      field message : String = ""
      field observed_generation : Int64
      field reason : String = ""
      field status : Status
      field type : String

      enum Status
        True
        False
        Unknown
      end
    end

    struct Port
      include Serializable

      field app_protocol : String?
      field name : String = ""
      field node_port : Int32?
      field port : Int32
      field protocol : Protocol
      field target_port : Int32 | String | Nil

      enum Protocol
        TCP
        UDP
        STCP
      end
    end

    enum SessionAffinity
      None
      ClientIP
    end

    struct SessionAffinityConfig
      include Serializable

      field client_ip : ClientIPConfig?
    end

    struct ClientIPConfig
      include Serializable

      field timeout_seconds : Int32
    end
  end

  define_resource "services",
    group: "",
    type: Service,
    prefix: "api"
end
