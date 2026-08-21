# Compose Example

Present Tempo and Stripe payment options on a single `/paid` endpoint using `server.compose`.

## Setup

```sh
cd examples/compose
bundle install
cp ../tempo_charge/.env.template .env 2>/dev/null || true
# Set RECIPIENT_ADDRESS, SECRET_KEY, STRIPE_SECRET_KEY, and STRIPE_NETWORK_ID
bundle exec ruby app.rb
```

The server starts on `http://localhost:4567`.

## Endpoints

| Endpoint | Price |
|----------|-------|
| `GET /free` | Free |
| `GET /paid` | $0.01 (Tempo or Stripe) |

A 402 response includes two `WWW-Authenticate: Payment` challenges. The client picks the method it supports.

## Testing with mppx

```sh
npx mppx http://localhost:4567/paid
```

`mppx` sends `Accept-Payment` and pays with whichever configured method matches. To inspect the merged challenge:

```sh
curl -i http://localhost:4567/paid
```
