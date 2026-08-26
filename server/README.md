# Zeolite Notion Auth

> If this service is down, Zeolite works exactly as it always does and nothing
> is lost — only syncing pauses, and it resumes on its own.

This standalone service completes the secret-bearing steps of Zeolite's Notion OAuth handshake. The Notion client secret stays on the server and never ships inside the mobile app.

| Route | Purpose |
| --- | --- |
| `GET /notion/start` | Starts authorization using the app's verifier challenge. |
| `GET /notion/callback` | Exchanges Notion's authorization code and returns to the app. |
| `POST /notion/claim` | Releases the token payload after verifier proof. |
| `POST /notion/refresh` | Exchanges a refresh token for a fresh token payload. |

## Environment variables

- `NOTION_CLIENT_ID` — required Notion OAuth client ID
- `NOTION_CLIENT_SECRET` — required Notion OAuth client secret
- `REDIRECT_URI` — required callback URL configured in Notion
- `PORT` — optional server port, default `8080`
- `APP_SCHEME` — optional mobile URL scheme, default `zeolite`
- `TRUST_PROXY` — number of proxies in front of the service, default `0`. Set
  it to `1` behind a single load balancer, or rate limiting counts every
  caller as the balancer and throttles them as one.

## Run

```sh
npm install
npm start
```

Run the tests with `npm test`.

## What this service must never become

- It stores no users.
- It keeps no database.
- It holds no token after a claim.
- It proxies no Notion API calls.
- It logs no tokens.
