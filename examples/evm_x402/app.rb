require "dotenv/load"
require "sinatra"
require "json"
require "mpp-rb"

RECIPIENT_ADDRESS = ENV.fetch("RECIPIENT_ADDRESS")
SECRET_KEY = ENV.fetch("SECRET_KEY")
FACILITATOR_URL = ENV.fetch("X402_FACILITATOR_URL", "https://x402.org/facilitator")

evm = Mpp::Methods::Evm.charge(
  currency: Mpp::Methods::Evm::Assets::BASE_SEPOLIA_USDC,
  recipient: RECIPIENT_ADDRESS,
  x402: {facilitator: FACILITATOR_URL}
)

server = Mpp.create(
  methods: [evm],
  realm: "localhost:4567",
  secret_key: SECRET_KEY
)

get "/free" do
  content_type :json
  JSON.generate({message: "This endpoint is free."})
end

get "/paid" do
  result = server.charge(
    env["HTTP_AUTHORIZATION"],
    "0.01",
    description: "Paid endpoint",
    payment_signature: env["HTTP_PAYMENT_SIGNATURE"],
    url: request.url,
    http_method: request.request_method
  )

  if result.is_a?(Mpp::Challenge)
    resp = server.challenge_response(result, url: request.url, http_method: request.request_method)
    status resp["status"]
    headers resp["headers"]
    body resp["body"]
    return
  end

  credential, receipt = result
  extra = {"Payment-Receipt" => receipt.to_payment_receipt}
  evm.decorate_receipt(extra, receipt, credential, payment_signature: env["HTTP_PAYMENT_SIGNATURE"])
  extra.each { |key, value| headers[key] = value }
  content_type :json
  JSON.generate({message: "Payment received.", reference: receipt.reference})
end
