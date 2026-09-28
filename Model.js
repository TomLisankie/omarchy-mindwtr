// Pure data shaping for the Mindwtr Omarchy widget. No QML globals here, so
// the parsing and formatting rules stay testable on their own.

var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

function asString(value, fallback) {
  if (value === undefined || value === null) return fallback === undefined ? "" : fallback
  var text = String(value)
  return text
}

function clampText(value, maxLength) {
  var text = asString(value)
  if (text.length <= maxLength) return text
  return text.slice(0, Math.max(0, maxLength - 1)) + "\u2026"
}

function normalizeTask(raw) {
  if (!raw || typeof raw !== "object") return null
  var id = asString(raw.id).trim()
  var title = asString(raw.title).trim()
  if (id === "" && title === "") return null
  var contexts = []
  if (Array.isArray(raw.contexts)) {
    for (var i = 0; i < raw.contexts.length; i++) {
      var context = asString(raw.contexts[i]).trim()
      if (context !== "") contexts.push(context)
    }
  }
  return {
    id: id,
    title: title === "" ? "(untitled)" : title,
    status: asString(raw.status),
    dueDate: asString(raw.dueDate),
    startTime: asString(raw.startTime),
    contexts: contexts,
    priority: asString(raw.priority),
    project: asString(raw.project).trim(),
    focused: raw.focused === true
  }
}

function normalizeList(raw) {
  var out = []
  if (!Array.isArray(raw)) return out
  for (var i = 0; i < raw.length; i++) {
    var task = normalizeTask(raw[i])
    if (task) out.push(task)
  }
  return out
}

function parseSummary(raw) {
  var text = asString(raw).replace(/^\s+|\s+$/g, "")
  if (text === "") return { ok: false, error: "unreachable" }
  var parsed
  try {
    parsed = JSON.parse(text)
  } catch (e) {
    return { ok: false, error: "bad_response" }
  }
  if (!parsed || typeof parsed !== "object") return { ok: false, error: "bad_response" }
  if (parsed.ok !== true) return { ok: false, error: asString(parsed.error, "error") }
  var counts = parsed.counts && typeof parsed.counts === "object" ? parsed.counts : {}
  return {
    ok: true,
    server: asString(parsed.server),
    fetchedAt: asString(parsed.fetchedAt),
    total: Number(parsed.total) || 0,
    counts: {
      focus: Number(counts.focus) || 0,
      inbox: Number(counts.inbox) || 0,
      next: Number(counts.next) || 0,
      waiting: Number(counts.waiting) || 0,
      someday: Number(counts.someday) || 0
    },
    focus: normalizeList(parsed.focus),
    inbox: normalizeList(parsed.inbox),
    next: normalizeList(parsed.next),
    waiting: normalizeList(parsed.waiting),
    someday: normalizeList(parsed.someday)
  }
}

function parseMutation(raw) {
  var text = asString(raw).replace(/^\s+|\s+$/g, "")
  if (text === "") return { ok: false, error: "unreachable" }
  var parsed
  try {
    parsed = JSON.parse(text)
  } catch (e) {
    return { ok: false, error: "bad_response" }
  }
  if (!parsed || typeof parsed !== "object") return { ok: false, error: "bad_response" }
  if (parsed.ok !== true) return { ok: false, error: asString(parsed.error, "error") }
  return { ok: true, error: "" }
}

function errorText(code) {
  var value = asString(code)
  switch (value) {
    case "no_server_url": return "No server URL configured"
    case "no_token": return "No API token configured"
    case "unauthorized": return "The server rejected the token"
    case "unreachable": return "Server unreachable"
    case "insecure_http": return "Refusing to send the token over plain HTTP"
    case "invalid_url": return "The server URL is invalid (remove any user:pass@)"
    case "bad_response": return "The server returned an unexpected response"
    case "empty": return "Nothing to capture"
    case "missing_id": return "Missing task id"
    case "tmpdir": return "Could not create a temp directory"
    case "unknown_command": return "Unknown helper command"
    case "": return ""
    default:
      if (value.indexOf("http_") === 0) return "Server returned HTTP " + value.slice(5)
      return clampText(value, 120)
  }
}

// Accepts "YYYY-MM-DD", a full ISO timestamp, or a date-time with offset.
function parseDate(value) {
  var text = asString(value).trim()
  if (text === "") return null
  var dayMatch = text.match(/^(\d{4})-(\d{2})-(\d{2})/)
  if (dayMatch) {
    var year = parseInt(dayMatch[1], 10)
    var month = parseInt(dayMatch[2], 10) - 1
    var day = parseInt(dayMatch[3], 10)
    return new Date(year, month, day)
  }
  var parsed = new Date(text)
  return isNaN(parsed.getTime()) ? null : parsed
}

function startOfDay(date) {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate())
}

function relativeDayLabel(target, today, overdueWord) {
  var dayMs = 86400000
  var diff = Math.round((startOfDay(target).getTime() - startOfDay(today).getTime()) / dayMs)
  if (diff === 0) return "today"
  if (diff === 1) return "tomorrow"
  if (diff === -1) return overdueWord ? "yesterday" : ""
  if (diff < 0) return overdueWord ? (Math.abs(diff) + "d overdue") : ""
  if (diff <= 7) return "in " + diff + "d"
  return ""
}

function formatDay(date, today) {
  var label = MONTHS[date.getMonth()] + " " + date.getDate()
  if (date.getFullYear() !== today.getFullYear()) label += " " + date.getFullYear()
  return label
}

function dueLabel(task, now) {
  var date = parseDate(task.dueDate)
  var kind = "due"
  if (!date) {
    date = parseDate(task.startTime)
    kind = "starts"
  }
  if (!date) return ""
  var today = now instanceof Date ? now : new Date()
  var relative = relativeDayLabel(date, today, kind === "due")
  if (relative.indexOf("overdue") !== -1) return relative
  if (relative !== "") return kind + " " + relative
  return kind + " " + formatDay(date, today)
}

function isOverdue(task, now) {
  var date = parseDate(task.dueDate)
  if (!date) return false
  var today = now instanceof Date ? now : new Date()
  return startOfDay(date).getTime() < startOfDay(today).getTime()
}

function subtitle(task, now) {
  var parts = []
  if (task.project !== "") parts.push(task.project)
  if (task.contexts.length > 0) parts.push(task.contexts.join(" "))
  var due = dueLabel(task, now)
  if (due !== "") parts.push(due)
  return parts.join("  \u00b7  ")
}

function totalCount(summary) {
  if (!summary || !summary.counts) return 0
  return (summary.counts.focus || 0)
    + (summary.counts.inbox || 0)
    + (summary.counts.next || 0)
    + (summary.counts.waiting || 0)
    + (summary.counts.someday || 0)
}
