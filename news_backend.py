#!/usr/bin/env python3
"""
OmanewsNC - Omarchy backend helper.
Supports Nextcloud Login Flow v2 (direct browser sign-in) as well as
Nextcloud Desktop client keyring auto-detection. Handles SQLite caching,
syncing, and article state management.
"""

import argparse
import base64
import configparser
import datetime
import html
import json
import os
import re
import shlex
import shutil
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

PLUGIN_DIR = Path.home() / ".config" / "omarchy" / "plugins" / "clartek.omanextnews"
AUTH_FILE = PLUGIN_DIR / "auth.json"
CACHE_DIR = Path.home() / ".cache" / "omarchy" / "plugins" / "clartek.omanextnews"
DB_PATH = CACHE_DIR / "news.db"
AUTH_STATE_PATH = CACHE_DIR / "auth_state.json"
USER_AGENT = "OmanewsNC/1.0"
MAX_RESPONSE_BYTES = 10 * 1024 * 1024  # 10 MiB limit for API responses
MAX_ERROR_BYTES = 64 * 1024            # 64 KiB limit for error responses
MAX_FLOW_BYTES = 64 * 1024             # 64 KiB limit for login flow responses


def read_bounded(stream, max_bytes):
  """Read up to max_bytes from stream, raising ValueError if exceeded."""
  data = stream.read(max_bytes + 1)
  if len(data) > max_bytes:
    raise ValueError(f"HTTP response exceeded maximum allowed limit of {max_bytes} bytes")
  return data



def command_output(command, timeout=5):
  try:
    process = subprocess.run(
      command,
      stdout=subprocess.PIPE,
      stderr=subprocess.PIPE,
      text=True,
      timeout=timeout,
      check=False,
    )
    return process.returncode, process.stdout.strip()
  except (subprocess.SubprocessError, OSError):
    return -1, ""


def open_url_in_browser(url):
  if shutil.which("omarchy"):
    code, _ = command_output(["omarchy", "launch", "browser", url])
    if code == 0:
      return True
  if shutil.which("xdg-open"):
    try:
      subprocess.Popen(["xdg-open", url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
      return True
    except OSError:
      pass
  return False


# ---------------------------------------------------------------------------
# Authentication
# ---------------------------------------------------------------------------

def save_direct_auth(saved_creds):
  """Persist Nextcloud credentials with strict private permissions (0600)

  using an atomic tempfile write.
  """
  PLUGIN_DIR.mkdir(parents=True, exist_ok=True)
  try:
    os.chmod(PLUGIN_DIR, 0o700)
  except OSError:
    pass

  payload = json.dumps(saved_creds, indent=2).encode("utf-8")
  temp_file = PLUGIN_DIR / f".auth.tmp.{os.getpid()}"
  flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
  fd = os.open(str(temp_file), flags, 0o600)
  try:
    with open(fd, "wb") as f:
      f.write(payload)
      f.flush()
      os.fsync(f.fileno())
    os.chmod(str(temp_file), 0o600)
    os.replace(str(temp_file), str(AUTH_FILE))
    os.chmod(str(AUTH_FILE), 0o600)
  except Exception:
    try:
      if temp_file.exists():
        temp_file.unlink()
    except OSError:
      pass
    raise


def read_direct_auth():
  if AUTH_FILE.is_file():
    try:
      # Enforce private file mode on existing auth file
      try:
        current_mode = os.stat(str(AUTH_FILE)).st_mode & 0o777
        if current_mode != 0o600:
          os.chmod(str(AUTH_FILE), 0o600)
      except OSError:
        pass
      data = json.loads(AUTH_FILE.read_text(encoding="utf-8"))
      if data.get("serverUrl") and data.get("username") and data.get("appPassword"):
        return {
          "serverUrl": data["serverUrl"].rstrip("/"),
          "credentialUser": data["username"],
          "appPassword": data["appPassword"],
          "source": "direct",
        }
    except Exception:
      pass
  return None


def read_desktop_account():
  config_path = Path.home() / ".config" / "Nextcloud" / "nextcloud.cfg"
  parser = configparser.RawConfigParser(strict=False)
  try:
    parser.read(config_path, encoding="utf-8")
  except (OSError, configparser.Error):
    return None

  account_prefix = "0\\"
  server_url = ""
  dav_user = ""
  webflow_user = ""

  if parser.has_section("Accounts"):
    for key, value in parser.items("Accounts"):
      if key.startswith(account_prefix):
        sub_key = key[len(account_prefix):]
        if sub_key == "url":
          server_url = value.rstrip("/")
        elif sub_key == "dav_user":
          dav_user = value
        elif sub_key == "webflow_user":
          webflow_user = value

  credential_user = dav_user or webflow_user
  if not server_url or not credential_user:
    return None

  return {
    "serverUrl": server_url,
    "credentialUser": credential_user,
    "davUser": dav_user,
    "source": "desktop",
  }


def keyring_passwords(account):
  if not shutil.which("secret-tool") or not shutil.which("busctl"):
    return []

  server_url = str(account.get("serverUrl", "")).rstrip("/")
  credential_user = str(account.get("credentialUser", ""))
  if not server_url or not credential_user:
    return []

  code, tree = command_output(["busctl", "--user", "tree", "org.freedesktop.secrets", "--list"])
  if code != 0:
    return []

  passwords = []
  paths = re.findall(r"^(/org/freedesktop/secrets/collection/\S+/\d+)$", tree, re.MULTILINE)
  for path in paths:
    _, label = command_output([
      "busctl", "--user", "get-property", "org.freedesktop.secrets", path,
      "org.freedesktop.Secret.Item", "Label",
    ])
    if "nextcloud" not in label.lower():
      continue

    attr_code, raw_attributes = command_output([
      "busctl", "--user", "get-property", "org.freedesktop.secrets", path,
      "org.freedesktop.Secret.Item", "Attributes",
    ])
    if attr_code != 0:
      continue

    tokens = shlex.split(raw_attributes)
    attributes = dict(zip(tokens[2::2], tokens[3::2]))
    server_key = attributes.get("server", "")
    user_key = attributes.get("user", "")
    if not server_key or not user_key:
      continue

    expected_prefixes = (
      credential_user + ":" + server_url + "/:",
      credential_user + "_app-password:" + server_url + "/:",
    )
    if server_key != "Nextcloud" or not user_key.startswith(expected_prefixes):
      continue

    secret_code, password = command_output([
      "secret-tool", "lookup", "server", server_key, "user", user_key,
    ])
    if secret_code == 0 and password and not any(password == item[1] for item in passwords):
      passwords.append((user_key, password))

  return passwords


def start_login_flow(server_url):
  server_url = server_url.rstrip("/")
  flow_url = f"{server_url}/index.php/login/v2"
  req = urllib.request.Request(flow_url, data=b"", headers={"User-Agent": USER_AGENT}, method="POST")
  try:
    with urllib.request.urlopen(req, timeout=10) as resp:
      raw = read_bounded(resp, MAX_FLOW_BYTES)
      flow_data = json.loads(raw.decode("utf-8"))
      poll_endpoint = flow_data.get("poll", {}).get("endpoint")
      token = flow_data.get("poll", {}).get("token")
      login_url = flow_data.get("login")
      if not poll_endpoint or not token or not login_url:
        return False, "Malformed login flow response from Nextcloud"

      # Open browser
      open_url_in_browser(login_url)

      # Start polling (timeout after 300 seconds)
      start_time = time.time()
      poll_data = urllib.parse.urlencode({"token": token}).encode("utf-8")

      while time.time() - start_time < 300:
        time.sleep(1.5)
        poll_req = urllib.request.Request(
          poll_endpoint,
          data=poll_data,
          headers={"User-Agent": USER_AGENT},
          method="POST"
        )
        try:
          with urllib.request.urlopen(poll_req, timeout=8) as poll_resp:
            if poll_resp.status == 200:
              raw = read_bounded(poll_resp, MAX_FLOW_BYTES)
              creds = json.loads(raw.decode("utf-8"))
              saved_creds = {
                "serverUrl": creds.get("server", server_url).rstrip("/"),
                "username": creds.get("loginName", ""),
                "appPassword": creds.get("appPassword", ""),
                "createdAt": int(time.time()),
                "authMethod": "direct"
              }
              save_direct_auth(saved_creds)
              return True, saved_creds
        except urllib.error.HTTPError as e:
          if e.code == 404:
            # Still pending user confirmation in browser
            continue
          else:
            return False, f"Polling error: HTTP {e.code}"
        except Exception:
          continue

      return False, "Login flow timed out"

  except Exception as e:
    return False, f"Could not connect to Nextcloud server: {e}"


class NewsClient:
  def __init__(self, server_url, username, passwords, auth_source="direct"):
    self.server_url = server_url.rstrip("/")
    self.username = username
    self.passwords = passwords  # list of (key, password)
    self.auth_source = auth_source

  def request(self, endpoint, method="GET", json_body=None, timeout=12):
    url = f"{self.server_url}/index.php/apps/news/api/v1-2{endpoint}"
    data = None
    if json_body is not None:
      data = json.dumps(json_body).encode("utf-8")

    for key, password in self.passwords:
      auth_str = f"{self.username}:{password}"
      auth_header = "Basic " + base64.b64encode(auth_str.encode("utf-8")).decode("ascii")
      headers = {
        "Authorization": auth_header,
        "User-Agent": USER_AGENT,
        "Accept": "application/json",
      }
      if data is not None:
        headers["Content-Type"] = "application/json; charset=utf-8"

      req = urllib.request.Request(url, data=data, headers=headers, method=method)
      try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
          raw = read_bounded(resp, MAX_RESPONSE_BYTES)
          body = raw.decode("utf-8", errors="replace")
          return resp.status, json.loads(body) if body.strip() else {}
      except urllib.error.HTTPError as e:
        if e.code in (401, 403) and len(self.passwords) > 1:
          continue
        raw = e.read(MAX_ERROR_BYTES)
        body = raw.decode("utf-8", errors="replace") if raw else ""
        try:
          err_json = json.loads(body) if body.strip() else {"message": str(e.reason)}
        except Exception:
          err_json = {"message": str(e.reason)}
        return e.code, err_json
      except ValueError as e:
        return 413, {"message": str(e)}
      except Exception as e:
        return 0, {"message": str(e)}

    return 401, {"message": "Invalid Nextcloud credentials"}


def get_client(args=None):
  # 1. Manual args override
  if args and getattr(args, "server_url", "") and getattr(args, "user", "") and getattr(args, "password", ""):
    return NewsClient(args.server_url, args.user, [("manual", args.password)], "manual"), ""

  # 2. Direct Plugin Auth (auth.json)
  direct = read_direct_auth()
  if direct:
    return NewsClient(
      direct["serverUrl"],
      direct["credentialUser"],
      [("direct", direct["appPassword"])],
      "direct"
    ), ""

  # 3. Nextcloud Desktop client fallback
  desktop = read_desktop_account()
  if desktop:
    creds = keyring_passwords(desktop)
    if creds:
      return NewsClient(
        desktop["serverUrl"],
        desktop["credentialUser"],
        creds,
        "desktop"
      ), ""

  # Guess default URL if available
  default_server = desktop.get("serverUrl", "") if desktop else ""
  return None, "Not authenticated. Click to sign in."


# ---------------------------------------------------------------------------
# Database & Cache
# ---------------------------------------------------------------------------

def get_db():
  CACHE_DIR.mkdir(parents=True, exist_ok=True)
  try:
    os.chmod(CACHE_DIR, 0o700)
  except OSError:
    pass
  conn = sqlite3.connect(str(DB_PATH))
  try:
    if DB_PATH.is_file():
      os.chmod(DB_PATH, 0o600)
  except OSError:
    pass
  conn.row_factory = sqlite3.Row
  with conn:
    conn.execute("""
      CREATE TABLE IF NOT EXISTS folders (
        id INTEGER PRIMARY KEY,
        name TEXT,
        opened INTEGER DEFAULT 1
      )
    """)
    conn.execute("""
      CREATE TABLE IF NOT EXISTS feeds (
        id INTEGER PRIMARY KEY,
        url TEXT,
        title TEXT,
        favicon_link TEXT,
        unread_count INTEGER DEFAULT 0,
        folder_id INTEGER DEFAULT 0,
        ordering INTEGER DEFAULT 0,
        link TEXT,
        pinned INTEGER DEFAULT 0
      )
    """)
    conn.execute("""
      CREATE TABLE IF NOT EXISTS items (
        id INTEGER PRIMARY KEY,
        guid TEXT,
        guid_hash TEXT,
        url TEXT,
        title TEXT,
        author TEXT,
        pub_date INTEGER,
        updated_date INTEGER,
        body TEXT,
        enclosure_mime TEXT,
        enclosure_link TEXT,
        media_thumbnail TEXT,
        media_description TEXT,
        feed_id INTEGER,
        unread INTEGER DEFAULT 1,
        starred INTEGER DEFAULT 0,
        last_modified INTEGER
      )
    """)
    conn.execute("CREATE INDEX IF NOT EXISTS idx_items_feed ON items(feed_id)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_items_unread ON items(unread)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_items_starred ON items(starred)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_items_pub_date ON items(pub_date DESC)")
    conn.execute("""
      CREATE TABLE IF NOT EXISTS meta (
        key TEXT PRIMARY KEY,
        value TEXT
      )
    """)
  return conn


def sync_all(client, notify=True):
  conn = get_db()

  # 1. Fetch Folders
  f_status, f_data = client.request("/folders")
  if f_status != 200:
    return False, f"Failed to fetch folders: {f_data.get('message', f_status)}"

  # 2. Fetch Feeds
  fe_status, fe_data = client.request("/feeds")
  if fe_status != 200:
    return False, f"Failed to fetch feeds: {fe_data.get('message', fe_status)}"

  # 3. Fetch Items (batch of latest unread & recent read)
  it_status, it_data = client.request("/items?batchSize=100&type=3&id=0&getRead=true")
  if it_status != 200:
    return False, f"Failed to fetch items: {it_data.get('message', it_status)}"

  folders = f_data.get("folders", [])
  feeds = fe_data.get("feeds", [])
  starred_count = fe_data.get("starredCount", 0)
  items = it_data.get("items", [])

  prev_max_id = 0
  with conn:
    row = conn.execute("SELECT value FROM meta WHERE key = 'latest_item_id'").fetchone()
    if row and row["value"]:
      try:
        prev_max_id = int(row["value"])
      except ValueError:
        prev_max_id = 0

  new_unread_titles = []
  max_id = prev_max_id

  with conn:
    conn.execute("DELETE FROM folders")
    for f in folders:
      conn.execute(
        "INSERT OR REPLACE INTO folders (id, name, opened) VALUES (?, ?, ?)",
        (f.get("id"), f.get("name"), 1 if f.get("opened") else 0)
      )

    conn.execute("DELETE FROM feeds")
    for fe in feeds:
      conn.execute(
        """INSERT OR REPLACE INTO feeds
           (id, url, title, favicon_link, unread_count, folder_id, ordering, link, pinned)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        (
          fe.get("id"),
          fe.get("url"),
          fe.get("title"),
          fe.get("faviconLink"),
          fe.get("unreadCount", 0),
          fe.get("folderId", 0),
          fe.get("ordering", 0),
          fe.get("link"),
          1 if fe.get("pinned") else 0
        )
      )

    for item in items:
      item_id = item.get("id")
      if item_id > max_id:
        max_id = item_id
      if prev_max_id > 0 and item_id > prev_max_id and item.get("unread", True):
        new_unread_titles.append(item.get("title", ""))

      conn.execute(
        """INSERT INTO items
           (id, guid, guid_hash, url, title, author, pub_date, updated_date, body,
            enclosure_mime, enclosure_link, media_thumbnail, media_description,
            feed_id, unread, starred, last_modified)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
           ON CONFLICT(id) DO UPDATE SET
             unread = excluded.unread,
             starred = excluded.starred,
             title = excluded.title,
             body = excluded.body,
             last_modified = excluded.last_modified
        """,
        (
          item.get("id"),
          item.get("guid"),
          item.get("guidHash"),
          item.get("url"),
          item.get("title"),
          item.get("author"),
          item.get("pubDate"),
          item.get("updatedDate"),
          item.get("body"),
          item.get("enclosureMime"),
          item.get("enclosureLink"),
          item.get("mediaThumbnail"),
          item.get("mediaDescription"),
          item.get("feedId"),
          1 if item.get("unread") else 0,
          1 if item.get("starred") else 0,
          item.get("lastModified")
        )
      )

    conn.execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('latest_item_id', ?)", (str(max_id),))
    conn.execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('last_sync', ?)", (str(int(time.time())),))
    conn.execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('starred_count', ?)", (str(starred_count),))

  if notify and prev_max_id > 0 and new_unread_titles:
    count = len(new_unread_titles)
    title = f"OmanewsNC: {count} new article{'s' if count > 1 else ''}"
    body = new_unread_titles[0] if count == 1 else f"{new_unread_titles[0]} and {count - 1} more"
    command_output(["notify-send", "-a", "OmanewsNC", "-i", "news-feed", title, body])

  return True, ""


def query_status(client=None):
  conn = get_db()
  with conn:
    feed_row = conn.execute("SELECT SUM(unread_count) as total FROM feeds").fetchone()
    unread_count = feed_row["total"] if feed_row and feed_row["total"] is not None else 0

    if unread_count == 0:
      item_row = conn.execute("SELECT COUNT(*) as total FROM items WHERE unread = 1").fetchone()
      unread_count = item_row["total"] if item_row else 0

    meta_star = conn.execute("SELECT value FROM meta WHERE key = 'starred_count'").fetchone()
    starred_count = int(meta_star["value"]) if meta_star and meta_star["value"] else 0

    last_sync_row = conn.execute("SELECT value FROM meta WHERE key = 'last_sync'").fetchone()
    last_sync = int(last_sync_row["value"]) if last_sync_row and last_sync_row["value"] else 0

    folders = [dict(r) for r in conn.execute("SELECT * FROM folders ORDER BY name ASC").fetchall()]
    feeds = [dict(r) for r in conn.execute("SELECT * FROM feeds ORDER BY ordering ASC, title ASC").fetchall()]

    authenticated = client is not None
    auth_method = client.auth_source if client else "none"
    server_url = client.server_url if client else ""
    user = client.username if client else ""

    if not authenticated:
      desktop = read_desktop_account()
      if desktop:
        server_url = desktop.get("serverUrl", "")

    return {
      "ok": True,
      "authenticated": authenticated,
      "authMethod": auth_method,
      "serverUrl": server_url,
      "user": user,
      "unreadCount": int(unread_count),
      "starredCount": int(starred_count),
      "lastSync": last_sync,
      "folders": folders,
      "feeds": feeds,
    }


def query_items(feed_id=0, folder_id=0, starred_only=False, unread_only=False, limit=50, offset=0, search=""):
  conn = get_db()
  conditions = []
  params = []

  if starred_only:
    conditions.append("items.starred = 1")
  if unread_only:
    conditions.append("items.unread = 1")
  if feed_id > 0:
    conditions.append("items.feed_id = ?")
    params.append(feed_id)
  elif folder_id > 0:
    conditions.append("items.feed_id IN (SELECT id FROM feeds WHERE folder_id = ?)")
    params.append(folder_id)

  if search:
    conditions.append("(items.title LIKE ? OR items.author LIKE ? OR items.body LIKE ?)")
    pattern = f"%{search}%"
    params.extend([pattern, pattern, pattern])

  where_clause = ("WHERE " + " AND ".join(conditions)) if conditions else ""
  sql = f"""
    SELECT items.*, feeds.title as feed_title, feeds.favicon_link as feed_favicon
    FROM items
    LEFT JOIN feeds ON items.feed_id = feeds.id
    {where_clause}
    ORDER BY items.pub_date DESC
    LIMIT ? OFFSET ?
  """
  params.extend([limit, offset])

  with conn:
    rows = conn.execute(sql, params).fetchall()
    items = []
    for r in rows:
      d = dict(r)
      body = d.get("body") or ""
      clean_body = re.sub(r"<[^>]+>", " ", body)
      clean_body = re.sub(r"\s+", " ", clean_body).strip()
      clean_body = html.unescape(clean_body)
      d["snippet"] = clean_body[:200]
      if d.get("title"):
        d["title"] = html.unescape(d["title"])
      if d.get("author"):
        d["author"] = html.unescape(d["author"])
      items.append(d)
    return items


def mark_item_read(client, item_id, read=True):
  conn = get_db()
  with conn:
    conn.execute("UPDATE items SET unread = ? WHERE id = ?", (0 if read else 1, item_id))
    item = conn.execute("SELECT feed_id FROM items WHERE id = ?", (item_id,)).fetchone()
    if item:
      delta = -1 if read else 1
      conn.execute(
        "UPDATE feeds SET unread_count = MAX(0, unread_count + ?) WHERE id = ?",
        (delta, item["feed_id"])
      )

  if client:
    endpoint = f"/items/{item_id}/read" if read else f"/items/{item_id}/unread"
    client.request(endpoint, method="PUT")
  return True


def star_item(client, item_id, starred=True):
  conn = get_db()
  with conn:
    conn.execute("UPDATE items SET starred = ? WHERE id = ?", (1 if starred else 0, item_id))

  if client:
    endpoint = f"/items/{item_id}/star" if starred else f"/items/{item_id}/unstar"
    client.request(endpoint, method="PUT")
  return True


def mark_all_read(client, feed_id=0, folder_id=0):
  conn = get_db()
  with conn:
    max_row = conn.execute("SELECT MAX(id) as max_id FROM items").fetchone()
    newest_id = max_row["max_id"] if max_row and max_row["max_id"] else 0

    if feed_id > 0:
      conn.execute("UPDATE items SET unread = 0 WHERE feed_id = ?", (feed_id,))
      conn.execute("UPDATE feeds SET unread_count = 0 WHERE id = ?", (feed_id,))
      if client and newest_id > 0:
        client.request(f"/feeds/{feed_id}/read", method="PUT", json_body={"newestItemId": newest_id})
    elif folder_id > 0:
      conn.execute(
        "UPDATE items SET unread = 0 WHERE feed_id IN (SELECT id FROM feeds WHERE folder_id = ?)",
        (folder_id,)
      )
      conn.execute("UPDATE feeds SET unread_count = 0 WHERE folder_id = ?", (folder_id,))
      if client and newest_id > 0:
        client.request(f"/folders/{folder_id}/read", method="PUT", json_body={"newestItemId": newest_id})
    else:
      conn.execute("UPDATE items SET unread = 0")
      conn.execute("UPDATE feeds SET unread_count = 0")
      if client and newest_id > 0:
        client.request("/all/read", method="PUT", json_body={"newestItemId": newest_id})

  return True


def logout():
  if AUTH_FILE.is_file():
    try:
      AUTH_FILE.unlink()
    except OSError:
      pass
  if DB_PATH.is_file():
    try:
      DB_PATH.unlink()
    except OSError:
      pass
  return True


def main():
  parser = argparse.ArgumentParser(description="OmanewsNC Omarchy backend")
  parser.add_argument("--server-url", default="", help="Nextcloud server URL")
  parser.add_argument("--user", default="", help="Nextcloud user")
  parser.add_argument("--password", default="", help="Nextcloud password")
  parser.add_argument("--login-flow", action="store_true", help="Start browser sign-in flow")
  parser.add_argument("--logout", action="store_true", help="Clear direct login credentials")
  parser.add_argument("--sync", action="store_true", help="Sync latest feeds and articles")
  parser.add_argument("--no-notify", action="store_true", help="Suppress notification")
  parser.add_argument("--status", action="store_true", help="Print overall status")
  parser.add_argument("--items", action="store_true", help="Query items")
  parser.add_argument("--feed-id", type=int, default=0, help="Filter items by feed ID")
  parser.add_argument("--folder-id", type=int, default=0, help="Filter items by folder ID")
  parser.add_argument("--starred", action="store_true", help="Filter by starred")
  parser.add_argument("--unread", action="store_true", help="Filter by unread")
  parser.add_argument("--search", default="", help="Search filter")
  parser.add_argument("--limit", type=int, default=50, help="Items query limit")
  parser.add_argument("--offset", type=int, default=0, help="Items query offset")
  parser.add_argument("--mark-read", type=int, default=0, help="Mark item ID as read")
  parser.add_argument("--mark-unread", type=int, default=0, help="Mark item ID as unread")
  parser.add_argument("--star", type=int, default=0, help="Star item ID")
  parser.add_argument("--unstar", type=int, default=0, help="Unstar item ID")
  parser.add_argument("--mark-all-read", action="store_true", help="Mark all items read")
  parser.add_argument("--test-auth", action="store_true", help="Test authentication")

  args = parser.parse_args()

  if args.logout:
    logout()
    print(json.dumps({"ok": True, "action": "logout"}))
    sys.exit(0)

  if args.login_flow:
    server = args.server_url
    if not server:
      desktop = read_desktop_account()
      server = desktop.get("serverUrl", "") if desktop else ""
    if not server:
      print(json.dumps({"ok": False, "error": "Server URL required for login flow"}))
      sys.exit(1)

    ok, res = start_login_flow(server)
    if ok:
      # Sync feeds right after successful login
      client, _ = get_client()
      if client:
        sync_all(client, notify=False)
      print(json.dumps({"ok": True, "user": res.get("username"), "serverUrl": res.get("serverUrl")}))
      sys.exit(0)
    else:
      print(json.dumps({"ok": False, "error": res}))
      sys.exit(1)

  client, auth_err = get_client(args)

  if args.test_auth:
    if not client:
      print(json.dumps({"ok": False, "error": auth_err}))
      sys.exit(1)
    status_code, data = client.request("/version")
    if status_code == 200:
      print(json.dumps({
        "ok": True,
        "serverUrl": client.server_url,
        "user": client.username,
        "authSource": client.auth_source,
        "version": data.get("version")
      }))
    else:
      print(json.dumps({"ok": False, "status": status_code, "error": data.get("message", "Auth failed")}))
    sys.exit(0)

  if args.mark_read > 0:
    mark_item_read(client, args.mark_read, read=True)
    print(json.dumps({"ok": True, "action": "mark_read", "id": args.mark_read}))
    sys.exit(0)

  if args.mark_unread > 0:
    mark_item_read(client, args.mark_unread, read=False)
    print(json.dumps({"ok": True, "action": "mark_unread", "id": args.mark_unread}))
    sys.exit(0)

  if args.star > 0:
    star_item(client, args.star, starred=True)
    print(json.dumps({"ok": True, "action": "star", "id": args.star}))
    sys.exit(0)

  if args.unstar > 0:
    star_item(client, args.unstar, starred=False)
    print(json.dumps({"ok": True, "action": "unstar", "id": args.unstar}))
    sys.exit(0)

  if args.mark_all_read:
    mark_all_read(client, feed_id=args.feed_id, folder_id=args.folder_id)
    print(json.dumps({"ok": True, "action": "mark_all_read"}))
    sys.exit(0)

  if args.sync:
    if not client:
      print(json.dumps({"ok": False, "error": auth_err}))
      sys.exit(1)
    ok, sync_err = sync_all(client, notify=not args.no_notify)
    if not ok:
      print(json.dumps({"ok": False, "error": sync_err}))
      sys.exit(1)
    status = query_status(client)
    print(json.dumps(status))
    sys.exit(0)

  if args.items:
    items = query_items(
      feed_id=args.feed_id,
      folder_id=args.folder_id,
      starred_only=args.starred,
      unread_only=args.unread,
      limit=args.limit,
      offset=args.offset,
      search=args.search
    )
    print(json.dumps({"ok": True, "items": items}))
    sys.exit(0)

  # Status default
  status = query_status(client)
  print(json.dumps(status))


if __name__ == "__main__":
  main()
