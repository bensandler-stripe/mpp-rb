require "dotenv/load"
require "sinatra"
require "json"
require "mpp-rb"

PORT = Integer(ENV.fetch("PORT", "4567"))
set :port, PORT
set :bind, ENV.fetch("BIND", "127.0.0.1")

TEMPO_DEPOSIT_ADDRESS = ENV.fetch("TEMPO_DEPOSIT_ADDRESS")
BASE_DEPOSIT_ADDRESS = ENV.fetch("BASE_DEPOSIT_ADDRESS")
SECRET_KEY = ENV.fetch("SECRET_KEY")
STRIPE_SECRET_KEY = ENV.fetch("STRIPE_SECRET_KEY")
STRIPE_NETWORK_ID = ENV.fetch("STRIPE_NETWORK_ID")
FACILITATOR_URL = ENV.fetch("X402_FACILITATOR_URL", "https://x402.org/facilitator")
AMOUNT = ENV.fetch("AMOUNT", "0.01")

tempo = Mpp::Methods::Tempo.tempo(
  chain_id: Mpp::Methods::Tempo::Defaults::TESTNET_CHAIN_ID,
  currency: Mpp::Methods::Tempo::Defaults::PATH_USD,
  recipient: TEMPO_DEPOSIT_ADDRESS,
  intents: {"charge" => Mpp::Methods::Tempo::ChargeIntent.new}
)

evm = Mpp::Methods::Evm.charge(
  currency: Mpp::Methods::Evm::Assets::BASE_USDC,
  recipient: BASE_DEPOSIT_ADDRESS,
  x402: {facilitator: FACILITATOR_URL}
)

stripe = Mpp::Methods::Stripe.stripe(
  secret_key: STRIPE_SECRET_KEY,
  network_id: STRIPE_NETWORK_ID,
  currency: "usd",
  payment_methods: ["card", "link"]
)

server = Mpp.create(
  methods: [tempo, evm, stripe],
  realm: ENV.fetch("MPP_REALM", "localhost:#{PORT}"),
  secret_key: SECRET_KEY
)

paid = server.compose(
  [tempo, {amount: AMOUNT, description: "Paid endpoint"}],
  [evm, {amount: AMOUNT, description: "Paid endpoint"}],
  [stripe, {amount: AMOUNT, description: "Paid endpoint"}]
)

configure do
  warn "Compose example on http://#{settings.bind}:#{settings.port}"
  warn "  GET /free  — no payment"
  warn "  GET /paid  — #{AMOUNT} via tempo, evm (Base USDC + x402), or stripe SPT"
end

get "/" do
  content_type :json
  JSON.generate({
    endpoints: {
      "/free" => "no payment",
      "/paid" => "#{AMOUNT} via tempo, evm (Base USDC), or stripe SPT"
    }
  })
end

get "/free" do
  content_type :json
  JSON.generate({message: "This endpoint is free."})
end

get "/paid" do
  result = paid.call(
    authorization: env["HTTP_AUTHORIZATION"],
    payment_signature: env["HTTP_PAYMENT_SIGNATURE"],
    accept_payment: env["HTTP_ACCEPT_PAYMENT"],
    url: request.url,
    http_method: request.request_method
  )

  if result.payment_required?
    resp = result.to_response
    halt [resp["status"], resp["headers"], [resp["body"]]]
  end

  _credential, receipt = result.payment
  headers "Payment-Receipt" => receipt.to_payment_receipt
  result.extra_headers.each { |key, value| headers[key] = value unless value.nil? }
  content_type :json
  JSON.generate({message: "Payment received.", method: receipt.method})
end
