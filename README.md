# omarchy-mindwtr

An [Omarchy](https://omarchy.org/) bar plugin for a **self-hosted
[Mindwtr](https://github.com/dongdongbh/Mindwtr) Cloud server**. It shows your
GTD buckets in the status bar and lets you capture and complete tasks without
opening the app.

- **Bar icon** with a badge counting Focus / Inbox / Next / Waiting (configurable).
- **Popup panel** with tabs for Focus, Inbox, Next, Waiting and Someday.
- **Details view** for the selected task: status, project, contexts, dates,
  priority, estimate, description, checklist and attachments.
- **Quick capture** into the Inbox with `POST /v1/tasks`.
- **Mark done** with `d` or the row checkbox (`POST /v1/tasks/:id/complete`).
- Full keyboard control: arrows/`j`/`k` to move, `Enter` for details, `d` for
  done, `c` to capture, `Esc` to back out.
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
- `label` — optional friendly name shown in the panel header instead of the host.
- `insecureSkipVerify` — set `true` only for a self-signed certificate you
  control. It maps to `curl -k`.
- `allowInsecureHttp` — plain `http://` to a non-loopback host is refused
  because it would put the token on the wire in cleartext. Set this to `true`
  only for a trusted private network you control.

Environment variables `MINDWTR_CLOUD_URL` and `MINDWTR_CLOUD_TOKEN` take
precedence over the file. `MINDWTR_CONFIG` overrides the config path, and
`MINDWTR_ALLOW_INSECURE_HTTP=1` opts into plain HTTP for a non-loopback host,
and `MINDWTR_LABEL` overrides the display name.

The config is read on every refresh, so edits apply without a restart.

## Settings

Set in the bar widget's settings UI or inline in `shell.json`:

| Key | Default | Meaning |
| --- | --- | --- |
| `badge` | `inbox` | Which bucket the bar number counts: `focus`, `inbox`, `next`, `waiting`. |
| `showCount` | `true` | Show the badge at all. |
| `quickAdd` | `true` | Show the capture field in the panel. |
| `checkbox` | `true` | Show a row checkbox; clicking it or pressing `d` marks done. Clicking the row opens details. |
| `refreshIntervalSec` | `120` | Server poll interval (30–3600). |

## Keyboard

With the capture field not focused:

| Key | Action |
| --- | --- |
| `↑` / `↓` or `k` / `j` | Move the row cursor |
| `←` / `→` or `1`–`5` | Switch bucket tab |
| `g` / `G` | Jump to first / last row |
| `Enter` / `Space` | Open the selected task's details |
| `d` | Mark the selected (or shown) task done |
| `c` or `/` | Focus the capture field |
| `r` | Refresh from the server |
| `Esc` | Back out of details, else close the panel |

In the capture field, `Enter` adds the task and `Esc` returns to the list.

## How it works

`mindwtr-api.sh` is the only piece that touches the network. It reads the
config, calls the Cloud API, and prints one normalized JSON object per
invocation. `Panel.qml` runs it through Quickshell's `Process` and renders the
result; `Model.js` holds the pure parsing and formatting so it is testable on
its own.

Endpoints used:

| Command | Request |
| --- | --- |
| `summary` | `GET /v1/projects?limit=500`, paged `GET /v1/tasks` |
| `task` | `GET /v1/tasks/<id>` (+ projects for the title) |
| `capture` | `POST /v1/tasks` with `{ "input": "<text>" }`; the text is read from stdin, not from an argument |
| `complete` | `POST /v1/tasks/<id>/complete` |

The task list is paged up to 1000 tasks per refresh.

## Security

- The bearer token is read from `~/.config/omarchy/mindwtr.json` and handed to
  `curl` through a config stream on stdin, so it never appears in a process
  argument list where other local processes could read it.
- Task text follows the same rule. Quick capture passes the text to the helper on
  stdin, the helper builds the JSON body itself, and that body is sent to `curl`
  through the same stdin config stream. No task content is ever an argument of
  `bash`, the helper, or `curl`, so it stays out of `/proc/<pid>/cmdline` while
  those processes run. Only opaque task ids appear in an argument list.
- Attachment URIs are opened by passing them to `xdg-open` as a single argument
  list element, not by splicing them into a shell command string.
- Plain `http://` is refused for any non-loopback host; loopback is allowed for
  local test servers. `insecureSkipVerify` only relaxes certificate checking and
  is opt-in.
- Each response is capped at 16 MiB (`MINDWTR_MAX_RESPONSE_BYTES`) and each
  request has an 8 s timeout (`MINDWTR_TIMEOUT`), so a broken or hostile server
  cannot make the long-lived shell buffer an unbounded body.
- The plugin never writes your tasks or configuration; the only state it owns is
  the token file you create.

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
  printf 'Buy milk\n' | bash ~/.config/omarchy/plugins/mindwtr/mindwtr-api.sh capture | jq .
  ```

## License

MIT
