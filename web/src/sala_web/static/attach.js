"use strict";
/* The attachment part of a chat composer, on its own: the attach button (and the Android two-entry menu), the chips of what is
   attached, the upload of each file, the shrink of a big image, drag and drop, and the paste de-duplication. It uses nothing of
   the page it is in (no app.js global): the page hands over a config object and gets a handle back. Styled by attach.css.

     const att = SalaAttach.create(hostEl, {
       endpoint,        // the upload address; an image is POSTed to it whole, any other file to <endpoint>?name=<its name> (default "api/upload")
       fetch,           // the page's own (authenticated) fetch, used for an image's upload (default window.fetch)
       limits,          // {perFile, perImageSource, maxFiles, totalBytes, reencodeOver}: bytes; maxFiles and totalBytes are unlimited by default
       onChange,        // (uploads) after the chips were drawn: the page's send button reads uploads here
       onChosen,        // (file) for each file the owner chose, pasted or dropped, before it is attached
       onStatus,        // (message | () => message, kind) a notice such as an upload that failed; kind "error". Default: a line under the chips
       onUnauthorized,  // () a file upload came back 401: the page checks its sign-in
       t,               // (key, vars) -> text; the keys are DEFAULT_WORDS' (English). A key the page does not know falls back to English
       isBusy,          // () -> true while the page is sending: the attach button is disabled and does nothing
       dropTarget,      // the element drag and drop is watched on (the page's window); none: no drop handling
       chipsEl,         // the element the chips are drawn in (default: a new one put before hostEl)
       renderSend,      // (slotEl) the page puts its own send button in the slot, which is the last child of hostEl
     });
     handle: getUploads(), clear(), add(files), isUploading(), bindPaste(editableEl), and for a page with its own editor:
             handlePaste(e), handleBeforeInput(e), seenInEarlierLink(link, file, at), addImage(file), restore(entries),
             render(), refresh(), limits

   hostEl gets, at its start, the attach button, its menu and the two hidden file inputs, in this order. */
(function () {
  if (window.SalaAttach) return;

  const MB = 1024 * 1024;
  const DEFAULT_WORDS = {
    "app.up.attached": "attached image",
    "app.up.failed": "Upload failed: {name}: {msg}",
    "app.up.failedMeta": "Failed: {error}",
    "app.up.file": "Attached file {name}",
    "app.up.imgEmpty": "That image came through empty. Try attaching it again.",
    "app.up.imgFailed": "Image upload failed: {msg}",
    "app.up.imgTooBig": "This image is {size}, over the {limit} limit, and could not be made small enough to attach.",
    "app.up.lost": "the connection was lost",
    "app.up.noFile": "no file",
    "app.up.notAttached": "Not attached: {what} (png, jpeg, gif or webp only).",
    "app.up.progress": "Uploading {pct}% of {size}",
    "app.up.readFailed": "Could not read the inserted image: {msg}",
    "app.up.remove": "Remove {name}",
    "app.up.removeImage": "Remove image",
    "app.up.tooLarge": "too large ({size}; the limit is {max})",
    "app.up.unknownType": "unknown type",
    "ui.cmp.attach": "Attach files",
    "ui.cmp.menu": "Attach menu",
    "ui.cmp.photos": "Photos and videos",
    "ui.cmp.files": "Files and camera",
    "attach.tooMany": "Not attached: at most {max} files.",
    "attach.totalTooBig": "Not attached: the files together would be over {max}.",
  };
  const fill = (s, vars) => String(s).replace(/\{(\w+)\}/g, (m, k) => (vars && vars[k] != null ? vars[k] : m));

  const h = (tag, attrs = {}, ...kids) => {
    const n = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs)) {
      if (v == null || v === false) continue;
      if (k === "class") n.className = v;
      else if (k === "text") n.textContent = v;
      else if (k.startsWith("on")) n.addEventListener(k.slice(2), v);
      else n.setAttribute(k, v === true ? "" : v);
    }
    for (const c of kids) if (c != null) n.append(c);
    return n;
  };

  const ATTACH_ICON = '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M16 8l-7 7a2 2 0 0 0 3 3l7.5-7.5a4 4 0 0 0-6-6L6 12a6 6 0 0 0 8.5 8.5l6-6"/></svg>';

  // ---- pure helpers (no page state) ----
  function humanSize(n) {
    if (!(n >= 0)) return "";
    if (n < 1024) return n + " B";
    const units = ["KB", "MB", "GB"];
    let v = n / 1024, i = 0;
    while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
    return (v >= 10 ? Math.round(v) : v.toFixed(1)) + " " + units[i];
  }
  function fileIcon() {
    const ns = "http://www.w3.org/2000/svg";
    const svg = document.createElementNS(ns, "svg");
    svg.setAttribute("viewBox", "0 0 20 20"); svg.setAttribute("width", "20"); svg.setAttribute("height", "20");
    svg.setAttribute("class", "fc-icon"); svg.setAttribute("aria-hidden", "true");
    const path = document.createElementNS(ns, "path");
    path.setAttribute("d", "M5 2.5h6.5L15 6v11.5H5zM11.5 2.5V6H15");
    path.setAttribute("fill", "none"); path.setAttribute("stroke", "currentColor");
    path.setAttribute("stroke-width", "1.4"); path.setAttribute("stroke-linejoin", "round");
    svg.append(path);
    return svg;
  }

  // An image goes up whole when it is within the limit (limits.perImageSource), its long side is at
  // most IMAGE_MAX_SIDE px, and it is not a big PNG or WebP (below). Otherwise it is redrawn on a canvas at that size and
  // re-encoded before it is sent: Claude scales an image down itself, so the session sees the same picture. PNG is kept only
  // when a pixel is not opaque (JPEG has no alpha, so the see-through parts would turn solid); every other image becomes a
  // JPEG, which is far smaller for a photo or a screenshot. A result still over the limit steps the quality down (JPEG) and
  // then the size, and an image that cannot be made to fit is refused in words (app.up.imgTooBig).
  // A big PNG or WebP is re-encoded as a JPEG even when it fits the limit: the pane's Claude Code takes an image of at most
  // 5 MB as base64 (3.75 MB of bytes) and 2000 px a side, shrinks a bigger one itself and drops the image when that fails; a
  // Ctrl+V of a 3000 x 4000 photo hands over its pixels as a PNG of 19 MB (the photo's own file was 5 MB of JPEG), which
  // the session never received. A photo or a screenshot is a fraction of that as a JPEG; a PNG that holds a see-through pixel
  // stays as it is (the check reads the pixels), and so does a JPEG or a GIF (a GIF would lose its animation).
  // limits.reencodeOver: a PNG or WebP over this many bytes is re-encoded as a JPEG when it has no see-through pixel
  const IMAGE_MAX_SIDE = 4000;               // under the 4096 px side that mobile canvases allow (16.7 MP)
  const JPEG_QUALITIES = [0.92, 0.85, 0.75, 0.6];
  const SHRINK_STEP = 0.75;                  // each further size step keeps this share of the side
  const MIN_SIDE = 320;                      // below this the picture is of no use: give up

  // The picture's pixels, upright (the EXIF turn applied), or null when the browser cannot decode the file.
  async function decodeImage(blob) {
    try {
      if (window.createImageBitmap) return await createImageBitmap(blob, { imageOrientation: "from-image" });
    } catch (e) { /* fall through to an <img>, which also applies the turn */ }
    const url = URL.createObjectURL(blob);
    try {
      const img = new Image();
      img.src = url;
      await img.decode();
      return img;
    } catch (e) {
      return null;
    } finally {
      URL.revokeObjectURL(url);
    }
  }
  const imageSide = (img) => ({ w: img.naturalWidth || img.width, h: img.naturalHeight || img.height });

  // True when any pixel is not fully opaque: read in strips, so a 16 MP canvas is never copied out whole.
  function hasTransparency(ctx, w, h) {
    const strip = Math.max(1, Math.floor(1048576 / w));  // about 1M pixels (4 MB) a read
    for (let y = 0; y < h; y += strip) {
      const d = ctx.getImageData(0, y, w, Math.min(strip, h - y)).data;
      for (let i = 3; i < d.length; i += 4) if (d[i] !== 255) return true;
    }
    return false;
  }
  const canvasBlob = (canvas, type, quality) => new Promise((res) => canvas.toBlob(res, type, quality));

  // The image as it should be sent: the file itself when it needs no shrink, a smaller File when it does, and null when it
  // cannot be made to fit the limit. A file the browser cannot decode goes up as it is when it is within the limit (the
  // server takes it, as before), and counts as one that cannot be made to fit when it is over.
  async function fitImage(file, limits) {
    const asIs = () => (file.size <= limits.perImageSource ? file : null);
    const img = await decodeImage(file);
    if (!img) return asIs();
    const canvas = document.createElement("canvas");
    try {
      const { w: sw, h: sh } = imageSide(img);
      if (!sw || !sh) return asIs();
      const bigLossless = (file.type === "image/png" || file.type === "image/webp") && file.size > limits.reencodeOver;
      if (file.size <= limits.perImageSource && Math.max(sw, sh) <= IMAGE_MAX_SIDE && !bigLossless) return file;
      let scale = Math.min(1, IMAGE_MAX_SIDE / Math.max(sw, sh));
      let png = null;  // decided on the first draw: the pixels do not change between sizes
      for (;;) {
        const w = Math.max(1, Math.round(sw * scale)), h = Math.max(1, Math.round(sh * scale));
        if (Math.max(w, h) < Math.min(MIN_SIDE, Math.max(sw, sh))) return null;
        canvas.width = w; canvas.height = h;
        const ctx = canvas.getContext("2d", { willReadFrequently: true });
        ctx.imageSmoothingQuality = "high";
        ctx.drawImage(img, 0, 0, w, h);
        if (png === null) {
          png = file.type !== "image/jpeg" && hasTransparency(ctx, w, h);
          // a see-through PNG that is only big, not over the limit or too wide, keeps its alpha as it is
          if (png && file.size <= limits.perImageSource && Math.max(sw, sh) <= IMAGE_MAX_SIDE) return file;
        }
        const type = png ? "image/png" : "image/jpeg";
        const made = (blob) => new File([blob], (file.name || "image").replace(/\.[^./\\]+$/, "") + (png ? ".png" : ".jpg"), { type });
        // a big PNG or WebP is steered to limits.reencodeOver by the quality steps, at the same size in pixels; when no step gets
        // there, the smallest result within the limit goes up, never a smaller picture for a size the pane shrinks itself
        const soft = !png && bigLossless ? Math.min(limits.perImageSource, limits.reencodeOver) : limits.perImageSource;
        let best = null;
        for (const q of png ? [undefined] : JPEG_QUALITIES) {
          const blob = await canvasBlob(canvas, type, q);
          if (!blob || blob.type !== type) return asIs();  // a browser without that encoder
          if (blob.size > limits.perImageSource) continue;
          // a re-encode no smaller than a file the server takes anyway is not worth sending
          if (file.size <= limits.perImageSource && blob.size >= file.size) continue;
          if (blob.size <= soft) return made(blob);
          if (!best || blob.size < best.size) best = blob;
        }
        if (best) return made(best);
        if (file.size <= limits.perImageSource) return file;
        scale *= SHRINK_STEP;
      }
    } finally {
      if (img.close) img.close();
      canvas.width = canvas.height = 0;
    }
  }

  // The file's bytes, read once more when the first read comes back empty (a picker or a clipboard sometimes hands over a
  // File whose bytes are not ready yet); an empty second read is the browser's, not the server's.
  async function readImageBytes(file) {
    let buf = await file.arrayBuffer();
    if (!buf.byteLength) {
      await new Promise((r) => setTimeout(r, 150));
      buf = await file.arrayBuffer();
    }
    return buf;
  }

  // A file with no name (an Android keyboard's or a share sheet's blob) is named from its type: pasted-<time>.<ext>, .bin
  // when the type says nothing; the server makes the name safe all the same (safe_upload_name).
  const NAME_EXT = { "video/mp4": "mp4", "video/webm": "webm", "video/quicktime": "mov", "audio/mpeg": "mp3", "audio/mp4": "m4a", "audio/ogg": "ogg",
                     "audio/wav": "wav", "application/pdf": "pdf", "application/zip": "zip", "application/json": "json", "text/plain": "txt",
                     "text/markdown": "md", "text/csv": "csv", "text/html": "html", "image/heic": "heic", "image/heif": "heif",
                     "image/avif": "avif", "image/bmp": "bmp", "image/svg+xml": "svg", "image/png": "png", "image/jpeg": "jpg",
                     "image/gif": "gif", "image/webp": "webp" };
  function attachmentName(file) {
    if ((file.name || "").trim()) return file.name;
    const type = (file.type || "").split(";")[0].trim().toLowerCase();
    return `pasted-${Date.now()}.${NAME_EXT[type] || "bin"}`;
  }

  // An image whose type the keyboard did not give: told by its first bytes (the four types the server takes as images)
  async function sniffImageType(blob) {
    const b = new Uint8Array(await blob.slice(0, 12).arrayBuffer());
    const at = (i, str) => [...str].every((c, k) => b[i + k] === c.charCodeAt(0));
    if (b[0] === 0x89 && at(1, "PNG")) return "image/png";
    if (b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return "image/jpeg";
    if (at(0, "GIF8")) return "image/gif";
    if (at(0, "RIFF") && at(8, "WEBP")) return "image/webp";
    return "";
  }
  const IMAGE_EXT = { "image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp" };

  // Pasted images are clipboardData.files: it holds one File per item of kind "file", the same objects on every read
  // (HTML spec, [SameObject]); clipboardData.items is read only when files is empty, a net for a browser that fills
  // items alone. Reading both and deduplicating the File objects by their fields attached two chips for one paste
  // (on Android Chrome, and the same on a desktop Chrome): Chromium 155 makes a new File for every
  // items[i].getAsFile() call, "image.png" with lastModified = the time of the call, so the File in files (made when
  // the event was built) and the one getAsFile() returned differed by a few ms, and no field told them apart
  // (web/tests/test_composer_attach.py).
  function clipboardFiles(cd) {
    if (!cd) return [];
    const files = [...(cd.files || [])];
    if (!files.length) for (const i of cd.items || []) if (i.kind === "file") { const f = i.getAsFile(); if (f) files.push(f); }
    return files;
  }
  const clipboardImages = (cd) => clipboardFiles(cd).filter((f) => f.type.startsWith("image/"));
  // What beforeinput takes (it takes every file now; that broke the Android keyboard's image: its clipboard,
  // image suggestions, stickers and GIFs reach the editable through commitContent as an insertion carrying a File of NO
  // TYPE, or no bytes; before, clipboardImages() filtered it out, the browser inserted the <img> itself and liftImage
  // attached it; after, the File went to addFile, the browser's <img> was cancelled, and nothing was attached). A file with no
  // bytes, or with no type and no name that names a kind of file (no extension, or an image's extension), is left to the
  // browser here; a real file of any type, mp4 and PDF included, is taken. The paste event takes every file instead: the
  // editor cancels a paste that holds no text itself, so no <img> would follow, and addAttachment tells an image by its bytes.
  const NAMED_FILE_RE = /\.(?!(?:png|jpe?g|gif|webp|bmp|heic|heif|avif|svg)$)[A-Za-z0-9]{1,10}$/i;
  function leftToBrowser(f) {
    return !f.size || (!f.type && !NAMED_FILE_RE.test(f.name || ""));
  }
  const takenFiles = (cd) => clipboardFiles(cd).filter((f) => !leftToBrowser(f));
  // true when two Files hold the same bytes (read whole; a file that cannot be read counts as different)
  async function sameBytes(a, b) {
    try {
      const [x, y] = await Promise.all([a.arrayBuffer(), b.arrayBuffer()]);
      if (x.byteLength !== y.byteLength) return false;
      const n = x.byteLength >> 2, p = new Uint32Array(x, 0, n), q = new Uint32Array(y, 0, n);
      for (let i = 0; i < n; i++) if (p[i] !== q[i]) return false;
      const u = new Uint8Array(x), v = new Uint8Array(y);
      for (let i = n << 2; i < u.length; i++) if (u[i] !== v[i]) return false;
      return true;
    } catch (e) {
      return false;
    }
  }
  // The files of one event without a picture twice: an image File of the same type and size and the same bytes as an earlier one
  // of the event is left out. Files that are not images are never merged. A single file, or files that differ in type or size,
  // are decided without reading a byte, so a lone paste attaches at once.
  async function distinctPictures(files) {
    const kept = [];
    for (const f of files) {
      let twin = false;
      if (f.type.startsWith("image/")) {
        for (const k of kept) {
          if (k.type === f.type && k.size === f.size && await sameBytes(k, f)) { twin = true; break; }
        }
      }
      if (!twin) kept.push(f);
    }
    return kept;
  }

  const GESTURE_MS = 1000;

  function create(hostEl, cfg = {}) {
    const limits = { perFile: 500 * MB, perImageSource: 20 * MB, reencodeOver: 5 * MB, maxFiles: Infinity, totalBytes: Infinity, ...cfg.limits };
    const endpoint = cfg.endpoint || "api/upload";
    const doFetch = cfg.fetch || ((...a) => window.fetch(...a));
    const isBusy = cfg.isBusy || (() => false);
    const tr = (key, vars) => {
      const v = cfg.t ? cfg.t(key, vars) : undefined;
      return typeof v === "string" && v && v !== key ? v : fill(DEFAULT_WORDS[key] || key, vars);
    };

    let uploads = [];   // {id, name, url, uploading}
    let uploadSeq = 0;

    // ---- the page: the button, its menu, the two inputs, the chips ----
    hostEl.insertAdjacentHTML("afterbegin",
      `<button id="attach" class="attach-btn" type="button">${ATTACH_ICON}</button>` +
      '<div id="attach-menu" class="attach-menu" role="menu">' +
      '<button type="button" role="menuitem" id="attach-photos"></button>' +
      '<button type="button" role="menuitem" id="attach-files"></button></div>' +
      '<input id="file-input" type="file" multiple hidden>' +
      '<input id="photo-input" type="file" accept="image/*,video/*" multiple hidden>');
    const attachBtn = hostEl.querySelector("#attach"), attachMenu = hostEl.querySelector("#attach-menu");
    const fileInput = hostEl.querySelector("#file-input"), photoInput = hostEl.querySelector("#photo-input");
    const chipsEl = cfg.chipsEl || (() => { const n = h("div", { id: "chips" }); hostEl.before(n); return n; })();
    chipsEl.classList.add("attach-chips");
    let statusEl = null;
    let slot = null;
    if (cfg.renderSend) { slot = h("span", { class: "attach-send" }); hostEl.append(slot); cfg.renderSend(slot); }

    function status(msg, kind) {
      if (cfg.onStatus) { cfg.onStatus(msg, kind); return; }
      if (!statusEl) { statusEl = h("div", { class: "attach-status", role: "status" }); chipsEl.after(statusEl); }
      statusEl.textContent = typeof msg === "function" ? msg() : msg;
      statusEl.className = "attach-status" + (kind ? " " + kind : "");
    }
    function paintLabels() {
      attachBtn.setAttribute("aria-label", tr("ui.cmp.attach")); attachBtn.title = tr("ui.cmp.attach");
      attachMenu.setAttribute("aria-label", tr("ui.cmp.menu"));
      attachMenu.querySelector("#attach-photos").textContent = tr("ui.cmp.photos");
      attachMenu.querySelector("#attach-files").textContent = tr("ui.cmp.files");
    }
    paintLabels();

    // the attach button stays usable while an upload is in flight (a second photo can be picked), busy-marked meanwhile
    function refresh() {
      const uploading = uploads.some((u) => u.uploading);
      attachBtn.disabled = isBusy();
      attachBtn.classList.toggle("busy", uploading);
      attachBtn.setAttribute("aria-busy", String(uploading));
    }

    // A file that is not an image: a chip with a generic file icon, its name, and under it its size, the
    // upload's progress while it goes up, or the error that stopped it. Progress repaints the two nodes in place
    // (paintFileChip), so a long upload does not rebuild the chip, and the remove button keeps its focus.
    function paintFileChip(u) {
      if (!u.metaEl || !u.metaEl.isConnected) return;
      const pct = u.size ? Math.min(100, Math.floor(100 * (u.loaded || 0) / u.size)) : 0;
      u.metaEl.textContent = u.error ? tr("app.up.failedMeta", { error: u.error }) : u.uploading ? tr("app.up.progress", { pct, size: humanSize(u.size) }) : humanSize(u.size);
      u.barEl.style.width = (u.uploading ? pct : 0) + "%";
    }
    function fileChip(u) {
      u.metaEl = h("span", { class: "fc-meta" });
      u.barEl = h("span", { class: "fc-bar" });
      const chip = h("div", { class: "chip file" + (u.uploading ? " uploading" : "") + (u.error ? " failed" : ""), role: "group",
                              "aria-label": tr("app.up.file", { name: u.fileName }), title: u.error ? u.fileName + ": " + u.error : u.fileName },
        fileIcon(), h("span", { class: "fc-text" }, h("span", { class: "fc-name", text: u.fileName }), u.metaEl), u.barEl,
        h("button", { type: "button", "aria-label": tr("app.up.remove", { name: u.fileName }), text: "×", onclick: () => removeUpload(u.id) }));
      queueMicrotask(() => paintFileChip(u));  // the nodes are in the page once render has put them there
      return chip;
    }
    function render() {
      paintLabels();
      chipsEl.replaceChildren(...uploads.map((u) => u.kind === "file" ? fileChip(u) :
        h("div", { class: "chip" + (u.uploading ? " uploading" : ""), title: u.error || "" },
          h("img", { src: u.url, alt: tr("app.up.attached") }),
          h("button", { "aria-label": tr("app.up.removeImage"), text: "×", onclick: () => removeUpload(u.id) }))));
      refresh();
      if (cfg.onChange) cfg.onChange(uploads);
    }
    function removeUpload(id) {
      const u = uploads.find((x) => x.id === id);
      if (u && u.xhr) u.xhr.abort();  // a file still going up stops with its chip
      if (u && u.url) URL.revokeObjectURL(u.url);
      uploads = uploads.filter((x) => x.id !== id);
      render();
    }

    async function addImage(file) {
      if (!file || !/^image\/(png|jpeg|gif|webp)$/.test(file.type)) {
        status(() => tr("app.up.notAttached", { what: file ? file.type || tr("app.up.unknownType") : tr("app.up.noFile") }), "error");
        return;
      }
      const u = { id: ++uploadSeq, url: URL.createObjectURL(file), uploading: true, name: null };
      uploads.push(u);
      render();
      try {
        const buf = await readImageBytes(file);
        if (!buf.byteLength) throw new Error(tr("app.up.imgEmpty"));
        // a File whose own size disagrees with the bytes just read (it said 0, or the first read was empty) is rebuilt from
        // those bytes, so the shrink and the upload below start from a whole file
        let send = buf.byteLength === file.size ? file : new File([buf], file.name || "image", { type: file.type });
        const fit = await fitImage(send, limits);
        if (!fit) throw new Error(tr("app.up.imgTooBig", { size: humanSize(send.size), limit: humanSize(limits.perImageSource) }));
        send = fit;
        const r = await doFetch(endpoint, { method: "POST", headers: { "Content-Type": send.type }, body: send });
        const d = await r.json();
        if (!r.ok || !d.ok) throw new Error(d.error || r.statusText);
        u.name = d.name;
      } catch (e) {
        status(() => tr("app.up.imgFailed", { msg: e.message }), "error");
        uploads = uploads.filter((x) => x !== u);
      }
      u.uploading = false;
      render();
    }

    // Any file but a png, jpeg, gif or webp goes up as the raw body of <endpoint>?name=<its name>, in an XMLHttpRequest for
    // its progress (fetch has none for an upload). The server streams it to disk and answers with the reference send takes.
    function addFile(file) {
      const u = { id: ++uploadSeq, kind: "file", fileName: attachmentName(file), size: file.size, loaded: 0, uploading: true, name: null, error: "" };
      uploads.push(u);
      const fail = (msg) => {
        u.uploading = false; u.error = typeof msg === "function" ? msg() : msg; u.xhr = null;
        status(() => tr("app.up.failed", { name: u.fileName, msg: typeof msg === "function" ? msg() : msg }), "error");
        render();
      };
      render();
      if (file.size > limits.perFile) { fail(() => tr("app.up.tooLarge", { size: humanSize(file.size), max: humanSize(limits.perFile) })); return Promise.resolve(); }
      return new Promise((resolve) => {
        const xhr = new XMLHttpRequest();
        u.xhr = xhr;
        xhr.open("POST", endpoint + "?name=" + encodeURIComponent(u.fileName));
        xhr.setRequestHeader("Content-Type", "application/octet-stream");
        xhr.upload.onprogress = (e) => { u.loaded = e.loaded; paintFileChip(u); };
        xhr.onload = () => {
          if (xhr.status === 401 && cfg.onUnauthorized) cfg.onUnauthorized();
          let d = {};
          try { d = JSON.parse(xhr.responseText); } catch (e) { /* not JSON: a proxy's page */ }
          if (xhr.status >= 200 && xhr.status < 300 && d.ok) { u.name = d.name; u.uploading = false; u.xhr = null; u.loaded = u.size; render(); }
          else fail(d.error || xhr.statusText || "HTTP " + xhr.status);
          resolve();
        };
        xhr.onerror = () => { fail(() => tr("app.up.lost")); resolve(); };
        xhr.onabort = () => resolve();
        xhr.send(file);
      });
    }
    // A file of no type that is in fact a png, jpeg, gif or webp (told by its bytes) goes up as an image, thumbnail and all.
    async function addAttachment(file) {
      if (cfg.onChosen) cfg.onChosen(file);
      if (uploads.length >= limits.maxFiles) { status(() => tr("attach.tooMany", { max: limits.maxFiles }), "error"); return; }
      if (uploads.reduce((n, u) => n + (u.size || 0), file.size) > limits.totalBytes) { status(() => tr("attach.totalTooBig", { max: humanSize(limits.totalBytes) }), "error"); return; }
      if (!file.type && file.size) {
        let type = "";
        try { type = await sniffImageType(file); } catch (e) { /* unreadable: it goes up as it is, and the upload says why it failed */ }
        if (type) file = new File([file], file.name || `pasted-${Date.now()}.${IMAGE_EXT[type]}`, { type });
      }
      return /^image\/(png|jpeg|gif|webp)$/.test(file.type) ? addImage(file) : addFile(file);
    }

    // ---- one gesture, one chip ----
    // Everything that can carry an image into the editable feeds addImage, and the text that comes with it stays plain:
    // 1. the paste event (a desktop paste, the Android paste menu, a keyboard's clipboard chip when Chrome delivers it so):
    //    files become chips; text with an HTML flavour goes in as its plain text; a plain-only paste is the browser's own;
    // 2. beforeinput, for an insertion that reaches the editable without a paste event (a keyboard's commitContent may
    //    arrive as insertFromPaste or insertFromDrop with a DataTransfer, an autocorrect as insertReplacementText): files
    //    become chips, HTML becomes its text; formatting commands (Ctrl+B, a format from a menu) are refused;
    // 3. an <img> that the browser put into the editable itself (its own paste of a bitmap, a keyboard's insertion): lifted
    //    out into a chip by the page's liftImage (it asks seenInEarlierLink, then addImage) and removed.
    // One gesture, one chip: these are the links of one chain (Chromium 155: the paste event, then beforeinput
    // insertFromPaste with the same files, then the <img> it inserts), and the link that attaches the files stops the
    // chain (preventDefault: no beforeinput after a prevented paste, no <img> after a prevented beforeinput). Should a
    // browser run a later link all the same, it carries the same bytes under another File object, so a later link skips
    // what an earlier link attached within the last second, by size and type (nothing else survives the new File). Only a
    // later link checks: two pastes of one image in a row are two chips, so are two <img> in one insertion.
    // The clock of that check is when the later link BEGAN, not when it finished reading its files: a clipboard image of
    // 3000 x 4000 px is encoded as a PNG of 19 MB when `files` is first read, a second or more, once for each link, and a
    // window that ran on past those reads let the second link look like a new gesture.
    // One event is one gesture on its own side as well: the files of a single paste, beforeinput or drop are one picture each,
    // so two image Files in one event that hold the same bytes (a clipboard that offers the picture twice, as image.png and as
    // another name) make one chip (distinctPictures).
    let gestures = [];  // what a link attached: [{link, size, type, at}], links 1 (paste, drop), 2 (beforeinput), 3 (<img>)
    function noteGesture(link, files) {
      const at = performance.now();
      gestures = gestures.filter((g) => at - g.at < GESTURE_MS);
      for (const f of files) gestures.push({ link, size: f.size, type: f.type, at });
    }
    function fromEarlierLink(link, f, at = performance.now()) {
      return gestures.some((g) => g.link < link && at - g.at < GESTURE_MS && g.size === f.size && (g.type === f.type || !g.type));
    }
    // An event the handlers took already (one event reaching a handler twice attaches once)
    const takenEvents = new WeakSet();
    // Attach the pictures of one event (the files are already noted as the gesture's)
    async function attachEvent(files) {
      (await distinctPictures(files)).forEach(addAttachment);
    }
    // The two links an editor's handlers call; each returns true when it took the event (the caller then cancels it)
    function handlePaste(e) {
      if (takenEvents.has(e)) return true;
      const files = clipboardFiles(e.clipboardData);   // any file; an image stays a thumbnail (addAttachment)
      if (!files.length) return false;
      takenEvents.add(e);
      noteGesture(1, files); attachEvent(files);
      return true;
    }
    function handleBeforeInput(e) {
      const dt = e.dataTransfer;
      if (!dt) return false;
      if (takenEvents.has(e)) return true;
      const at = performance.now();   // when this link began: reading a big clipboard image below takes a second or more
      const files = takenFiles(dt);
      if (!files.length) return false;
      takenEvents.add(e);
      const fresh = files.filter((f) => !fromEarlierLink(2, f, at));
      noteGesture(2, files);   // all of them, those skipped too: the link after this one counts from the end of this read
      attachEvent(fresh);
      return true;
    }
    // For a plain editable (a textarea): the two links as listeners, a taken event cancelled. Returns the function that removes them.
    function bindPaste(editableEl) {
      const on = (fn) => (e) => { if (fn(e)) e.preventDefault(); };
      const paste = on(handlePaste), before = on(handleBeforeInput);
      editableEl.addEventListener("paste", paste);
      editableEl.addEventListener("beforeinput", before);
      return () => { editableEl.removeEventListener("paste", paste); editableEl.removeEventListener("beforeinput", before); };
    }

    // ---- the attach button ----
    // The attach button, for a phone where paste and drag-drop do not reach the composer: a hidden file input behind it
    // (no accept: any file, multiple; on Android the chooser offers camera, gallery and files), feeding the same
    // addAttachment path as a paste. The value is cleared after each pick, so the same photo can be chosen
    // again (a "change" would not fire for it otherwise).
    // On Android (its user agent) the button opens a two-entry menu instead: "Photos and videos" opens the photo input (accept image
    // and video, which Android Chrome shows as its photo picker), "Files and camera" opens the chooser above (no accept). Every
    // other platform keeps the single tap straight to the chooser. The menu closes on a tap outside, Escape, or focus leaving it.
    const takePicks = (input) => {
      const files = [...(input.files || [])];
      input.value = "";
      files.forEach(addAttachment);
    };
    fileInput.addEventListener("change", () => takePicks(fileInput));
    photoInput.addEventListener("change", () => takePicks(photoInput));
    const onAndroid = /\bAndroid\b/.test(navigator.userAgent || "");
    if (!onAndroid) {
      attachBtn.addEventListener("click", () => { if (!isBusy()) fileInput.click(); });
    } else {
      let attachOpen = false;
      const setAttachMenu = (open) => {
        attachOpen = open;
        attachMenu.classList.toggle("on", open);
        attachBtn.setAttribute("aria-expanded", open ? "true" : "false");
      };
      const inAttach = (node) => !!node && (attachBtn.contains(node) || attachMenu.contains(node));
      attachBtn.setAttribute("aria-haspopup", "menu");
      attachBtn.setAttribute("aria-expanded", "false");
      attachBtn.addEventListener("click", () => { if (!isBusy()) setAttachMenu(!attachOpen); });
      attachMenu.addEventListener("click", (e) => {
        const item = e.target.closest('[role="menuitem"]');
        if (!item) return;
        (item.id === "attach-photos" ? photoInput : fileInput).click();   // inside the tap: the browser allows the chooser
        setAttachMenu(false);
      });
      attachMenu.addEventListener("keydown", (e) => {
        const items = [...attachMenu.querySelectorAll('[role="menuitem"]')];
        const at = items.indexOf(document.activeElement);
        if (e.key === "ArrowDown" || e.key === "ArrowUp") {
          e.preventDefault();
          items[(at + (e.key === "ArrowDown" ? 1 : items.length - 1)) % items.length].focus();
        }
      });
      document.addEventListener("pointerdown", (e) => { if (attachOpen && !inAttach(e.target)) setAttachMenu(false); });
      document.addEventListener("focusout", (e) => { if (attachOpen && !inAttach(e.relatedTarget)) setAttachMenu(false); });
      document.addEventListener("keydown", (e) => {
        if (attachOpen && e.key === "Escape") { setAttachMenu(false); attachBtn.focus(); }
      });
    }

    // ---- drag and drop ----
    const dz = cfg.dropTarget;
    if (dz) {
      let dragDepth = 0;
      dz.addEventListener("dragenter", (e) => { if (e.dataTransfer?.types?.includes("Files")) { dragDepth++; document.body.classList.add("dragging"); } });
      dz.addEventListener("dragleave", () => { if (--dragDepth <= 0) { dragDepth = 0; document.body.classList.remove("dragging"); } });
      dz.addEventListener("dragover", (e) => { if (e.dataTransfer?.types?.includes("Files")) e.preventDefault(); });
      dz.addEventListener("drop", (e) => {
        dragDepth = 0; document.body.classList.remove("dragging");
        const files = [...(e.dataTransfer?.files || [])];
        if (files.length) { e.preventDefault(); noteGesture(1, files); files.forEach(addAttachment); }
      });
    }

    return {
      limits,
      getUploads: () => uploads,
      clear() { uploads = []; render(); },
      add(files) { return Promise.all([...files].map(addAttachment)); },
      isUploading: () => uploads.some((u) => u.uploading),
      // already uploaded entries (a message taken back into the composer, a draft kept over a sign-in): {name, url} for an image,
      // {kind: "file", name, fileName, size} for a file
      restore(entries) {
        for (const e of entries) uploads.push({ id: ++uploadSeq, uploading: false, ...e });
        if (entries.length) render();
      },
      render, refresh, bindPaste, handlePaste, handleBeforeInput, addImage,
      seenInEarlierLink: (link, f, at) => fromEarlierLink(link, f, at),
    };
  }

  window.SalaAttach = { create, humanSize, fileIcon, clipboardFiles, clipboardImages, sniffImageType, IMAGE_EXT };
})();
