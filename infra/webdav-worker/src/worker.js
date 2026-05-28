// Minimal WebDAV server backed by an R2 bucket, protected by HTTP Basic auth.
// Implements only the verbs the Flark iOS app uses:
//   OPTIONS, PROPFIND (Depth 0|1), GET (with If-None-Match → 304),
//   HEAD, PUT (with If-None-Match: * or If-Match: <etag>), MKCOL, DELETE.
//
// "Directories" are represented as zero-byte marker objects whose key
// ends with "/". Listings combine real children (objects under the
// prefix) with delimitedPrefixes (virtual subtrees that only exist
// because something underneath them does).

const ENC = new TextEncoder();

function timingSafeEq(a, b) {
  const ab = ENC.encode(a);
  const bb = ENC.encode(b);
  if (ab.length !== bb.length) return false;
  let r = 0;
  for (let i = 0; i < ab.length; i++) r |= ab[i] ^ bb[i];
  return r === 0;
}

function unauthorized() {
  return new Response("Unauthorized", {
    status: 401,
    headers: { "WWW-Authenticate": 'Basic realm="flark-webdav"' },
  });
}

function checkAuth(req, env) {
  const h = req.headers.get("authorization") || "";
  if (!h.startsWith("Basic ")) return false;
  let dec;
  try { dec = atob(h.slice(6)); } catch { return false; }
  const i = dec.indexOf(":");
  if (i < 0) return false;
  return timingSafeEq(dec.slice(0, i), env.DAV_USER)
      && timingSafeEq(dec.slice(i + 1), env.DAV_PASS);
}

function urlToKey(url) {
  const u = new URL(url);
  let p = decodeURIComponent(u.pathname);
  if (p.startsWith("/")) p = p.slice(1);
  return p; // may end with "/" for collections; may be "" for root
}

function hrefFor(key) {
  const trailing = key.endsWith("/");
  const segs = key.split("/").filter(Boolean).map(encodeURIComponent);
  return "/" + segs.join("/") + (trailing && segs.length ? "/" : "");
}

function xmlEscape(s) {
  return String(s).replace(/[<>&"']/g, (c) => ({
    "<": "&lt;", ">": "&gt;", "&": "&amp;", '"': "&quot;", "'": "&apos;",
  }[c]));
}

function entry(href, isCollection, etag, size, mtime) {
  const propEtag = etag ? `<D:getetag>${xmlEscape(etag)}</D:getetag>` : "";
  const propLen = size != null ? `<D:getcontentlength>${size}</D:getcontentlength>` : "";
  const propMod = mtime ? `<D:getlastmodified>${xmlEscape(mtime)}</D:getlastmodified>` : "";
  return `<D:response>`
       + `<D:href>${xmlEscape(href)}</D:href>`
       + `<D:propstat><D:prop>`
       + `<D:resourcetype>${isCollection ? "<D:collection/>" : ""}</D:resourcetype>`
       + propEtag + propLen + propMod
       + `</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>`
       + `</D:response>`;
}

function multistatus(parts) {
  const xml = `<?xml version="1.0" encoding="utf-8"?>\n`
            + `<D:multistatus xmlns:D="DAV:">\n${parts.join("\n")}\n</D:multistatus>`;
  return new Response(xml, {
    status: 207,
    headers: { "content-type": 'application/xml; charset="utf-8"' },
  });
}

// Strip quotes / weak-prefix from an ETag header so it can be passed to R2.
function normEtag(t) {
  if (!t) return t;
  return t.replace(/^W\//, "").replace(/^"(.*)"$/, "$1");
}

async function handlePropfind(req, env) {
  const rawKey = urlToKey(req.url);
  const depth = req.headers.get("depth") || "1";

  // Root listing.
  if (rawKey === "" || rawKey === "/") {
    const listing = await env.BUCKET.list({ prefix: "", delimiter: "/", limit: 1000 });
    const parts = [entry("/", true, null, null, null)];
    if (depth !== "0") {
      for (const o of listing.objects) {
        const isDir = o.key.endsWith("/");
        parts.push(entry(hrefFor(o.key), isDir,
          isDir ? null : o.httpEtag,
          isDir ? null : o.size,
          o.uploaded.toUTCString()));
      }
      for (const p of listing.delimitedPrefixes) {
        if (!listing.objects.some(o => o.key === p)) {
          parts.push(entry(hrefFor(p), true, null, null, null));
        }
      }
    }
    return multistatus(parts);
  }

  // Path without trailing slash: could be either a file or a dir-as-prefix.
  // Try file first; fall through to dir lookup if it isn't one.
  if (!rawKey.endsWith("/")) {
    const obj = await env.BUCKET.head(rawKey);
    if (obj) {
      return multistatus([
        entry(hrefFor(rawKey), false, obj.httpEtag, obj.size, obj.uploaded.toUTCString()),
      ]);
    }
  }

  const dirKey = rawKey.endsWith("/") ? rawKey : rawKey + "/";
  const marker = await env.BUCKET.head(dirKey);
  const listing = await env.BUCKET.list({ prefix: dirKey, delimiter: "/", limit: 1000 });
  const hasChildren = listing.objects.some(o => o.key !== dirKey)
                   || listing.delimitedPrefixes.length > 0;
  if (!marker && !hasChildren) {
    return new Response("Not Found", { status: 404 });
  }

  const parts = [entry(hrefFor(dirKey), true, null, null, null)];
  if (depth !== "0") {
    for (const o of listing.objects) {
      if (o.key === dirKey) continue;
      const isDir = o.key.endsWith("/");
      parts.push(entry(hrefFor(o.key), isDir,
        isDir ? null : o.httpEtag,
        isDir ? null : o.size,
        o.uploaded.toUTCString()));
    }
    for (const p of listing.delimitedPrefixes) {
      if (!listing.objects.some(o => o.key === p)) {
        parts.push(entry(hrefFor(p), true, null, null, null));
      }
    }
  }
  return multistatus(parts);
}

async function handleGet(req, env, headOnly) {
  const key = urlToKey(req.url);
  if (!key || key.endsWith("/")) return new Response("Bad Request", { status: 400 });
  const inm = normEtag(req.headers.get("if-none-match"));

  // Implement If-None-Match by reading the current object's etag ourselves
  // and comparing. R2's onlyIf.etagDoesNotMatch is finicky about quoted vs
  // unquoted forms, and a single head() costs the same as a conditional GET
  // when the etags do match (which is the cache-hit path we care about).
  if (inm) {
    const head = await env.BUCKET.head(key);
    if (!head) return new Response("Not Found", { status: 404 });
    if (normEtag(head.httpEtag) === normEtag(inm)) {
      return new Response(null, { status: 304, headers: { etag: head.httpEtag } });
    }
    if (headOnly) return objectResponse(head, true);
    const obj2 = await env.BUCKET.get(key);
    if (!obj2) return new Response("Not Found", { status: 404 });
    return objectResponse(obj2, false);
  }

  const obj = headOnly ? await env.BUCKET.head(key) : await env.BUCKET.get(key);
  if (!obj) return new Response("Not Found", { status: 404 });
  return objectResponse(obj, headOnly);
}

function objectResponse(obj, headOnly) {
  const h = new Headers();
  h.set("etag", obj.httpEtag);
  h.set("content-length", String(obj.size));
  h.set("content-type", obj.httpMetadata?.contentType || "application/octet-stream");
  h.set("last-modified", obj.uploaded.toUTCString());
  if (headOnly || !("body" in obj)) return new Response(null, { status: 200, headers: h });
  return new Response(obj.body, { status: 200, headers: h });
}

async function handlePut(req, env) {
  const key = urlToKey(req.url);
  if (!key || key.endsWith("/")) return new Response("Bad Request", { status: 400 });

  const inm = req.headers.get("if-none-match");
  const im = normEtag(req.headers.get("if-match"));

  if (inm === "*") {
    // Create-only semantics — R2 has no native onlyIf for "absent", so
    // serialize against a head() check. Two racing PUTs against the same
    // new key can both win here; for the Flark write pattern (unique
    // per-author / per-event filenames) that is acceptable.
    const existing = await env.BUCKET.head(key);
    if (existing) return new Response("Precondition Failed", { status: 412 });
  }

  const opts = im ? { onlyIf: { etagMatches: im } } : undefined;
  const body = await req.arrayBuffer();
  const ct = req.headers.get("content-type") || undefined;
  const httpMetadata = ct ? { contentType: ct } : undefined;
  const result = await env.BUCKET.put(key, body, { ...opts, httpMetadata });
  if (result === null) return new Response("Precondition Failed", { status: 412 });

  // Make sure any ancestor "directory" markers exist so PROPFIND of the
  // parents reports a collection without needing a separate MKCOL.
  await ensureMarkers(env, key);

  return new Response(null, { status: 201, headers: { etag: result.httpEtag } });
}

async function ensureMarkers(env, key) {
  const parts = key.split("/");
  parts.pop(); // drop file segment
  let acc = "";
  for (const seg of parts) {
    if (!seg) continue;
    acc += seg + "/";
    // best-effort, ignore race conditions
    const h = await env.BUCKET.head(acc);
    if (!h) await env.BUCKET.put(acc, new Uint8Array(0));
  }
}

async function handleMkcol(req, env) {
  let key = urlToKey(req.url);
  if (!key) return new Response("Method Not Allowed", { status: 405 });
  if (!key.endsWith("/")) key += "/";
  const h = await env.BUCKET.head(key);
  if (h) return new Response("Method Not Allowed", { status: 405 });
  await env.BUCKET.put(key, new Uint8Array(0));
  return new Response(null, { status: 201 });
}

async function handleDelete(req, env) {
  const key = urlToKey(req.url);
  if (!key) return new Response("Forbidden", { status: 403 });

  if (key.endsWith("/")) {
    // Recursive — paginate through all keys under the prefix.
    let cursor;
    do {
      const list = await env.BUCKET.list({ prefix: key, limit: 1000, cursor });
      const keys = list.objects.map(o => o.key);
      if (keys.length) await env.BUCKET.delete(keys);
      cursor = list.truncated ? list.cursor : undefined;
    } while (cursor);
    return new Response(null, { status: 204 });
  }

  await env.BUCKET.delete(key);
  return new Response(null, { status: 204 });
}

function handleOptions() {
  return new Response(null, {
    status: 200,
    headers: {
      allow: "OPTIONS, GET, HEAD, PUT, DELETE, MKCOL, PROPFIND",
      dav: "1, 2",
    },
  });
}

export default {
  async fetch(req, env) {
    if (!checkAuth(req, env)) return unauthorized();
    try {
      switch (req.method.toUpperCase()) {
        case "OPTIONS":   return handleOptions();
        case "GET":       return handleGet(req, env, false);
        case "HEAD":      return handleGet(req, env, true);
        case "PUT":       return handlePut(req, env);
        case "DELETE":    return handleDelete(req, env);
        case "MKCOL":     return handleMkcol(req, env);
        case "PROPFIND":  return handlePropfind(req, env);
        default:
          return new Response("Method Not Allowed", {
            status: 405,
            headers: { allow: "OPTIONS, GET, HEAD, PUT, DELETE, MKCOL, PROPFIND" },
          });
      }
    } catch (e) {
      return new Response("Internal Error: " + (e?.message || String(e)), { status: 500 });
    }
  },
};
