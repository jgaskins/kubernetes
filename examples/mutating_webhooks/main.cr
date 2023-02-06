require "log"

require "./json_patch"

Log.setup_from_env

log = Log.for("app")
app = App.new(log)

http = HTTP::Server.new([
  HTTP::LogHandler.new,
  HTTP::CompressHandler.new,
  app,
])
Signal::TERM.trap { http.close }
port = ENV.fetch("PORT", "3000").to_i

tls = OpenSSL::SSL::Context::Server.new
tls.ca_certificates = "/certs/ca.crt"
tls.certificate_chain = "/certs/tls.crt"
tls.private_key = "/certs/tls.key"

http.bind_tls "0.0.0.0", port, context: tls
log.info { "Listening on port #{port}..." }
http.listen

while app.handling_requests?
  sleep 1.second
end

require "./admission_review"

class App
  include HTTP::Handler

  getter log : Log
  @handling_requests = Atomic(Int64).new(0)

  def initialize(@log)
  end

  def call(context)
    @handling_requests.add 1
    response = context.response
    response.content_type = "application/json"

    if body = context.request.body
      review = AdmissionReview.from_json(body)
      @log.debug { review.to_json }
      if request = review.request
        response_review = AdmissionReview.new(
          api_version: review.api_version,
          kind: review.kind,
          response: AdmissionReview::Response.new(
            uid: request.uid,
            patch_type: :json_patch,
            patch: [
              JSONPatch.new(
                op: :add,
                path: "/spec/nodeSelector",
                value: {} of String => JSON::Any,
              ),
              JSONPatch.new(
                op: :add,
                path: "/spec/nodeSelector/kubernetes.io~1arch",
                value: "arm64",
              ),
            ],
            allowed: true,
          ),
        )

        log.debug { response_review.to_json }

        response_review.to_json response
      else
        response.status = :bad_request
        {error: "AdmissionReview must contain a request"}.to_json response
      end
    else
      response.status = :bad_request
      {error: "Must provide a request body"}.to_json response
    end
  rescue ex : JSON::ParseException
    context.response.status = :unprocessable_entity
    {error: "Cannot parse AdmissionReview"}.to_json context.response
  ensure
    @handling_requests.sub 1
  end

  def handling_requests?
    @handling_requests.get > 0
  end
end
