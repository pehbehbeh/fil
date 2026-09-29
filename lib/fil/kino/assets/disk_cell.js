// The client of Fil.Kino.DiskCell: a form whose fields go to the server one by one, on change. The server builds the
// code from them. Plain DOM, no build step. It looks like kino_db's connection cell: the adapter in a header, the
// options below it, switches for booleans, and secrets picked from Livebook's secret list.

const ROOT_FIELDS = {
  local: { label: "Root directory", placeholder: "By default, the current directory" },
  s3: { label: "Key prefix", placeholder: "By default, the bucket root" },
  memory: { label: "Root", placeholder: "" },
};

// Remix Icon's lock-password-line, the icon of kino_db's secret fields.
const LOCK_ICON =
  "M18 8h2a1 1 0 0 1 1 1v12a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V9a1 1 0 0 1 1-1h2V7a6 6 0 1 1 12 0v1zM5 10v10h14V10H5zm6 " +
  "4h2v2h-2v-2zm-4 0h2v2H7v-2zm8 0h2v2h-2v-2zm1-6V7a4 4 0 1 0-8 0v1h8z";

export function init(ctx, { fields }) {
  ctx.importCSS("theme.css");
  ctx.importCSS("disk_cell.css");

  const form = element("form", "fil-cell");
  form.addEventListener("submit", (event) => event.preventDefault());

  const inputs = {};
  const secrets = {};

  const header = element("div", "fil-cell-header");
  inputs.adapter = select(["local", "Local"], ["s3", "S3"], ["memory", "Memory"]);
  inputs.variable = textInput();
  header.append(inlineField("Adapter", inputs.adapter), inlineField("Assign to", inputs.variable));

  // The S3 options around the root field, which every adapter has: the bucket above it, the credentials below.
  const bucketRow = element("div", "fil-cell-row");
  inputs.bucket = textInput();
  inputs.region = textInput("us-east-1");
  inputs.endpoint = textInput("By default, AWS");
  bucketRow.append(field("Bucket", inputs.bucket), field("Region", inputs.region), field("Endpoint", inputs.endpoint));

  const rootRow = element("div", "fil-cell-row");
  inputs.root = textInput();
  const rootField = field(ROOT_FIELDS.local.label, inputs.root);
  inputs.path_style = element("input", "fil-cell-switch-input");
  inputs.path_style.type = "checkbox";
  // The server switches it with the endpoint while it's at Fil.Adapter.S3's default: on with an endpoint, off without.
  const pathStyle = switchField("Path-style URLs", inputs.path_style);
  rootRow.append(rootField, pathStyle);

  const secretsRow = element("div", "fil-cell-row");
  secretsRow.append(
    secretField("access_key_id_secret", "Access key ID", "AWS_ACCESS_KEY_ID"),
    secretField("secret_access_key_secret", "Secret access key", "AWS_SECRET_ACCESS_KEY"),
    secretField("session_token_secret", "Session token", "AWS_SESSION_TOKEN")
  );

  const help = element("p", "fil-cell-help");
  help.textContent =
    "Without credentials, the disk accesses a public bucket without signing requests. " +
    "The session token is only for temporary credentials, such as from AWS STS or SSO.";

  const s3Only = [bucketRow, pathStyle, secretsRow, help];
  form.append(header, bucketRow, rootRow, secretsRow, help);
  ctx.root.append(form);

  for (const name of ["variable", "root", "bucket", "region", "endpoint"]) {
    inputs[name].addEventListener("change", () => push(name, inputs[name].value));
  }

  inputs.bucket.addEventListener("input", () => markEmpty(inputs.bucket));

  inputs.adapter.addEventListener("change", () => {
    push("adapter", inputs.adapter.value);
    showAdapter(inputs.adapter.value);
  });

  inputs.path_style.addEventListener("change", () => push("path_style", inputs.path_style.checked));

  function push(name, value) {
    ctx.pushEvent("update_field", { field: name, value });
  }

  // A secret field shows the name of a Livebook secret, and clicking it opens Livebook's secret picker. The lock
  // button in front of it picks a secret too, or removes the one that's set.
  function secretField(name, label, preselect) {
    const input = textInput("Select a secret");
    input.readOnly = true;
    input.classList.add("fil-cell-secret-input");

    const icon = element("button", "fil-cell-secret-icon");
    icon.type = "button";
    icon.append(lockIcon());

    const pick = () => {
      ctx.selectSecret((secretName) => push(name, secretName), input.value || preselect, { title: label });
    };

    input.addEventListener("click", pick);
    input.addEventListener("keydown", (event) => {
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        pick();
      }
    });
    icon.addEventListener("click", () => (input.value ? push(name, "") : pick()));

    const group = element("div", "fil-cell-secret");
    group.append(icon, input);
    inputs[name] = input;
    secrets[name] = icon;

    return field(label, group, input);
  }

  function setSecret(name, value) {
    const icon = secrets[name];
    icon.classList.toggle("fil-cell-secret-icon--set", value !== "");
    icon.title = value === "" ? "Select a secret" : "Remove the secret";
    icon.setAttribute("aria-label", icon.title);
  }

  function setFields(values) {
    for (const [name, value] of Object.entries(values)) {
      const input = inputs[name];
      if (!input) continue;

      if (input.type === "checkbox") {
        input.checked = value;
      } else {
        input.value = value;
      }

      if (name === "adapter") showAdapter(value);
      if (name === "bucket") markEmpty(input);
      if (secrets[name]) setSecret(name, value);
    }
  }

  function showAdapter(adapter) {
    for (const el of s3Only) el.hidden = adapter !== "s3";
    rootField.querySelector(".fil-cell-label").textContent = ROOT_FIELDS[adapter].label;
    inputs.root.placeholder = ROOT_FIELDS[adapter].placeholder;
  }

  ctx.handleEvent("update", ({ fields }) => setFields(fields));

  // Livebook calls this before it evaluates the cell, so a field that still has focus is sent first.
  ctx.handleSync(() => {
    if (document.activeElement && document.activeElement.dispatchEvent) {
      document.activeElement.dispatchEvent(new Event("change"));
    }
  });

  setFields(fields);
}

let nextId = 0;

function element(tag, className, text) {
  const el = document.createElement(tag);
  if (className) el.className = className;
  if (text !== undefined) el.textContent = text;
  return el;
}

function textInput(placeholder = "") {
  const input = element("input", "fil-cell-input");
  input.type = "text";
  input.placeholder = placeholder;
  input.spellcheck = false;
  input.autocomplete = "off";
  return input;
}

function select(...options) {
  const el = element("select", "fil-cell-input fil-cell-select");

  for (const [value, label] of options) {
    const option = element("option", null, label);
    option.value = value;
    el.append(option);
  }

  return el;
}

// A label above its input. `target` is the element the label names, when `content` wraps it.
function field(label, content, target = content) {
  target.id = `fil-cell-${nextId++}`;
  const labelEl = element("label", "fil-cell-label", label);
  labelEl.htmlFor = target.id;

  const wrapper = element("div", "fil-cell-field");
  wrapper.append(labelEl, content);
  return wrapper;
}

// An uppercase label left of its input, for the header.
function inlineField(label, input) {
  const wrapper = field(label, input);
  wrapper.className = "fil-cell-inline-field";
  wrapper.firstChild.className = "fil-cell-inline-label";
  return wrapper;
}

function switchField(label, checkbox) {
  const track = element("label", "fil-cell-switch");
  track.append(checkbox, element("span", "fil-cell-switch-track"));

  const wrapper = field(label, track, checkbox);
  wrapper.classList.add("fil-cell-field--fixed");
  return wrapper;
}

function markEmpty(input) {
  input.classList.toggle("fil-cell-input--empty", input.value === "");
}

function lockIcon() {
  const ns = "http://www.w3.org/2000/svg";
  const svg = document.createElementNS(ns, "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("width", "22");
  svg.setAttribute("height", "22");
  svg.setAttribute("aria-hidden", "true");

  const path = document.createElementNS(ns, "path");
  path.setAttribute("d", LOCK_ICON);
  path.setAttribute("fill", "currentColor");
  svg.append(path);
  return svg;
}
