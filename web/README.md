# BeatPort Digger - web version

A browser front-end so a phone, tablet or laptop can search and preview the
Beatport catalogue without installing a native app. It is a **Dart backend** that
reuses the app's engine plus a **React** front-end.

```
[phone / tablet browser] -> http://<pc-ip>:8080
        React UI  --REST-->  Dart backend (lib/engine)  -->  Beatport
```

The browser cannot talk to Beatport directly (CORS, auth, and the encrypted HLS
previews all need a server), so the backend stands in the middle. It holds one
signed-in session in memory - single user, for personal use on your own network.

## Run it (production - one origin, what the phone uses)

From the project root:

```bash
# 1. Build the React app once (re-run after front-end changes).
cd web/frontend && npm install && npm run build && cd ../..

# 2. Start the backend; it serves the built app and the API on :8080.
dart run bin/server.dart
```

The backend prints the machine's LAN addresses at startup, for example
`http://192.168.50.20:8080`. Open that address in the browser on your phone
(same Wi-Fi) and sign in with your Beatport account.

## Develop (hot reload)

```bash
# Terminal 1 - backend
dart run bin/server.dart

# Terminal 2 - React dev server (proxies /api to the backend)
cd web/frontend && npm run dev
```

Open the dev server URL it prints (default http://localhost:5173).

## Endpoints

- `POST /api/login` `{username, password}` - sign in.
- `GET  /api/status` - `{authenticated}`.
- `GET  /api/search?title=&artist=&label=&genre=&bpmLow=&bpmHigh=&sort=&page=`.
- `GET  /api/genres` - genres for a filter dropdown.
- `GET  /api/preview/<id>` - decrypted AAC preview the browser can play.

## Status

Phase 1: sign in, search, preview playback with autoplay. Downloads and the
harmonic wheel are still to come. The backend keeps the session in memory, so a
restart means signing in again.

## Notes

- Keep this on your local network. Hosting it publicly would put your Beatport
  login on a server; there is no multi-user auth here.
- The machine running the backend must stay on for the phone to reach it.
