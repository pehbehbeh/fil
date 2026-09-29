// The client of Fil.Kino.Browser. Plain DOM, no build step. Names and paths come from the storage, so they're only
// ever set as text, never as HTML.

export function init(ctx, data) {
  ctx.importCSS("theme.css");
  ctx.importCSS("browser.css");

  const root = element("div", "fil-browser");
  const bar = element("div", "fil-bar");
  const crumbs = element("nav", "fil-crumbs");
  const refresh = button("Refresh", "fil-button");
  const error = element("div", "fil-error");
  const table = element("table", "fil-table");
  const body = element("tbody");
  const more = element("div", "fil-more");
  const card = element("div", "fil-card");
  const preview = element("div", "fil-card fil-preview");
  preview.hidden = true;

  const head = element("thead");
  const headRow = element("tr");
  for (const label of ["Name", "Size", "Modified", "Type", ""]) {
    headRow.append(element("th", null, label));
  }
  head.append(headRow);
  table.append(head, body);
  bar.append(crumbs, refresh);
  card.append(table, more);
  root.append(bar, error, card, preview);
  ctx.root.append(root);

  let imageUrl = null;
  let currentPath = null;
  let previewPath = null;
  let writable = false;

  refresh.addEventListener("click", () => ctx.pushEvent("refresh", {}));

  function render(listing) {
    // A preview goes when its file isn't listed anymore: another directory opened, or the file was deleted.
    if (previewPath !== null && !listing.entries.some((entry) => entry.path === previewPath)) clearPreview();
    currentPath = listing.path;
    writable = listing.writable;

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
      cell(dir ? "" : actions(entry), "fil-actions")
    );

    return tr;
  }

  function actions(entry) {
    const span = element("span");

    if (entry.downloadable) {
      const download = button("Download", "fil-button");
      download.addEventListener("click", () => ctx.pushEvent("download", { path: entry.path }));
      span.append(download);
    } else {
      span.append(element("span", "fil-note", entry.size === null ? "size unknown" : "too large to download here"));
    }

    if (writable) {
      const remove = button("Delete", "fil-button fil-button--danger");
      remove.addEventListener("click", () => {
        if (window.confirm(`Delete ${entry.path}?`)) ctx.pushEvent("delete", { path: entry.path });
      });
      span.append(remove);
    }

    return span;
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
    previewPath = path;
  }

  function clearPreview() {
    if (imageUrl) {
      URL.revokeObjectURL(imageUrl);
      imageUrl = null;
    }

    preview.replaceChildren();
    preview.hidden = true;
    previewPath = null;
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
