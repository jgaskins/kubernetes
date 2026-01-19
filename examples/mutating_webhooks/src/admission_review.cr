require "kubernetes"
require "json"
require "uuid/json"
require "uuid/yaml"

require "./base64_converter"
require "./json_patch"

struct AdmissionReview
  include Kubernetes::Serializable

  field api_version : String?
  field kind : String?
  field request : Request?
  field response : Response?

  def initialize(
    *,
    @api_version = "admission.k8s.io/v1",
    @kind = "AdmissionReview",
    @request = nil,
    @response = nil
  )
  end

  struct Request
    include Kubernetes::Serializable
    include JSON::Serializable::Unmapped

    field uid : UUID?

    # # Fully-qualified group/version/kind of the incoming object
    #   kind:
    #     group: autoscaling
    #     version: v1
    #     kind: Scale
    field kind : Kind?

    struct Kind
      include Kubernetes::Serializable
      field group : String?
      field version : String?
      field kind : String?
    end

    #   # Fully-qualified group/version/kind of the resource being modified
    #   resource:
    #     group: apps
    #     version: v1
    #     resource: deployments
    field resource : Resource?

    struct Resource
      include Kubernetes::Serializable

      field group : String?
      field version : String?
      field resource : String?
    end

    #   # subresource, if the request is to a subresource
    #   subResource: scale
    field sub_resource : String?

    #   # Fully-qualified group/version/kind of the incoming object in the original request to the API server.
    #   # This only differs from `kind` if the webhook specified `matchPolicy: Equivalent` and the
    #   # original request to the API server was converted to a version the webhook registered for.
    #   requestKind:
    #     group: autoscaling
    #     version: v1
    #     kind: Scale
    field request_kind : Kind?

    #   # Fully-qualified group/version/kind of the resource being modified in the original request to the API server.
    #   # This only differs from `resource` if the webhook specified `matchPolicy: Equivalent` and the
    #   # original request to the API server was converted to a version the webhook registered for.
    #   requestResource:
    #     group: apps
    #     version: v1
    #     resource: deployments
    field request_resource : Resource?

    #   # subresource, if the request is to a subresource
    #   # This only differs from `subResource` if the webhook specified `matchPolicy: Equivalent` and the
    #   # original request to the API server was converted to a version the webhook registered for.
    #   requestSubResource: scale
    field request_sub_resource : String?

    #   # Name of the resource being modified
    #   name: my-deployment
    field name : String?

    #   # Namespace of the resource being modified, if the resource is namespaced (or is a Namespace object)
    #   namespace: my-namespace
    field namespace : String?

    #   # operation can be CREATE, UPDATE, DELETE, or CONNECT
    #   operation: UPDATE
    field operation : Operation?
    enum Operation
      CREATE
      UPDATE
      DELETE
      CONNECT
    end

    #   userInfo:
    field user_info : UserInfo?

    struct UserInfo
      include Kubernetes::Serializable
      #     # Username of the authenticated user making the request to the API server
      #     username: admin
      field username : String?
      #     # UID of the authenticated user making the request to the API server
      #     uid: 014fbff9a07c
      field uid : String?
      #     # Group memberships of the authenticated user making the request to the API server
      #     groups:
      #       - system:authenticated
      #       - my-admin-group
      field groups : Array(String) { [] of String }
      #     # Arbitrary extra info associated with the user making the request to the API server.
      #     # This is populated by the API server authentication layer and should be included
      #     # if any SubjectAccessReview checks are performed by the webhook.
      #     extra:
      #       some-key:
      #         - some-value1
      #         - some-value2
      field extra : Hash(String, JSON::Any) { {} of String => JSON::Any }
    end

    #   # object is the new object being admitted.
    #   # It is null for DELETE operations.
    #   object:
    #     apiVersion: autoscaling/v1
    #     kind: Scale
    field object : ObjectReference?

    struct ObjectReference
      include Kubernetes::Serializable
      field api_version : String?
      field kind : String?
    end

    #   # oldObject is the existing object.
    #   # It is null for CREATE and CONNECT operations.
    #   oldObject:
    #     apiVersion: autoscaling/v1
    #     kind: Scale
    field old_object : ObjectReference?

    #   # options contains the options for the operation being admitted, like meta.k8s.io/v1 CreateOptions, UpdateOptions, or DeleteOptions.
    #   # It is null for CONNECT operations.
    #   options:
    #     apiVersion: meta.k8s.io/v1
    #     kind: UpdateOptions
    field options : Options?

    struct Options
      include Kubernetes::Serializable

      field api_version : String?
      field kind : Kind?

      enum Kind
        CreateOptions
        UpdateOptions
        DeleteOptions
      end
    end

    #   # dryRun indicates the API request is running in dry run mode and will not be persisted.
    #   # Webhooks with side effects should avoid actuating those side effects when dryRun is true.
    #   # See http://k8s.io/docs/reference/using-api/api-concepts/#make-a-dry-run-request for more details.
    #   dryRun: False
    field? dry_run : Bool = false
  end

  struct Response
    include Kubernetes::Serializable
    field uid : UUID?
    field? allowed : Bool
    field patch_type : PatchType? = nil
    field patch : Array(JSONPatch), converter: Base64Converter(Array(JSONPatch)) do
      [] of JSONPatch
    end

    def initialize(*, @uid, @allowed, @patch_type = nil, @patch = nil)
    end

    enum PatchType
      JSONPatch

      def to_json(json)
        to_s.to_json json
      end
    end
  end
end
