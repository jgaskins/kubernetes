require "http"
require "json"
require "yaml"
require "uuid"
require "uuid/json"
require "uuid/yaml"
require "uri/yaml"
require "db/pool"

require "./serializable"

module Kubernetes
  VERSION = "0.1.0"

  class Client
    def self.from_config(*, file : String = "#{ENV["HOME"]?}/.kube/config", context context_name : String? = nil)
      config = File.open(file) { |f| Config.from_yaml f }

      from_config(
        config: config,
        context: context_name || config.current_context,
      )
    end

    def self.from_config(config : Config, *, context context_name : String = config.current_context)
      if context_entry = config.contexts.find { |c| c.name == context_name }
        if cluster_entry = config.clusters.find { |c| c.name == context_entry.context.cluster }
          if user_entry = config.users.find { |u| u.name == context_entry.context.user }
            file = File.tempfile prefix: "kubernetes", suffix: ".crt" do |tempfile|
              Base64.decode cluster_entry.cluster.certificate_authority_data, tempfile
            end
            at_exit { file.delete }

            new(
              server: cluster_entry.cluster.server,
              certificate_file: file.path,
              token: user_entry.user.credential.status.token,
            )
          else
            raise ArgumentError.new("No user #{context_entry.context.user.inspect} found in Kubernetes config")
          end
        else
          raise ArgumentError.new("No cluster #{context_entry.context.cluster.inspect} found in Kubernetes config")
        end
      else
        raise ArgumentError.new("No context #{context_name.inspect} found in Kubernetes config")
      end
    end

    def self.new
      if host = ENV["KUBERNETES_SERVICE_HOST"]?
        if port = ENV["KUBERNETES_SERVICE_PORT"]?
          host += ":#{port}"
        end
        server = URI.parse("https://#{host}")
        new server: server
      elsif File.exists? "#{ENV["HOME"]?}/.kube/config"
        from_config
      else
        raise ArgumentError.new("Using `Kubernetes::Client.new` with no arguments can only be run where there is a valid `~/.kube/config` or from within a Kubernetes cluster with `KUBERNETES_SERVICE_HOST` set.")
      end
    end

    def self.new(
      server : URI,
      token : String = File.read("/var/run/secrets/kubernetes.io/serviceaccount/token"),
      certificate_file : String = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt",
      client_cert_file : String? = nil,
      private_key_file : String? = nil,
      log = Log.for("kubernetes.client")
    )
      if certificate_file || client_cert_file || private_key_file
        tls = OpenSSL::SSL::Context::Client.new

        if certificate_file
          tls.ca_certificates = certificate_file
        end

        if private_key_file
          tls.private_key = private_key_file
        end

        if client_cert_file
          tls.certificate_chain = client_cert_file
        end
      end

      new(
        server: server,
        token: token,
        tls: tls,
        log: log,
      )
    end

    def initialize(
      *,
      @server : URI = URI.parse("https://#{ENV["KUBERNETES_SERVICE_HOST"]}:#{ENV["KUBERNETES_SERVICE_PORT"]}"),
      @token : String = File.read("/var/run/secrets/kubernetes.io/serviceaccount/token"),
      @tls : OpenSSL::SSL::Context::Client?,
      @log = Log.for("kubernetes.client")
    )
      if @token.presence
        authorization = "Bearer #{token}"
      end
      @http_pool = DB::Pool(HTTP::Client).new do
        http = HTTP::Client.new(server, tls: @tls)
        http.before_request do |request|
          if authorization
            request.headers["Authorization"] = authorization
          end
        end
        http
      end
    end

    def close : Nil
      @http_pool.close
    end

    def apis
      get("/apis") do |response|
        APIGroup::List.from_json response.body_io
      end
    end

    def api_resources(group : String)
      get("/apis/#{group}") do |response|
        APIResource::List.from_json response.body_io
      end
    end

    def get(path : String, headers = HTTP::Headers.new, *, as type : T.class) : T? forall T
      get path, headers do |response|
        case response.status
        when .ok?
          T.from_json(response.body_io)
        when .not_found?
          nil
        else
          raise UnexpectedResponse.new("Unexpected response status: #{response.status_code} - #{response.body_io.gets_to_end}")
        end
      end
    end

    def get(path : String, headers = HTTP::Headers.new)
      @http_pool.checkout do |http|
        path = path.gsub(%r{//+}, '/')
        http.get path, headers: headers do |response|
          yield response
        ensure
          response.body_io.skip_to_end
        end
      end
    end

    def put(path : String, body, headers = HTTP::Headers.new)
      @http_pool.checkout do |http|
        path = path.gsub(%r{//+}, '/')
        http.put path, headers: headers, body: body.to_json
      end
    end

    def raw_patch(path : String, body, headers = HTTP::Headers.new)
      @http_pool.checkout do |http|
        path = path.gsub(%r{//+}, '/')
        http.patch path, headers: headers, body: body
      end
    end

    def patch(path : String, body, headers = HTTP::Headers.new)
      headers["Content-Type"] = "application/apply-patch+yaml"

      @http_pool.checkout do |http|
        path = path.gsub(%r{//+}, '/')
        http.patch path, headers: headers, body: body.to_yaml
      end
    end

    def delete(path : String, headers = HTTP::Headers.new)
      @http_pool.checkout do |http|
        path = path.gsub(%r{//+}, '/')
        http.delete path, headers: headers
      end
    end

    private def make_label_selector_string(label_selector : String | Nil)
      label_selector
    end

    private def make_label_selector_string(kwargs : NamedTuple)
      make_label_selector_string(**kwargs)
    end

    private def make_label_selector_string(**kwargs : String)
      size = 0
      kwargs.each do |key, value|
        size += key.to_s.bytesize + value.bytesize + 2 # ',' and '='
      end

      String.build size do |str|
        kwargs.each_with_index 1 do |key, value, index|
          key.to_s str
          str << '=' << value
          unless index == kwargs.size
            str << ','
          end
        end
      end
    end

    private def make_label_selector_string(labels : Hash(String, String))
      size = 0
      labels.each do |(key, value)|
        size += key.bytesize + value.bytesize + 2 # ',' and '='
      end

      String.build size do |str|
        labels.each_with_index 1 do |(key, value), index|
          str << key << '=' << value

          unless index == labels.size
            str << ','
          end
        end
      end
    end
  end

  struct Resource(T)
    include Serializable

    field api_version : String { "" }
    field kind : String { "" }
    field metadata : Metadata
    field spec : T
    field status : JSON::Any = JSON::Any.new(nil)

    def initialize(*, @api_version, @kind, @metadata, @spec, @status = JSON::Any.new(nil))
    end
  end

  struct Metadata
    include Serializable

    DEFAULT_TIME = Time.new(seconds: 0, nanoseconds: 0, location: Time::Location::UTC)

    field name : String = ""
    field namespace : String { "" }
    field labels : Hash(String, String) { {} of String => String }
    field annotations : Hash(String, String) { {} of String => String }
    field resource_version : String, ignore_serialize: true { "" }
    field generate_name : String, ignore_serialize: true { "" }
    field generation : Int64, ignore_serialize: true { 0i64 }
    field creation_timestamp : Time = DEFAULT_TIME, ignore_serialize: true
    field deletion_timestamp : Time?, ignore_serialize: true
    field owner_references : Array(OwnerReferenceApplyConfiguration), ignore_serialize: true do
      [] of OwnerReferenceApplyConfiguration
    end
    field finalizers : Array(String) { %w[] }
    field uid : UUID, ignore_serialize: true { UUID.empty }

    def initialize(@name, @namespace = nil, @labels = {} of String => String, @annotations = {} of String => String)
    end
  end

  struct OwnerReferenceApplyConfiguration
    include Serializable

    field api_version : String?
    field kind : String?
    field name : String?
    field uid : UUID?
    field controller : Bool = false
    field block_owner_deletion : Bool?
  end

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

  struct APIGroup
    include Serializable

    field name : String
    field versions : Array(Version)
    field preferred_version : Version

    struct List
      include Serializable

      field api_version : String
      field kind : String
      field groups : Array(APIGroup)
    end

    struct Version
      include Serializable

      field group_version : String
      field version : String
    end
  end

  struct APIResource
    include Serializable

    field name : String
    field singular_name : String
    field namespaced : Bool
    field kind : String
    field verbs : Array(String)
    field short_names : Array(String) { %w[] }
    field storage_version_hash : String = ""

    struct List
      include Serializable

      field api_version : String?
      field group_version : String
      field resources : Array(APIResource)
    end
  end

  struct Event
    include Serializable

    field metadata : Metadata
    field event_time : String?
    field reason : String
    field regarding : Regarding
    field note : String
    field type : String

    struct Regarding
      include Serializable

      field kind : String
      field namespace : String
      field name : String
      field uid : UUID
      field api_version : String
      field resource_version : String
      field field_path : String?
    end

    struct Metadata
      include Serializable

      field name : String
      field namespace : String
      field uid : UUID
      field resource_version : String
      field creation_timestamp : Time
    end
  end

  struct StatefulSet
    include Serializable

    field replicas : Int32
    field template : JSON::Any
    field selector : JSON::Any
    field volume_claim_templates : JSON::Any
  end

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
        @progress_deadline_seconds = 600
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

  struct PodTemplate
    include Serializable

    field metadata : Metadata?
    field spec : PodSpec?
  end

  # https://github.com/kubernetes/kubernetes/blob/2dede1d4d453413da6fd852e00fc7d4c8784d2a8/staging/src/k8s.io/client-go/applyconfigurations/core/v1/podspec.go#L27-L63
  struct PodSpec
    include Serializable

    field containers : Array(Container)
    field restart_policy : String?
    field termination_grace_period_seconds : Int32
    field dns_policy : String
    field service_account_name : String?
    field service_account : String?
    field security_context : JSON::Any
    field scheduler_name : String
  end

  struct Container
    include Serializable

    field name : String
    field image : String
    field args : Array(String) = %w[]
    field ports : Array(Port) = [] of Port
    field env : Array(EnvVar) = [] of EnvVar
    field resources : Resources = Resources.new
    field termination_message_path : String?
    field termination_message_policy : String?
    field image_pull_policy : String

    struct Resources
      include Serializable

      field requests : Resource?
      field limits : Resource?

      def initialize
      end

      struct Resource
        include Serializable

        field cpu : String?
        field memory : String?
      end
    end

    struct EnvVar
      include Serializable

      field name : String
      field value : String { "" }
      field value_from : EnvVarSource?
    end

    struct EnvVarSource
      include Serializable

      field field_ref : ObjectFieldSelector?
      field config_map_key_ref : ConfigMapKeySelector?
      field resource_field_ref : ResourceFieldSelector?
      field secret_key_ref : SecretKeySelector?
    end

    struct ObjectFieldSelector
      include Serializable

      field api_version : String = "v1"
      field field_path : String
    end

    struct ConfigMapKeySelector
      include Serializable

      field key : String
      field name : String
      field optional : Bool?
    end

    struct ResourceFieldSelector
      include Serializable

      field container_name : String?
      field divisor : JSON::Any
      field resource : String
    end

    struct SecretKeySelector
      include Serializable

      field key : String
      field name : String
      field optional : Bool?
    end

    struct Port
      include Serializable

      field container_port : Int32?
      field protocol : String?
    end
  end

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

  struct Pod
    include Serializable

    field metadata : Metadata
    field spec : Spec
    field status : JSON::Any

    struct Spec
      include Serializable

      field volumes : Array(Volume)
      field containers : Array(Container)
      field restart_policy : String?
      field termination_grace_period_seconds : Int32
      field dns_policy : String
      field service_account_name : String?
      field service_account : String?
      field node_name : String = ""
      field security_context : JSON::Any
      field scheduler_name : String
      field tolerations : Array(Toleration)

      struct Toleration
        include Serializable

        field key : String = ""
        field operator : String = ""
        field effect : String = ""
        field toleration_seconds : Int32 = 0
      end

      struct Volume
        include Serializable

        field name : String
        field projected : Template?

        struct Template
          include Serializable

          field sources : Array(JSON::Any)
          field default_mode : Int32
        end
      end
    end

    struct Metadata
      include Serializable

      field namespace : String
      field name : String
      field generate_name : String?
      field uid : UUID
      field resource_version : String
      field creation_timestamp : Time
      field labels : Hash(String, String) = {} of String => String
      field annotations : Hash(String, String) = {} of String => String
      field owner_references : Array(OwnerReference) = [] of OwnerReference

      struct OwnerReference
        include Serializable
        field api_version : String = "apps/v1"
        field name : String
        field kind : String
        field uid : UUID
        field controller : Bool
        field block_owner_deletion : Bool?
      end
    end
  end

  module Networking
    struct Ingress
      include Serializable

      field rules : Array(Rule) = [] of Rule

      struct Rule
        include Serializable

        field host : String
        field http : HTTP

        struct HTTP
          include Serializable

          field paths : Array(Path)

          struct Path
            include Serializable

            field path : String
            field path_type : PathType
            field backend : Backend

            enum PathType
              ImplementationSpecific
              Exact
              Prefix
            end

            struct Backend
              include Serializable

              struct Service
                include Serializable

                field name : String
                field port : Port

                struct Port
                  include Serializable

                  field number : Int32
                end
              end
            end
          end
        end
      end
    end
  end

  struct List(T)
    include Serializable
    include Enumerable(T)

    field api_version : String
    field kind : String
    field metadata : Metadata
    field items : Array(T)

    delegate each, to: items
  end

  struct Watch(T)
    include Serializable

    field type : Type
    field object : T

    delegate added?, modified?, deleted?, error?, to: type

    def initialize(@type : Type, @object : T)
    end

    enum Type
      ADDED
      MODIFIED
      DELETED
      ERROR
    end
  end

  struct Status
    include Serializable

    field kind : String
    field api_version : String
    field metadata : Metadata
    field status : String
    field message : String
    field reason : String = ""
    field details : Details = Details.new
    field code : Int32

    struct Details
      include Serializable

      field name : String = ""
      field group : String = ""
      field kind : String = ""

      def initialize
      end
    end
  end

  # Define a new Kubernetes resource type. This can be used to specify your CRDs
  # to be able to manage your custom resources in Crystal code.
  macro define_resource(name, group, type, version = "v1", prefix = "apis", api_version = nil, kind = nil, list_type = nil, singular_name = nil, cluster_wide = false)
    {% api_version ||= "#{group}/#{version}" %}
    {% if kind == nil %}
      {% if type.resolve == ::Kubernetes::Resource %}
        {% kind = type.type_vars.first %}
      {% else %}
        {% kind = type.stringify %}
      {% end %}
    {% end %}
    {% singular_name ||= name.gsub(/s$/, "").id %}
    {% plural_method_name = name.gsub(/-/, "_") %}
    {% singular_method_name = singular_name.gsub(/-/, "_") %}

    class ::Kubernetes::Client
      def {{plural_method_name.id}}(
        {% if cluster_wide == false %}
          namespace : String? = "default",
        {% end %}
        # FIXME: Currently this is intended to be a string, but maybe we should
        # make it a Hash/NamedTuple?
        label_selector = nil,
      )
        label_selector = make_label_selector_string(label_selector)
        {% if cluster_wide == false %}
          namespace &&= "/namespaces/#{namespace}"
        {% else %}
          namespace = nil
        {% end %}
        params = URI::Params.new
        params["labelSelector"] = label_selector if label_selector
        path = "/{{prefix.id}}/{{group.id}}/{{version.id}}#{namespace}/{{name.id}}?#{params}"
        get path do |response|
          case response.status
          when .ok?
            # JSON.parse response.body_io
            {% if list_type %}
              {{list_type}}.from_json response.body_io
            {% else %}
              ::Kubernetes::List({{type}}).from_json response.body_io
            {% end %}
          when .not_found?
            raise ClientError.new "API resource \"{{name.id}}\" not found. Did you apply the CRD to the Kubernetes control plane?"
          else
            raise Error.new("Unknown Kubernetes API response: #{response.status} - please report to https://github.com/jgaskins/kubernetes/issues")
          end
        end
      end

      def {{singular_method_name.id}}(name : String, namespace : String = "default", resource_version : String = "")
        namespace = "/namespaces/#{namespace}"
        path = "/{{prefix.id}}/{{group.id}}/{{version.id}}#{namespace}/{{name.id}}/#{name}" 
        params = URI::Params{
          "resourceVersion" => resource_version,
        }

        get "#{path}?#{params}" do |response|
          case value = ({{type}} | Status).from_json response.body_io
          when Status
            nil
          else
            value
          end
        end
      end

      def apply_{{singular_method_name.id}}(
        resource : {{type}},
        spec,
        name : String = resource.metadata.name,
        {% unless cluster_wide %}
        namespace : String? = resource.metadata.namespace,
        {% end %}
        force : Bool = false,
        field_manager : String? = nil,
      )
        path = "/{{prefix.id}}/{{group.id}}/{{version.id}}{{cluster_wide ? "".id : "/namespaces/\#{namespace}".id}}/{{name.id}}/#{name}"
        params = URI::Params{
          "force" => force.to_s,
          "fieldManager" => field_manager || "k8s-cr",
        }
        metadata = {
          name: name,
          namespace: namespace,
        }
        if resource_version = resource.metadata.resource_version.presence
          metadata = metadata.merge(resourceVersion: resource_version)
        end

        response = patch "#{path}?#{params}", {
          apiVersion: resource.api_version,
          kind: resource.kind,
          metadata: metadata,
          spec: spec,
        }

        if body = response.body
          {{type}}.from_json response.body
        else
          raise "Missing response body"
        end
      end

      def apply_{{singular_method_name.id}}(
        metadata : NamedTuple | Metadata,
        api_version : String = "{{group.id}}/{{version.id}}",
        kind : String = "{{kind.id}}",
        force : Bool = false,
        field_manager : String? = nil,
        **kwargs,
      )
        case metadata
        in NamedTuple
          name = metadata[:name]
          {% if cluster_wide == false %}
            namespace = metadata[:namespace]
          {% end %}
        in Metadata
          name = metadata.name
          {% if cluster_wide == false %}
            namespace = metadata.namespace
          {% end %}
        end

        path = "/{{prefix.id}}/{{group.id}}/{{version.id}}{% if cluster_wide == false %}/namespaces/#{namespace}{% end %}/{{name.id}}/#{name}"
        params = URI::Params{
          "force" => force.to_s,
          "fieldManager" => field_manager || "k8s-cr",
        }
        response = patch "#{path}?#{params}", {
          apiVersion: api_version,
          kind: kind,
          metadata: metadata,
        }.merge(kwargs)

        if body = response.body
          # {{type}}.from_json response.body
          # JSON.parse body
          ({{type}} | Status).from_json body
        else
          raise "Missing response body"
        end
      end

      def patch_{{singular_method_name.id}}(name : String, {% if cluster_wide == false %}namespace, {% end %}**kwargs)
        path = "/{{prefix.id}}/{{group.id}}/{{version.id}}{% if cluster_wide == false %}/namespaces/#{namespace}{% end %}/{{name.id}}/#{name}"
        headers = HTTP::Headers{
          "Content-Type" =>  "application/merge-patch+json",
        }

        response = raw_patch path, kwargs.to_json, headers: headers
        if body = response.body
          ({{type}} | Status).from_json body
        else
          raise "Missing response body"
        end
      end

      def patch_{{singular_method_name.id}}_subresource(name : String, subresource : String{% if cluster_wide == false %}, namespace : String = "default"{% end %}, **args)
        path = "/{{prefix.id}}/{{group.id}}/{{version.id}}{% if cluster_wide == false %}/namespaces/#{namespace}{% end %}/{{name.id}}/#{name}/#{subresource}"
        headers = HTTP::Headers{
          "Content-Type" =>  "application/merge-patch+json",
        }

        response = raw_patch path, args.to_json, headers: headers
        if body = response.body
          # ({{type}} | Status).from_json body
          JSON.parse body
        else
          raise "Missing response body"
        end
      end

      def delete_{{singular_method_name.id}}(resource : {{type}})
        delete_{{singular_method_name.id}} name: resource.metadata.name, namespace: resource.metadata.namespace
      end

      def delete_{{singular_method_name.id}}(name : String{% if cluster_wide == false %}, namespace : String = "default"{% end %})
        path = "/{{prefix.id}}/{{group.id}}/{{version.id}}{% if cluster_wide == false %}/namespaces/#{namespace}{% end %}/{{name.id}}/#{name}"
        response = delete path
        JSON.parse response.body
      end

      def watch_{{plural_method_name.id}}(resource_version = "0", timeout : Time::Span = 1.hour, namespace : String? = nil, labels label_selector : String = "")
        params = URI::Params{
          "watch" => "1",
          "timeoutSeconds" => timeout.total_seconds.to_i.to_s,
          "labelSelector" =>  label_selector,
        }
        if namespace
          namespace = "/namespaces/#{namespace}"
        end
        get_response = nil
        loop do
          params["resourceVersion"] = resource_version

          return get "/{{prefix.id}}/{{group.id}}/{{version.id}}#{namespace}/{{name.id}}?#{params}" do |response|
            get_response = response
            unless response.success?
              if response.headers["Content-Type"]?.try(&.includes?("application/json"))
                message = JSON.parse(response.body_io)
              else
                message = response.body_io.gets_to_end
              end

              raise ClientError.new("#{response.status}: #{message}")
            end

            loop do
              watch = Watch({{type}} | Status).from_json IO::Delimited.new(response.body_io, "\n")

              # If there's a JSON parsing failure and we loop back around, we'll
              # use this resource version to pick up where we left off.
              resource_version = watch.object.metadata.resource_version

              case obj = watch.object
              when Status
                # If this is an error of some kind, we don't care we'll just run
                # another request starting from the last resource version we've
                # worked with.
                next
              else
                watch = Watch.new(
                  type: watch.type,
                  object: obj,
                )
              end

              yield watch
            end
          end
        rescue ex : IO::Error
          @log.warn { ex }
          sleep 1 # Don't hammer the server
        rescue ex : JSON::ParseException
          @log.warn { "Cannot parse watched object: #{ex} (server may have closed the HTTP connection)" }
        end
      ensure
        @log.warn { "Exited watch loop for {{plural_method_name.id}}, response = #{get_response.inspect}" }
      end
    end
    {% debug if flag? :debug_define_resource %}
  end

  macro import_crd(yaml_file)
    {{ run("./import_crd", yaml_file) }}
    {% debug if flag? :debug_import_crd %}
  end

  class Error < ::Exception
  end

  class ClientError < Error
  end

  class UnexpectedResponse < Error
  end

  define_resource "deployments",
    group: "apps",
    type: Deployment

  define_resource "statefulsets",
    group: "apps",
    type: Resource(StatefulSet),
    kind: "StatefulSet"

  define_resource "jobs",
    group: "batch",
    type: Resource(Job),
    kind: "Job"

  define_resource "services",
    group: "",
    type: Service,
    prefix: "api"

  define_resource "persistentvolumeclaims",
    group: "",
    type: Resource(JSON::Any), # TODO: Write PVC struct,
    prefix: "api",
    kind: "PersistentVolumeClaim"

  define_resource "ingresses",
    singular_name: "ingress",
    group: "networking.k8s.io",
    type: Resource(Networking::Ingress),
    kind: "Ingress"

  define_resource "pods",
    group: "",
    type: Pod,
    prefix: "api"

  struct Config
    include Serializable

    field api_version : String
    field kind : String
    field clusters : Array(ClusterEntry)
    field contexts : Array(ContextEntry)
    field current_context : String,
      key: "current-context"
    field preferences : Hash(String, YAML::Any)
    field users : Array(UserEntry)

    struct ClusterEntry
      include Serializable

      field cluster : Cluster
      field name : String

      struct Cluster
        include Serializable

        field certificate_authority_data : String, key: "certificate-authority-data"
        field server : URI
      end
    end

    struct ContextEntry
      include Serializable

      field context : Context
      field name : String

      struct Context
        include Serializable

        field cluster : String
        field user : String
      end
    end

    struct UserEntry
      include Serializable

      field name : String
      field user : User

      struct User
        include Serializable
        include YAML::Serializable::Unmapped

        field exec : Exec?

        def credential
          if exec = self.exec
            output = IO::Memory.new
            Process.run(
              command: exec.command,
              args: exec.args,
              output: output,
            )
            ExecCredential.from_json output.rewind
          else
            raise "Cannot figure out how to get credentials for #{inspect}"
          end
        end

        struct ExecCredential
          include Serializable

          field api_version : String
          field kind : String
          field spec : JSON::Any
          field status : Status

          struct Status
            include Serializable

            field expiration_timestamp : Time
            field token : String
          end
        end
      end

      struct Exec
        include Serializable

        field api_version : String
        field args : Array(String) { [] of String }
        field command : String
        field env : YAML::Any?
        field interactive_mode : String?
        field? provide_cluster_info : Bool?
      end
    end
  end
end
