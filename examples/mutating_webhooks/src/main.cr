require "openssl"
require "http"
require "log"

require "./webhook"

Log.setup_from_env

log = Log.for("app")
app = WebhookHandler.new(log)

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

# Allow any in-flight requests to finish up before exiting
while app.handling_requests?
  sleep 1.second
end
