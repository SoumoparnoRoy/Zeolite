# Zeolite Server

> If this service is down, Zeolite works exactly as it always does and nothing
> is lost — syncing pauses and resumes on its own, and reading a timetable off
> an image falls back to doing it on the device.

This standalone service holds the secrets Zeolite cannot ship inside the mobile app: the Notion client secret for the OAuth handshake, and the Cloudflare token used to read a timetable off an image.

| Route | Purpose |
| --- | --- |
| `GET /notion/start` | Starts authorization using the app's verifier challenge. |
| `GET /notion/callback` | Exchanges Notion's authorization code and returns to the app. |
| `POST /notion/claim` | Releases the token payload after verifier proof. |
| `POST /notion/refresh` | Exchanges a refresh token for a fresh token payload. |
| `POST /timetable/read` | Sends an image, and the text recognition already done on it, to Workers AI and returns the classes it found. Answers `503` when no Cloudflare token is configured. |
| `GET /health` | Returns `ok`. The app calls it when the connect screen opens, so a host that has spun the service down is awake before anyone taps Connect. |

## Environment variables

- `NOTION_CLIENT_ID` — required Notion OAuth client ID
- `NOTION_CLIENT_SECRET` — required Notion OAuth client secret
- `REDIRECT_URI` — required callback URL configured in Notion
- `PORT` — optional server port, default `8080`
- `APP_SCHEME` — optional mobile URL scheme, default `zeolite`
- `TRUST_PROXY` — number of proxies in front of the service, default `0`. Set
  it to `1` behind a single load balancer, or rate limiting counts every
  caller as the balancer and throttles them as one.
- `CLOUDFLARE_ACCOUNT_ID` and `CLOUDFLARE_API_TOKEN` — optional. Without both,
  `/timetable/read` answers `503` and everything else runs as usual.
- `CLOUDFLARE_MODEL` — optional, defaults to the Llama 3.2 vision model.
- `AI_DAILY_CALLS` — optional, default `180`. Workers AI allows 10,000 neurons
  a day on the free plan and stops rather than bills; a read costs roughly
  fifty, so this keeps the day's calls under that ceiling.

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
- It keeps no image, and no text read off one, after the reply.
- It proxies no Notion API calls.
- It logs no tokens.
