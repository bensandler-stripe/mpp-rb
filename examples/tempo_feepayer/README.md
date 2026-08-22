# Tempo hosted fee payer example

Gate an endpoint behind a Tempo charge whose gas is sponsored by a remote fee-payer service. The server advertises `feePayer: true` and co-signs pull credentials at `FEE_PAYER_URL`, sending the same `{url:, headers:}` config used for x402 facilitators.

## Setup

```sh
cd examples/tempo_feepayer
bundle install
cp .env.template .env
# Edit .env and fill in your values
bundle exec ruby app.rb
```

To try the config against a local mock sponsor (echoes `eth_signRawTransaction`):

```sh
FEE_PAYER_TOKEN=test-fee-payer-token bundle exec ruby mock_sponsor.rb
# in another terminal:
FEE_PAYER_URL=http://127.0.0.1:4570 FEE_PAYER_TOKEN=test-fee-payer-token bundle exec ruby app.rb
```

The paid API starts on `http://localhost:4567`. Broadcast still uses `TEMPO_RPC_URL` (Moderato by default).

## Endpoints

| Endpoint | Price |
|----------|-------|
| `GET /free` | Free |
| `GET /paid` | $0.01, sponsored |

## Testing with mppx

```sh
npx mppx http://localhost:4567/paid
```
