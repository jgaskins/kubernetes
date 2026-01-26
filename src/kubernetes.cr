require "http"
require "json"
require "yaml"
require "uuid"
require "uuid/json"
require "uuid/yaml"
require "uri/yaml"
require "db/pool"

require "./serializable"
require "./token_file_watcher"

module Kubernetes
  VERSION = "0.1.0"

  class Client
    @http_pool : DB::Pool(HTTP::Client)
    @on_close_callbacks : Array(->)

    def self.from_config(*, file : String = "#{ENV["HOME"]?}/.kube/config", context context_name : String? = nil)
      config = File.open(file) { |f| Config.from_yaml f }

      from_config(
        config: config,
        context: context_name || config.current_context,
      )
    end

    def self.from_config(config : Config, *, context context_name : String = config.current_context)
      context_entry = config.contexts.find { |c| c.name == context_name }
      if !context_entry
        raise ArgumentError.new("No context #{context_name.inspect} found in Kubernetes config")
      end

      cluster_entry = config.clusters.find { |c| c.name == context_entry.context.cluster }
      if !cluster_entry
        raise ArgumentError.new("No cluster #{context_entry.context.cluster.inspect} found in Kubernetes config")
      end

      user_entry = config.users.find { |u| u.name == context_entry.context.user }
      if !user_entry
        raise ArgumentError.new("No user #{context_entry.context.user.inspect} found in Kubernetes config")
      end

      file = File.tempfile prefix: "kubernetes", suffix: ".crt" do |tempfile|
        Base64.decode cluster_entry.cluster.certificate_authority_data, tempfile
      end
      at_exit { file.delete }

      user = user_entry.user

      if (cert = user.client_certificate_data) && (key = user.client_key_data)
        client_cert_file = File.tempfile prefix: "kubernetes", suffix: ".crt" do |tempfile|
          Base64.decode cert, tempfile
        end
        private_key_file = File.tempfile prefix: "kubernetes", suffix: ".crt" do |tempfile|
          Base64.decode key, tempfile
        end
        at_exit { client_cert_file.delete; private_key_file.delete }

        new(
          token: -> { "" },
          server: cluster_entry.cluster.server,
          certificate_file: file.path,
          client_cert_file: client_cert_file.path,
          private_key_file: private_key_file.path,
        )
      elsif (token = user.token_data)
        new(
          server: cluster_entry.cluster.server,
          certificate_file: file.path,
          token: -> { token },
        )
      else
        new(
          server: cluster_entry.cluster.server,
          certificate_file: file.path,
          token: -> { user_entry.user.credential.try &.status.token || "" },
        )
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

    # Constructor that accepts a token file path and creates a proc to read it.
    # On Linux, uses TokenFileWatcher with inotify for efficient token rotation detection.
    # On other platforms, reads the file on each request.
    {% if flag?(:linux) %}
      def self.new(
        server : URI,
        token_file : Path,
        certificate_file : String = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt",
        client_cert_file : String? = nil,
        private_key_file : String? = nil,
        log = Log.for("kubernetes.client"),
      )
        watcher = TokenFileWatcher.new(token_file, log: Log.for("kubernetes.token_watcher"))
        token_proc = -> { watcher.token }

        client = new(
          server: server,
          token: token_proc,
          certificate_file: certificate_file,
          client_cert_file: client_cert_file,
          private_key_file: private_key_file,
          log: log,
        )

        client.on_close { watcher.close }
        client
      end
    {% else %}
      def self.new(
        server : URI,
        token_file : Path,
        certificate_file : String = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt",
        client_cert_file : String? = nil,
        private_key_file : String? = nil,
        log = Log.for("kubernetes.client"),
      )
        token_proc = -> { File.read(token_file.to_s).strip }

        new(
          server: server,
          token: token_proc,
          certificate_file: certificate_file,
          client_cert_file: client_cert_file,
          private_key_file: private_key_file,
          log: log,
        )
      end
    {% end %}

    def self.new(
      server : URI,
      token : Proc(String) = -> { File.read("/var/run/secrets/kubernetes.io/serviceaccount/token").strip },
      certificate_file : String = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt",
      client_cert_file : String? = nil,
      private_key_file : String? = nil,
      log = Log.for("kubernetes.client"),
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
      @token : Proc(String) = -> { File.read("/var/run/secrets/kubernetes.io/serviceaccount/token").strip },
      @tls : OpenSSL::SSL::Context::Client?,
      @log = Log.for("kubernetes.client"),
    )
      @on_close_callbacks = [] of ->
      @http_pool = DB::Pool(HTTP::Client).new do
        http = HTTP::Client.new(@server, tls: @tls)
        http.before_request do |request|
          token_value = @token.call
          if token_value.presence
            request.headers["Authorization"] = "Bearer #{token_value}"
          end
        end
        http
      end
    end

    # Register a callback to be invoked when the client is closed.
    # Used for cleanup of resources like TokenFileWatcher.
    def on_close(&block : ->) : Nil
      @on_close_callbacks << block
    end

    def close : Nil
      @on_close_callbacks.each(&.call)
      @on_close_callbacks.clear
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

    def get(path : String, headers = HTTP::Headers.new, &)
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

    protected def parse_response(response, type : T.class) : T? forall T
      parse_response!(response, type)
    rescue err : ClientError
      nil
    end

    protected def parse_response!(response, type : T.class) : T forall T
      case response
      when .success?
        type.from_json(response.body_io)
      else
        status = Status.from_json(response.body_io) rescue nil
        case response.status
        when .not_found?
          raise ClientError.new("API resource not found", status, response)
        else
          raise ClientError.new("K8s API returned status code #{response.status_code}", status, response)
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

  enum PropagationPolicy
    Background
    Foreground
    Orphan
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
    field storage_version_hash : String?

    def initialize(
      *,
      @name,
      @singular_name,
      @namespaced,
      @kind,
      @verbs,
      @short_names = nil,
      @storage_version_hash = nil,
    )
    end

    struct List
      include Serializable

      field api_version : String?
      field kind : String = "APIResourceList"
      field group_version : String
      field resources : Array(APIResource)

      def initialize(*, @api_version, @group_version, @resources)
      end
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
          {% if list_type %}
            parse_response!(response, {{list_type}}).not_nil!
          {% else %}
            parse_response!(response, ::Kubernetes::List({{type}})).not_nil!
          {% end %}
        rescue err : ClientError
          if err.status_code == 404
            raise ClientError.new("API resource \"{{name.id}}\" not found. Did you apply the CRD to the Kubernetes control plane?", err.status, response)
          else
            raise err
          end
        end
      end

      def {{singular_method_name.id}}(
        name : String,
        {% if cluster_wide == false %}
          namespace : String = "default",
        {% end %}
        resource_version : String = ""
      )
        {% if cluster_wide == false %}
          namespace &&= "/namespaces/#{namespace}"
        {% else %}
          namespace = nil
        {% end %}

        path = "/{{prefix.id}}/{{group.id}}/{{version.id}}#{namespace}/{{name.id}}/#{name}"
        params = URI::Params{
          "resourceVersion" => resource_version,
        }

        get "#{path}?#{params}" do |response|
          parse_response(response)
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

        parse_response(response)
      end

      def patch_{{singular_method_name.id}}(name : String, {% if cluster_wide == false %}namespace, {% end %}**kwargs)
        path = "/{{prefix.id}}/{{group.id}}/{{version.id}}{% if cluster_wide == false %}/namespaces/#{namespace}{% end %}/{{name.id}}/#{name}"
        headers = HTTP::Headers{
          "Content-Type" =>  "application/merge-patch+json",
        }

        response = raw_patch path, kwargs.to_json, headers: headers
        parse_response(response)
      end

      def patch_{{singular_method_name.id}}_subresource(name : String, subresource : String{% if cluster_wide == false %}, namespace : String = "default"{% end %}, **args)
        path = "/{{prefix.id}}/{{group.id}}/{{version.id}}{% if cluster_wide == false %}/namespaces/#{namespace}{% end %}/{{name.id}}/#{name}/#{subresource}"
        headers = HTTP::Headers{
          "Content-Type" =>  "application/merge-patch+json",
        }

        response = raw_patch path, {subresource => args}.to_json, headers: headers
        parse_response(response)
      end

      def delete_{{singular_method_name.id}}(resource : {{type}})
        delete_{{singular_method_name.id}} name: resource.metadata.name, namespace: resource.metadata.namespace
      end

      def delete_{{singular_method_name.id}}(name : String{% if cluster_wide == false %}, namespace : String = "default"{% end %}, *, propagation_policy : PropagationPolicy = :background)
        params = URI::Params{"propagationPolicy" => propagation_policy.to_s}
        path = "/{{prefix.id}}/{{group.id}}/{{version.id}}{% if cluster_wide == false %}/namespaces/#{namespace}{% end %}/{{name.id}}/#{name}?#{params}"
        response = delete path
        JSON.parse response.body
      end

      def watch_{{plural_method_name.id}}(resource_version = "0", timeout : Time::Span = 10.minutes, namespace : String? = nil, labels label_selector : String = "")
        params = URI::Params{
          "watch" => "1",
          "timeoutSeconds" => timeout.total_seconds.to_i64.to_s,
          "labelSelector" => label_selector,
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

              raise ClientError.new("#{response.status}: #{message}", nil, response)
            end

            loop do
              json_string = response.body_io.read_line

              parser = JSON::PullParser.new(json_string)
              kind = parser.on_key!("object") do
                parser.on_key!("kind") do
                  parser.read_string
                end
              end

              if kind == "Status"
                watch = Watch(Status).from_json(json_string)
                obj = watch.object

                if match = obj.message.match /too old resource version: \d+ \((\d+)\)/
                  resource_version = match[1]
                end
                # If this is an error of some kind, we don't care we'll just run
                # another request starting from the last resource version we've
                # worked with.
                next
              end

              watch = Watch({{type}}).from_json(json_string)

              # If there's a JSON parsing failure and we loop back around, we'll
              # use this resource version to pick up where we left off.
              if new_version = watch.object.metadata.resource_version.presence
                resource_version = new_version
              end

              yield watch
            end
          end
        rescue ex : IO::EOFError
          # Server closed the connection after the timeout
        rescue ex : IO::Error
          @log.warn { ex }
          sleep 1.second # Don't hammer the server
        rescue ex : JSON::ParseException
          # This happens when the watch request times out. This is expected and
          # not an error, so we just ignore it.
          unless ex.message.try &.includes? "Expected BeginObject but was EOF at line 1, column 1"
            @log.warn { "Cannot parse watched object: #{ex}" }
          end
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
    getter :status, :raw_response

    def initialize(message : String, @status : Status | Nil, @raw_response : HTTP::Client::Response)
      super(message)
    end

    def status_code
      @raw_response.try(&.status_code)
    end
  end

  class UnexpectedResponse < Error
  end

  struct Config
    include Serializable

    field api_version : String
    field kind : String
    field clusters : Array(ClusterEntry)
    field contexts : Array(ContextEntry)
    field current_context : String,
      key: "current-context"
    field preferences : Hash(String, YAML::Any)?
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

        field client_certificate_data : String?, key: "client-certificate-data"
        field client_key_data : String?, key: "client-key-data"
        field token_data : String?, key: "token"

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

require "./types/**"
