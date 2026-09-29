// The client of Fil.Kino.Browser. Plain DOM, no build step. Names and paths come from the storage, so they're only
// ever set as text, never as HTML.

export function init(ctx, data) {
  ctx.importCSS("main.css");

  const root = element("div", "fil-browser");
  const bar = element("div", "fil-bar");
  const crumbs = element("nav", "fil-crumbs");
  const refresh = button("Refresh", "fil-button");
  const error = element("div", "fil-error");
  const table = element("table", "fil-table");
  const body = element("tbody");
  const more = element("div", "fil-more");
  const preview = element("div", "fil-preview");

  const head = element("thead");
  const headRow = element("tr");
  for (const label of ["Name", "Size", "Modified", "Type", ""]) {
    headRow.append(element("th", null, label));
  }
  head.append(headRow);
  table.append(head, body);
  bar.append(crumbs, refresh);
  root.append(bar, error, table, more, preview);
  ctx.root.append(root);

  let imageUrl = null;
  let currentPath = null;

  refresh.addEventListener("click", () => ctx.pushEvent("refresh", {}));

  function render(listing) {
    // A preview belongs to its directory, so it goes when another one opens.
    if (listing.path !== currentPath) clearPreview();
    currentPath = listing.path;

    showError(listing.error);
    renderCrumbs(listing.label, listing.path);
    renderRows(listing.entries);

    more.textContent = listing.more > 0 ? `and ${listing.more} more` : "";
    more.hidden = listing.more === 0;
  }

  function renderCrumbs(label, path) {
    crumbs.replaceChildren(link(label, () => open(".")));

    if (path === ".") return;

    const parts = path.split("/");
    parts.forEach((part, index) => {
      crumbs.append(element("span", "fil-separator", "/"));
      const dir = parts.slice(0, index + 1).join("/");
      crumbs.append(index === parts.length - 1 ? element("span", null, part) : link(part, () => open(dir)));
    });
  }

  function renderRows(entries) {
    if (entries.length === 0) {
      const row = element("tr");
      const cell = element("td", "fil-empty", "This directory is empty.");
      cell.colSpan = 5;
      row.append(cell);
      body.replaceChildren(row);
      return;
    }

    body.replaceChildren(...entries.map(row));
  }

  function row(entry) {
    const tr = element("tr");
    const dir = entry.type === "directory";
    const name = dir ? `${entry.name}/` : entry.name;
    const onClick = dir ? () => open(entry.path) : () => showPreview(entry);

    tr.append(
      cell(link(name, onClick)),
      cell(entry.size === null || dir ? "" : formatSize(entry.size), "fil-number"),
      cell(entry.mtime ? new Date(entry.mtime).toLocaleString() : ""),
      cell(dir ? "directory" : entry.content_type || ""),
      cell(dir ? "" : downloadCell(entry))
    );

    return tr;
  }

  function downloadCell(entry) {
    if (entry.size === null) return element("span", "fil-note", "size unknown");
    if (!entry.downloadable) return element("span", "fil-note", "too large to download here");

    const download = button("Download", "fil-button");
    download.addEventListener("click", () => ctx.pushEvent("download", { path: entry.path }));
    return download;
  }

  function open(path) {
    ctx.pushEvent("open", { path });
  }

  function showPreview(entry) {
    // The server only reads files whose listed size is known and small enough.
    if (entry.previewable) {
      ctx.pushEvent("preview", { path: entry.path });
    } else if (entry.size === null) {
      setPreview(entry.path, element("p", "fil-note", "No preview, the size of this file is unknown."));
    } else {
      setPreview(entry.path, element("p", "fil-note", "Too large to preview."));
    }
  }

  function setPreview(path, content) {
    clearPreview();
    preview.replaceChildren(element("div", "fil-preview-title", path), content);
    preview.hidden = false;
  }

  function clearPreview() {
    if (imageUrl) {
      URL.revokeObjectURL(imageUrl);
      imageUrl = null;
    }

    preview.replaceChildren();
    preview.hidden = true;
  }

  function showError(message) {
    error.textContent = message || "";
    error.hidden = !message;
  }

  ctx.handleEvent("listing", (listing) => render(listing));

  ctx.handleEvent("error", ({ message }) => showError(message));

  ctx.handleEvent("preview", ({ path, kind, text }) => {
    showError(null);

    if (kind === "text") {
      setPreview(path, element("pre", "fil-text", text));
    } else {
      setPreview(path, element("p", "fil-note", "No preview for this type of file."));
    }
  });

  ctx.handleEvent("preview_image", ([{ path, type }, buffer]) => {
    showError(null);

    const image = element("img", "fil-image");
    setPreview(path, image);
    imageUrl = URL.createObjectURL(new Blob([buffer], { type }));
    image.src = imageUrl;
    image.alt = path;
  });

  ctx.handleEvent("download", ([{ name }, buffer]) => {
    showError(null);

    const url = URL.createObjectURL(new Blob([buffer], { type: "application/octet-stream" }));
    const a = document.createElement("a");
    a.href = url;
    a.download = name;
    a.click();
    setTimeout(() => URL.revokeObjectURL(url), 0);
  });

  render(data);
}

function element(tag, className, text) {
  const el = document.createElement(tag);
  if (className) el.className = className;
  if (text !== undefined) el.textContent = text;
  return el;
}

function cell(content, className) {
  const td = element("td", className);
  td.append(content);
  return td;
}

function button(label, className) {
  const el = element("button", className, label);
  el.type = "button";
  return el;
}

function link(label, onClick) {
  const el = button(label, "fil-link");
  el.addEventListener("click", onClick);
  return el;
}

function formatSize(bytes) {
  const units = ["B", "KB", "MB", "GB", "TB"];
  let size = bytes;
  let unit = 0;

  while (size >= 1000 && unit < units.length - 1) {
    size /= 1000;
    unit += 1;
  }

  return unit === 0 ? `${size} B` : `${size.toFixed(1)} ${units[unit]}`;
}
