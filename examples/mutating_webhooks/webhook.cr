require "http"
require "json"

require "./admission_review"
require "./json_patch"

class WebhookHandler
  include HTTP::Handler

  @log : Log
  @handling_requests = Atomic(Int64).new(0)

  def initialize(@log)
  end

  # Modify this method to change the response we want to return
  def response_for(request)
    AdmissionReview::Response.new(
      # This must be the uid of the request according to the K8s docs.
      uid: request.uid,
      # This corresponds to JSONPatch::Operation in json_patch.cr
      patch_type: :json_patch,
      patch: [
        # JSONPatch doesn't recursively add keys, so we need to make sure the
        # nodeSelector object exists before we try to add keys to it.
        JSONPatch.new(
          op: :add,
          path: "/spec/nodeSelector",
          value: {} of String => JSON::Any,
        ),
        # Now that we know the nodeSelector exists, we can add the key to it.
        JSONPatch.new(
          op: :add,
          # Tildes and slashes have surprising escape requirements in JSONPatch
          path: "/spec/nodeSelector/kubernetes.io~1arch",
          value: "arm64",
        ),
      ],
      # If you want to reject the pod (or changes to it), set this to false.
      allowed: true,
    )
  end

  def call(context)
    @handling_requests.add 1
    response = context.response
    response.content_type = "application/json"

    if body = context.request.body
      begin
        review = AdmissionReview.from_json(body)
      rescue ex : JSON::ParseException
        # If we can't parse an AdmissionReview object, bail out
        context.response.status = :unprocessable_entity
        {error: "Cannot parse AdmissionReview"}.to_json context.response
        return
      end

      @log.debug { review.to_json }
      if request = review.request
        admission_response = response_for(request)
        response_review = AdmissionReview.new(
          api_version: review.api_version,
          kind: review.kind,
          response: admission_response,
        )

        @log.debug { response_review.to_json }
        response_review.to_json response
      else
        response.status = :bad_request
        {error: "AdmissionReview must contain a request"}.to_json response
      end
    else
      response.status = :bad_request
      {error: "Must provide a request body"}.to_json response
    end
  ensure
    @handling_requests.sub 1
  end

  def handling_requests?
    @handling_requests.get > 0
  end
end
