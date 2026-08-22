require "dotenv/load"
require "sinatra"
require "json"

PORT = Integer(ENV.fetch("PORT", "4570"))
TOKEN = ENV.fetch("FEE_PAYER_TOKEN", "test-fee-payer-token")

set :port, PORT
set :bind, ENV.fetch("BIND", "127.0.0.1")

configure do
  warn "Mock Tempo fee payer on http://#{settings.bind}:#{settings.port}"
  warn "  POST /  — JSON-RPC eth_signRawTransaction (Authorization: Bearer #{TOKEN})"
end

post "/" do
  unless request.env["HTTP_AUTHORIZATION"] == "Bearer #{TOKEN}"
    halt 401, JSON.generate({error: "unauthorized"})
  end

  body = JSON.parse(request.body.read)
  unless body["method"] == "eth_signRawTransaction"
    halt 200, JSON.generate({
      jsonrpc: "2.0",
      id: body["id"],
      error: {code: -32601, message: "Method not found"}
    })
  end

  raw_tx = body.dig("params", 0)
  content_type :json
  JSON.generate({jsonrpc: "2.0", id: body["id"], result: raw_tx})
end
