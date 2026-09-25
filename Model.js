// Nextcloud News Data Model and Formatting Helpers

function parseJson(raw) {
  var text = String(raw || "").trim()
  if (text === "") return { ok: false, error: "Empty response" }
  try {
    return JSON.parse(text)
  } catch (e) {
    return { ok: false, error: "JSON parse error: " + e.message }
  }
}

function relativeTime(timestampSec) {
  var ts = Number(timestampSec || 0)
  if (!isFinite(ts) || ts <= 0) return "Unknown"
  var diff = Math.max(0, Math.floor((Date.now() - ts * 1000) / 1000))
  if (diff < 60) return "Just now"
  var minutes = Math.floor(diff / 60)
  if (minutes < 60) return minutes + "m ago"
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return hours + "h ago"
  var days = Math.floor(hours / 24)
  if (days < 7) return days + "d ago"
  if (days < 30) return Math.floor(days / 7) + "w ago"
  return days < 365 ? Math.floor(days / 30) + "mo ago" : Math.floor(days / 365) + "y ago"
}

function formatFullDate(timestampSec) {
  var ts = Number(timestampSec || 0)
  if (!isFinite(ts) || ts <= 0) return ""
  var d = new Date(ts * 1000)
  return d.toLocaleDateString(undefined, {
    month: "short",
    day: "numeric",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit"
  })
}

function decodeEntities(str) {
  var text = String(str || "")
  text = text.replace(/&amp;/g, "&")
  text = text.replace(/&lt;/g, "<")
  text = text.replace(/&gt;/g, ">")
  text = text.replace(/&quot;/g, '"')
  text = text.replace(/&#0*39;/g, "'")
  text = text.replace(/&apos;/g, "'")
  text = text.replace(/&#x27;/gi, "'")
  text = text.replace(/&nbsp;/g, " ")
  text = text.replace(/&#8216;/g, "'")
  text = text.replace(/&#8217;/g, "'")
  text = text.replace(/&#8220;/g, '"')
  text = text.replace(/&#8221;/g, '"')
  text = text.replace(/&#8211;/g, "–")
  text = text.replace(/&#8212;/g, "—")
  text = text.replace(/&#(\d+);/g, function(match, dec) {
    var code = parseInt(dec, 10)
    return isFinite(code) && code > 0 ? String.fromCharCode(code) : match
  })
  text = text.replace(/&#x([0-9a-f]+);/gi, function(match, hex) {
    var code = parseInt(hex, 16)
    return isFinite(code) && code > 0 ? String.fromCharCode(code) : match
  })
  return text
}

function stripHtml(html) {
  var text = String(html || "")
  text = text.replace(/<[^>]+>/g, " ")
  text = decodeEntities(text)
  text = text.replace(/\s+/g, " ")
  return text.trim()
}

function sanitizeForQml(rawHtml) {
  var text = String(rawHtml || "")
  // Remove dangerous tags and embedded elements
  text = text.replace(/<(script|style|iframe|frame|object|embed|applet|base|link|meta)[^>]*>[\s\S]*?<\/\1>/gi, "")
  text = text.replace(/<(script|style|iframe|frame|object|embed|applet|base|link|meta)[^>]*\/?>/gi, "")
  // Disallow <img> in QML RichText to prevent unprompted HTTP/file fetches
  text = text.replace(/<img[^>]*\/?>/gi, " <i>[Image]</i> ")
  // Remove event handlers (onclick, onload, onerror, etc.)
  text = text.replace(/\s+on\w+\s*=\s*(["'][^"']*["']|[^\s>]+)/gi, "")
  // Neutralize javascript: or file: URIs in links
  text = text.replace(/href\s*=\s*(["'])\s*(?:javascript|file|data):[\s\S]*?\1/gi, 'href="#"')
  return text
}

function safeFavicon(url) {
  var s = String(url || "").trim()
  if (!s.startsWith("https://")) return ""
  // Reject local/private network ranges
  if (/^https:\/\/(localhost|127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|0\.0\.0\.0|\[::1\])/i.test(s)) return ""
  return s
}

function filePath(url) {
  return decodeURIComponent(String(url || "").replace(/^file:\/\//, ""))
}

if (typeof module !== "undefined") {
  module.exports = {
    parseJson: parseJson,
    relativeTime: relativeTime,
    formatFullDate: formatFullDate,
    stripHtml: stripHtml,
    decodeEntities: decodeEntities,
    sanitizeForQml: sanitizeForQml,
    safeFavicon: safeFavicon,
    filePath: filePath
  }
}

