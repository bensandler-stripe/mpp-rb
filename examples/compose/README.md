# Compose Example

A runnable Sinatra app that presents **Tempo**, **EVM USDC on Base**, and **Stripe Shared Payment Tokens** on a single `/paid` endpoint via `server.compose`.

Unauthenticated `GET /paid` returns three `WWW-Authenticate: Payment` challenges plus `PAYMENT-REQUIRED` (x402 exact for the EVM offer). The client pays with whichever method it supports: `Authorization: Payment` (Tempo, Stripe SPT, native EVM) or `PAYMENT-SIGNATURE` (x402 exact via the facilitator).

## Setup

```sh
cd examples/compose
bundle install
cp .env.template .env
```

Fill in `.env`:

| Variable | Purpose |
|----------|---------|
| `SECRET_KEY` | HMAC key for challenge ids (`openssl rand -hex 32`) |
| `TEMPO_DEPOSIT_ADDRESS` | `0x` recipient for Tempo testnet |
| `BASE_DEPOSIT_ADDRESS` | `0x` recipient for Base USDC |
| `STRIPE_SECRET_KEY` | Stripe secret key for SPT settlement |
| `STRIPE_NETWORK_ID` | Stripe Business Network id |
| `X402_FACILITATOR_URL` | x402 facilitator (defaults to `https://x402.org/facilitator`) |

Then:

```sh
bundle exec ruby app.rb
```

The server starts on `http://localhost:4567`. Issuing the three challenges does not need the `eth` gem. Settling an EVM payment does (EIP-3009 recovery). If you add `gem "eth"` and `bundle install` fails on `rbsecp256k1` / `aclocal`, install autotools first:

```sh
brew install autoconf automake libtool
```

## Endpoints

| Endpoint | Price |
|----------|-------|
| `GET /` | Free (lists routes) |
| `GET /free` | Free |
| `GET /paid` | $0.01 — Tempo **or** Base USDC **or** Stripe SPT |

## Inspect the composed 402

```sh
curl -i http://localhost:4567/paid
```

You should see three `WWW-Authenticate: Payment` challenges (`tempo/charge`, `evm/charge`, `stripe/charge`) and a `PAYMENT-REQUIRED` header from `evm.charge`. Rank methods with `Accept-Payment`:

```sh
curl -i -H 'Accept-Payment: stripe/charge, tempo/charge;q=0.5' http://localhost:4567/paid
```

## Pay with mppx

```sh
npx mppx http://localhost:4567/paid
```

`mppx` sends `Accept-Payment` and retries with a credential for a method it can fulfill. x402 exact clients read `PAYMENT-REQUIRED` and retry with `PAYMENT-SIGNATURE`; settlement goes through `X402_FACILITATOR_URL`.
