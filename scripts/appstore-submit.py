#!/usr/bin/env python3
"""Create an App Store version, attach the latest TestFlight build, set
release notes, and (optionally) submit for review.

Two-step intentionally: the default run prepares the draft (idempotent —
re-run is safe) but does NOT submit for review. Re-run with SUBMIT=1 to
trigger the actual review submission, which is one-shot and bills against
Apple's queue.

Required env (same shape as testflight.sh):
  ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH
  BUILD_NUMBER   build to attach (e.g. 202605281541)
Optional env:
  BUNDLE_ID      default app.flark.bogota
  VERSION        default 1.1.1
  SUBMIT=1       actually submit for review after the draft is ready
"""
import os
import sys
import time
from pathlib import Path

import jwt
import requests

# ---- copy ----------------------------------------------------------------
# Edit here, NOT in App Store Connect web UI, so the source of truth lives
# with the code that ships the build.
ZH_NOTES = """- 话题详情内嵌精简回复栏，发字 / 表情 / 图片不再需要打开完整编辑器
- 多 Space 切换：左滑边缘呼出，启动时回到上次打开的 Space
- iPad 三栏布局：Spaces / 话题 / 详情同框
- 通过 flark:// 链接分享、接受 WebDAV Space 邀请
- 同步进度内嵌顶部导航栏；下拉刷新更安静
- 英文界面文案补全"""

EN_NOTES = """- Inline reply composer in topic detail — type, drop emoji or photos without opening a sheet
- Multi-space switching: edge-swipe to open, last space restored on launch
- iPad three-column layout: Spaces / Topics / Detail
- Share and accept WebDAV space invites via flark:// links
- Sync progress lives in the nav bar; pull-to-refresh is now silent
- English UI fully translated"""

# ---- env -----------------------------------------------------------------
KEY_ID = os.environ["ASC_KEY_ID"]
ISSUER_ID = os.environ["ASC_ISSUER_ID"]
KEY_PATH = os.environ["ASC_KEY_PATH"]
BUNDLE_ID = os.environ.get("BUNDLE_ID", "app.flark.bogota")
VERSION = os.environ.get("VERSION", "1.1.1")
BUILD_NUMBER = os.environ["BUILD_NUMBER"]
DO_SUBMIT = os.environ.get("SUBMIT") == "1"

API = "https://api.appstoreconnect.apple.com"


def jwt_token() -> str:
    """Sign a 10-minute JWT for App Store Connect API."""
    payload = {
        "iss": ISSUER_ID,
        "exp": int(time.time()) + 600,
        "aud": "appstoreconnect-v1",
    }
    headers = {"kid": KEY_ID, "typ": "JWT"}
    pem = Path(KEY_PATH).read_text()
    return jwt.encode(payload, pem, algorithm="ES256", headers=headers)


def asc(method: str, path: str, **kwargs):
    """ASC call with bearer auth + error surfacing."""
    headers = {
        "Authorization": f"Bearer {jwt_token()}",
        "Content-Type": "application/json",
    }
    if "headers" in kwargs:
        headers.update(kwargs.pop("headers"))
    url = path if path.startswith("http") else API + path
    r = requests.request(method, url, headers=headers, timeout=30, **kwargs)
    if not r.ok:
        sys.stderr.write(f"\n!! {method} {path} -> {r.status_code}\n{r.text}\n")
        r.raise_for_status()
    return r.json() if r.text else None


# 1. Resolve app
print(f"▸ resolving app {BUNDLE_ID}")
r = asc("GET", f"/v1/apps?filter[bundleId]={BUNDLE_ID}")
if not r["data"]:
    raise SystemExit(f"App {BUNDLE_ID} not found under this team")
app_id = r["data"][0]["id"]
print(f"  appId = {app_id}")

# 2. Find or create the version
print(f"▸ looking for an existing {VERSION} (iOS) version")
r = asc(
    "GET",
    f"/v1/apps/{app_id}/appStoreVersions"
    f"?filter[versionString]={VERSION}&filter[platform]=IOS",
)
existing = r["data"]
EDITABLE = {
    "PREPARE_FOR_SUBMISSION",
    "DEVELOPER_REJECTED",
    "REJECTED",
    "INVALID_BINARY",
    "METADATA_REJECTED",
    "WAITING_FOR_REVIEW",  # can withdraw + edit
    "DEVELOPER_REMOVED_FROM_SALE",
}
if existing:
    version_id = existing[0]["id"]
    state = existing[0]["attributes"]["appStoreState"]
    print(f"  found, id={version_id}, state={state}")
    if state not in EDITABLE:
        raise SystemExit(
            f"Version {VERSION} is in state {state} — already submitted / "
            f"approved / live. Bump VERSION or remove this submission first."
        )
else:
    print(f"▸ creating new {VERSION} version")
    body = {
        "data": {
            "type": "appStoreVersions",
            "attributes": {
                "platform": "IOS",
                "versionString": VERSION,
            },
            "relationships": {
                "app": {"data": {"type": "apps", "id": app_id}}
            },
        }
    }
    r = asc("POST", "/v1/appStoreVersions", json=body)
    version_id = r["data"]["id"]
    print(f"  created, id={version_id}")

# 3. Set release notes per locale (create or update each)
print("▸ listing existing version localizations")
r = asc(
    "GET",
    f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations?limit=200",
)
locs = {loc["attributes"]["locale"]: loc["id"] for loc in r["data"]}
print(f"  locales present: {sorted(locs.keys())}")


def set_whats_new(locale: str, notes: str) -> None:
    if locale in locs:
        loc_id = locs[locale]
        body = {
            "data": {
                "type": "appStoreVersionLocalizations",
                "id": loc_id,
                "attributes": {"whatsNew": notes},
            }
        }
        asc("PATCH", f"/v1/appStoreVersionLocalizations/{loc_id}", json=body)
        print(f"  ✓ updated {locale}")
    else:
        body = {
            "data": {
                "type": "appStoreVersionLocalizations",
                "attributes": {"locale": locale, "whatsNew": notes},
                "relationships": {
                    "appStoreVersion": {
                        "data": {"type": "appStoreVersions", "id": version_id}
                    }
                },
            }
        }
        asc("POST", "/v1/appStoreVersionLocalizations", json=body)
        print(f"  ✓ created {locale}")


print("▸ writing What's New")
set_whats_new("zh-Hans", ZH_NOTES)
set_whats_new("en-US", EN_NOTES)

# 4. Find the build, polling until VALID
print(f"▸ waiting for build {BUILD_NUMBER} to finish processing")
build_id = None
for attempt in range(60):  # ~30 minutes
    r = asc(
        "GET",
        f"/v1/builds?filter[app]={app_id}"
        f"&filter[version]={BUILD_NUMBER}&limit=1",
    )
    if r["data"]:
        b = r["data"][0]
        proc = b["attributes"].get("processingState", "?")
        valid = b["attributes"].get("valid")
        print(f"  attempt {attempt + 1}: processingState={proc} valid={valid}")
        if proc == "VALID":
            build_id = b["id"]
            break
    else:
        print(f"  attempt {attempt + 1}: build not yet visible to ASC")
    time.sleep(30)

if not build_id:
    raise SystemExit(
        "Build never reached VALID state. Check App Store Connect "
        "→ TestFlight for any processing issue."
    )

# 5. Attach build to version
print(f"▸ attaching build {build_id}")
body = {"data": {"type": "builds", "id": build_id}}
asc("PATCH", f"/v1/appStoreVersions/{version_id}/relationships/build", json=body)
print("  ✓ build linked")

print()
print("✅ Draft ready in App Store Connect.")
print(
    f"   https://appstoreconnect.apple.com/apps/{app_id}/appstore/ios/version/inflight"
)

if not DO_SUBMIT:
    print()
    print("ℹ Submit step skipped. Set SUBMIT=1 to send for review:")
    print(
        f"   SUBMIT=1 BUILD_NUMBER={BUILD_NUMBER} "
        f"VERSION={VERSION} ./scripts/appstore-submit.py"
    )
    sys.exit(0)

# 6. Create + submit review submission
print()
print("▸ creating review submission")
body = {
    "data": {
        "type": "reviewSubmissions",
        "attributes": {"platform": "IOS"},
        "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
    }
}
r = asc("POST", "/v1/reviewSubmissions", json=body)
submission_id = r["data"]["id"]
print(f"  submission id = {submission_id}")

print("▸ adding the version as a submission item")
body = {
    "data": {
        "type": "reviewSubmissionItems",
        "relationships": {
            "reviewSubmission": {
                "data": {"type": "reviewSubmissions", "id": submission_id}
            },
            "appStoreVersion": {
                "data": {"type": "appStoreVersions", "id": version_id}
            },
        },
    }
}
asc("POST", "/v1/reviewSubmissionItems", json=body)

print("▸ submitting for review (irreversible)")
body = {
    "data": {
        "type": "reviewSubmissions",
        "id": submission_id,
        "attributes": {"submitted": True},
    }
}
asc("PATCH", f"/v1/reviewSubmissions/{submission_id}", json=body)
print()
print("🎉 Submitted for App Store review.")
