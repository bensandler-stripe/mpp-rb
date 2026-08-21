require "dotenv/load"
require "sinatra"
require "json"
require "mpp-rb"

RECIPIENT_ADDRESS = ENV.fetch("RECIPIENT_ADDRESS")
SECRET_KEY = ENV.fetch("SECRET_KEY")
STRIPE_SECRET_KEY = ENV.fetch("STRIPE_SECRET_KEY")
STRIPE_NETWORK_ID = ENV.fetch("STRIPE_NETWORK_ID")

tempo = Mpp::Methods::Tempo.tempo(
  chain_id: Mpp::Methods::Tempo::Defaults::TESTNET_CHAIN_ID,
  currency: Mpp::Methods::Tempo::Defaults::PATH_USD,
  recipient: RECIPIENT_ADDRESS,
  intents: {"charge" => Mpp::Methods::Tempo::ChargeIntent.new}
)

stripe = Mpp::Methods::Stripe.stripe(
  secret_key: STRIPE_SECRET_KEY,
  network_id: STRIPE_NETWORK_ID,
  currency: "usd",
  payment_methods: ["card", "link"]
)

server = Mpp.create(
  methods: [tempo, stripe],
  realm: "localhost:4567",
  secret_key: SECRET_KEY
)

paid = server.compose(
  [tempo, {amount: "0.01", description: "Paid endpoint"}],
  [stripe, {amount: "0.01", description: "Paid endpoint"}]
)

get "/free" do
  content_type :json
  JSON.generate({message: "This endpoint is free."})
end

get "/paid" do
  result = paid.call(
    authorization: env["HTTP_AUTHORIZATION"],
    accept_payment: env["HTTP_ACCEPT_PAYMENT"],
    url: request.url,
    http_method: request.request_method
  )

  if result.payment_required?
    resp = result.to_response
    status resp["status"]
    headers resp["headers"]
    body resp["body"]
    return
  end

  _credential, receipt = result.payment
  headers "Payment-Receipt" => receipt.to_payment_receipt
  content_type :json
  JSON.generate({message: "Payment received.", method: receipt.method})
end
