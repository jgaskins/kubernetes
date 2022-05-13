require "http"
require "json"
require "yaml"
require "uuid"
require "uuid/json"
require "uuid/yaml"
require "db/pool"

require "./serializable"

module Kubernetes
  VERSION = "0.1.0"

  class Client
    def initialize(
      @server : URI = URI.parse("https://#{ENV["KUBERNETES_SERVICE_HOST"]}:#{ENV["KUBERNETES_SERVICE_PORT"]}"),
      @token : String = File.read("/var/run/secrets/kubernetes.io/serviceaccount/token"),
      @certificate_file : String = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt",
      @log = Log.for("kubernetes.client")
    )
      tls = OpenSSL::SSL::Context::Client.new
      tls.ca_certificates = @certificate_file
      @headers = HTTP::Headers{"Authorization" => "Bearer #{token}"}

      @http_pool = DB::Pool(HTTP::Client).new do
        HTTP::Client.new(server, tls: tls)
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

    def get(path : String, headers = @headers)
      @http_pool.checkout do |http|
        path = path.gsub(%r{//+}, '/')
        http.get path, headers: headers do |response|
          yield response
        ensure
          response.body_io.skip_to_end
        end
      end
    end

    def put(path : String, body, headers = @headers)
      @http_pool.checkout do |http|
        path = path.gsub(%r{//+}, '/')
        http.put path, headers: headers, body: body.to_json
      end
    end

    def patch(path : String, body, headers = @headers.dup)
      headers["Content-Type"] = "application/apply-patch+yaml"

      @http_pool.checkout do |http|
        path = path.gsub(%r{//+}, '/')
        http.patch path, headers: headers, body: body.to_yaml
      end
    end

    def delete(path : String, headers = @headers)
      @http_pool.checkout do |http|
        path = path.gsub(%r{//+}, '/')
        http.delete path, headers: headers
      end
    end
  end

  struct Resource(T)
    include Serializable

    field api_version : String = ""
    field kind : String = ""
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
    field namespace : String = ""
    field labels : Hash(String, String) = {} of String => String
    field annotations : Hash(String, String) = {} of String => String
    field resource_version : String = ""
    field generate_name : String = ""
    field generation : Int64 = 0i64
    field creation_timestamp : Time = DEFAULT_TIME
    field deletion_timestamp : Time = DEFAULT_TIME
    field owner_references : Array(OwnerReferenceApplyConfiguration) { [] of OwnerReferenceApplyConfiguration }
    field finalizers : Array(String) { %w[] }
    field uid : UUID = UUID.empty

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

    struct Spec
      include Serializable

      field ports : Array(Port) = [] of Port
      field type : String = ""
      field session_affinity : String = "None"
      field external_name : String = ""

      def initialize(@ports : Array(Port))
      end

      struct Port
        include Serializable

        field name : String = ""
        field port : Int32
        field protocol : String
        field target_port : Int32 | String | Nil
      end
    end
  end

  struct Pod
    include Serializable

    field spec : Spec

    struct Spec
      include Serializable
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
    field short_names : Array(String) = %w[]
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
      field template : Template
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

      struct Template
        include Serializable

        field metadata : Metadata?
        field spec : Spec?

        # https://github.com/kubernetes/kubernetes/blob/2dede1d4d453413da6fd852e00fc7d4c8784d2a8/staging/src/k8s.io/client-go/applyconfigurations/core/v1/podspec.go#L27-L63
        struct Spec
          include Serializable

          field containers : Array(Container)
          field restart_policy : String?
          field termination_grace_period_seconds : Int32
          field dns_policy : String
          field service_account_name : String?
          field service_account : String?
          field security_context : JSON::Any
          field scheduler_name : String

          struct Container
            include Serializable

            field name : String
            field image : String
            field args : Array(String) = %w[]
            field ports : Array(Port) = [] of Port
            field env : Array(Env) = [] of Env
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

            struct Env
              include Serializable

              field name : String
              field value : String = ""
              field value_from : ValueFrom?

              struct ValueFrom
                include Serializable

                field field_ref : FieldRef?
              end

              struct FieldRef
                include Serializable

                field api_version : String = "v1"
                field field_path : String
              end
            end

            struct Port
              include Serializable

              field container_port : Int32?
              field protocol : String?
            end
          end
        end

        struct Metadata
          include Serializable

          field creation_timestamp : Time?
          field labels : Hash(String, String) = {} of String => String
          field annotations : Hash(String, String) = {} of String => String
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
    field template : Deployment::Spec::Template?
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

      alias Container = ::Kubernetes::Deployment::Spec::Template::Spec::Container

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
            field path_type : String
            field backend : Backend

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
  macro define_resource(name, group, type, version = "v1", prefix = "apis", api_version = nil, kind = nil, list_type = nil, singular_name = nil)
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
        namespace : String? = "default",
        # FIXME: Currently this is intended to be a string, but maybe we should
        # make it a Hash/NamedTuple?
        label_selector = nil,
      )
        namespace &&= "/namespaces/#{namespace}"
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
        namespace : String = resource.metadata.namespace,
        force : Bool = false,
        field_manager : String? = nil,
      )
        path = "/{{prefix.id}}/{{group.id}}/{{version.id}}/namespaces/#{namespace}/{{name.id}}/#{name}"
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
          spec: spec
        }

        if body = response.body
          {{type}}.from_json response.body
        else
          raise "Missing response body"
        end
      end

      def apply_{{singular_method_name.id}}(
        metadata : NamedTuple,
        spec,
        status = nil,
        api_version : String = "{{group.id}}/{{version.id}}",
        kind : String = "{{kind.id}}",
        force : Bool = false,
        field_manager : String? = nil,
      )
        name = metadata[:name]
        namespace = metadata[:namespace]
        path = "/{{prefix.id}}/{{group.id}}/{{version.id}}/namespaces/#{namespace}/{{name.id}}/#{name}"
        params = URI::Params{
          "force" => force.to_s,
          "fieldManager" => field_manager || "k8s-cr",
        }
        response = patch "#{path}?#{params}", {
          apiVersion: api_version,
          kind: kind,
          metadata: metadata,
          spec: spec,
        }

        if body = response.body
          # {{type}}.from_json response.body
          # JSON.parse body
          ({{type}} | Status).from_json body
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
        loop do
          params["resourceVersion"] = resource_version

          return get "/{{prefix.id}}/{{group.id}}/{{version.id}}#{namespace}/{{name.id}}?#{params}" do |response|
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
        rescue ex : JSON::ParseException
          @log.warn { "Cannot parse watched object: #{ex} (server may have closed the HTTP connection)" }
        end
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
end
