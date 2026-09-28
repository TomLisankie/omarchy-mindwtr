# omarchy-mindwtr

An [Omarchy](https://omarchy.org/) bar plugin for a **self-hosted
[Mindwtr](https://github.com/dongdongbh/Mindwtr) Cloud server**. It shows your
GTD buckets in the status bar and lets you capture and complete tasks without
opening the app.

- **Bar icon** with a badge counting Focus / Inbox / Next / Waiting (configurable).
- **Popup panel** with tabs for Focus, Inbox, Next, Waiting and Someday.
- **Quick capture** into the Inbox (`POST /v1/tasks`).
- **Mark done** on click (`POST /v1/tasks/:id/complete`).
- Talks to the Cloud REST API over HTTPS with a bearer token; no local SQLite,
  no MCP helper process.

## Requirements

- Omarchy with the Quickshell shell (`omarchy-shell`).
- A reachable self-hosted Mindwtr Cloud endpoint and one of its bearer tokens.
- `bash`, `curl`, `jq` (all present on a stock Omarchy install).
- The plugin makes network requests only to the `baseUrl` you configure, using
your bearer token. No other external dependencies.

## Install

```bash
omarchy plugin add <git-url> --enable
# then place it in a bar section, e.g.
omarchy bar move mindwtr --section right
```

The shell hot-reloads plugin code; `omarchy restart shell` if anything looks
stale.

## Configure

Create `~/.config/omarchy/mindwtr.json`:

```json
{
  "baseUrl": "https://mindwtr.example.com",
  "token": "your-bearer-token",
  "insecureSkipVerify": false
}
```

```bash
install -m 600 config.example.json ~/.config/omarchy/mindwtr.json
$EDITOR ~/.config/omarchy/mindwtr.json
chmod 600 ~/.config/omarchy/mindwtr.json   # protect the token
```

- `baseUrl` — full scheme and host (a bare host defaults to `https://`).
- `token` — the same bearer token your Mindwtr clients use on `/v1/*`.
- `insecureSkipVerify` — set `true` only for a self-signed certificate you
  control. It maps to `curl -k`.

Environment variables `MINDWTR_CLOUD_URL` and `MINDWTR_CLOUD_TOKEN` take
precedence over the file. `MINDWTR_CONFIG` overrides the config path.

The config is read on every refresh, so edits apply without a restart.

## Settings

Set in the bar widget's settings UI or inline in `shell.json`:

| Key | Default | Meaning |
| --- | --- | --- |
| `badge` | `focus` | Which bucket the bar number counts: `focus`, `inbox`, `next`, `waiting`. |
| `showCount` | `true` | Show the badge at all. |
| `quickAdd` | `true` | Show the capture field in the panel. |
| `completeOnClick` | `true` | Clicking a task row marks it done. |
| `refreshIntervalSec` | `120` | Server poll interval (30–3600). |

## How it works

`mindwtr-api.sh` is the only piece that touches the network. It reads the
config, calls the Cloud API, and prints one normalized JSON object per
invocation. `Panel.qml` runs it through Quickshell's `Process` and renders the
result; `Model.js` holds the pure parsing and formatting so it is testable on
its own. The token only ever appears in the `curl` header inside that script,
never in a shell command line the shell logs.

Endpoints used:

| Command | Request |
| --- | --- |
| `summary` | `GET /v1/projects?limit=500`, paged `GET /v1/tasks` |
| `capture` | `POST /v1/tasks` with `{ "input": "<text>" }` |
| `complete` | `POST /v1/tasks/<id>/complete` |

The task list is paged up to 1000 tasks per refresh.

## Remove

```bash
omarchy plugin remove mindwtr
rm -f ~/.config/omarchy/mindwtr.json   # deletes the stored token
```

`omarchy plugin remove` takes the widget out of the bar and deletes
`~/.config/omarchy/plugins/mindwtr`. Removing the config file is only needed
if you want to erase the bearer token too.

## Troubleshooting

- **"The server rejected the token"** — the token is wrong or revoked.
- **"Server unreachable"** — check `baseUrl`, TLS, and that the server is up.
- **"No server URL configured" / "No API token configured"** — the config file
  is missing or unreadable; check the path and permissions.
- Check the raw response manually:

  ```bash
  bash ~/.config/omarchy/plugins/mindwtr/mindwtr-api.sh summary | jq .
  ```

## License

MIT
