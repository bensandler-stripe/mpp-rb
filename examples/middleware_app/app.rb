# typed: false
require "dotenv/load"
require "sinatra/base"
require "json"
require "mpp-rb"

STRIPE_SECRET_KEY = ENV.fetch("STRIPE_SECRET_KEY")
STRIPE_NETWORK_ID = ENV.fetch("STRIPE_NETWORK_ID")
SECRET_KEY = ENV.fetch("SECRET_KEY")

handler = Mpp.create(
  method: Mpp::Methods::Stripe.stripe(
    secret_key: STRIPE_SECRET_KEY,
    network_id: STRIPE_NETWORK_ID,
    currency: "usd",
    payment_methods: ["card", "link"]
  ),
  realm: "localhost:9292",
  secret_key: SECRET_KEY
)

# The pricing proc determines cost per request. It receives the Rack env
# and returns a charge options hash, or nil for free endpoints.
# This runs BEFORE the app — no side effects allowed here.
pricing = lambda do |env|
  case env["PATH_INFO"]
  when "/paid"
    {amount: "0.10", description: "Paid endpoint"}
  when "/expensive"
    {amount: "1.00", description: "Premium endpoint"}
  end
end

class App < Sinatra::Base
  get "/free" do
    content_type :json
    JSON.generate({message: "This endpoint is free — no payment required."})
  end

  get "/paid" do
    content_type :json
    JSON.generate({message: "Payment verified. Here is your paid content."})
  end

  get "/expensive" do
    content_type :json
    JSON.generate({message: "Payment verified. Here is your premium content."})
  end
end

App.use Mpp::Server::Middleware, handler: handler, pricing: pricing
