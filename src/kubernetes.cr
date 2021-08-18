require "http"
require "json"
require "yaml"
require "uuid"
require "uuid/json"
require "db/pool"

require "./serializable"

module Kubernetes
  VERSION = "0.1.0"

  class Client
    def initialize(@server : URI, @token : String, @certificate_file : String)
      tls = OpenSSL::SSL::Context::Client.new
      tls.ca_certificates = @certificate_file
      @headers = HTTP::Headers{"Authorization" => "Bearer #{token}"}

      @http_pool = DB::Pool(HTTP::Client).new do
        HTTP::Client.new(server, tls: tls)
      end
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

    field name : String = ""
    field namespace : String = ""
    field labels : Hash(String, String) = {} of String => String
    field annotations : Hash(String, String) = {} of String => String
    field resource_version : String = ""
    field uid : UUID = UUID.empty

    def initialize(@name, @namespace = nil, @labels = {} of String => String, @annotations = {} of String => String)
    end
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
        field target_port : Int32?
      end
    end
  end

  struct Pod
    include Serializable

    field spec : Spec

    struct Spec
      include Serializable

      # fi
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
      field updated_replicas : Int32 =  -1
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

        field metadata : Metadata
        field spec : Spec

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
      field generate_name : String
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
        field block_owner_deletion : Bool
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

    field type : String
    field object : T

    def added?
      type == "ADDED"
    end

    def modified?
      type == "MODIFIED"
    end

    def deleted?
      type == "DELETED"
    end
  end

  struct Status
    include Serializable

    field kind : String
    field api_version : String
    field metadata : JSON::Any
    field status : String
    field message : String
    field reason : String
    field details : Details
    field code : Int32

    struct Details
      include Serializable

      field name : String
      field group : String
      field kind : String
    end
  end

  # Define a new Kubernetes resource type. This can be used to specify your CRDs
  # to be able to manage your custom resources in Crystal code.
  macro define_resource(name, group, type, version = "v1", prefix = "apis", list_type = nil, singular_name = nil)
    {% singular_name ||= name.gsub(/s$/, "").id %}

    class ::Kubernetes::Client
      def {{name.id}}(namespace : String? = "default")
        namespace &&= "/namespaces/#{namespace}"
        path = "/{{prefix.id}}/{{group.id}}/{{version.id}}#{namespace}/{{name.id}}" 
        get path do |response|
          # response.body_io.gets_to_end
          # JSON.parse response.body_io
          {% if list_type %}
            {{list_type}}.from_json response.body_io
          {% else %}
            ::Kubernetes::List({{type}}).from_json response.body_io
          {% end %}
        end
      end

      def {{singular_name.id}}(name : String, namespace : String = "default")
        if namespace
          namespace = "/namespaces/#{namespace}"
        end

        path = "/{{prefix.id}}/{{group.id}}/{{version.id}}#{namespace}/{{name.id}}/#{name}" 
        get path do |response|
          case value = ({{type}} | Status).from_json response.body_io
          when Status
            nil
          else
            value
          end
        end
      end

      def apply_{{singular_name.id}}(resource : {{type}}, spec, name : String = resource.metadata.name, namespace : String = resource.metadata.namespace, force : Bool = false)
        path = "/{{prefix.id}}/{{group.id}}/{{version.id}}/namespaces/#{namespace}/{{name.id}}/#{name}?fieldManager=k8s-cr&force=#{force}"
        metadata = {
          name: name,
          namespace: namespace,
        }
        if resource_version = resource.metadata.resource_version.presence
          metadata = metadata.merge(resourceVersion: resource_version)
        end

        response = patch path, {
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

      def apply_{{singular_name.id}}(api_version : String, kind : String, metadata : NamedTuple, spec, force : Bool = false)
        name = metadata[:name]
        namespace = metadata[:namespace]
        path = "/{{prefix.id}}/{{group.id}}/{{version.id}}/namespaces/#{namespace}/{{name.id}}/#{name}?fieldManager=k8s-cr&force=#{force}"
        response = patch path, {
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

      def delete_{{singular_name.id}}(name : String, namespace : String = "default")
        path = "/{{prefix.id}}/{{group.id}}/{{version.id}}/namespaces/#{namespace}/{{name.id}}/#{name}"
        response = delete path
        JSON.parse response.body
      end

      def watch_{{name.id}}(resource_version = "0")
        get "/{{prefix.id}}/{{group.id}}/{{version.id}}/{{name.id}}?resourceVersion=#{resource_version}&watch=1" do |response|
          loop do
            yield Watch({{type}}).from_json IO::Delimited.new(response.body_io, "\n")
          end
        end
      end
    end
  end

  macro import_crd(yaml_file)
    {{ run("./import_crd", yaml_file) }}
  end

  define_resource "deployments",
    group: "apps",
    type: Deployment

  define_resource "statefulsets",
    group: "apps",
    type: Resource(StatefulSet)

  define_resource "jobs",
    group: "batch",
    type: Resource(JSON::Any) # TODO: Write Job struct

  define_resource "services",
    group: "",
    type: Service,
    prefix: "api"

  define_resource "ingresses",
    singular_name: "ingress",
    group: "networking.k8s.io",
    type: Resource(Networking::Ingress)

  define_resource "pods",
    group: "",
    type: Pod,
    prefix: "api"
end

