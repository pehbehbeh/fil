// The client of Fil.Kino.DiskCell: a form whose fields go to the server one by one, on change. The server builds the
// code from them. Plain DOM, no build step.

const ROOT_LABELS = { local: "Root directory", s3: "Key prefix", memory: "Root" };

export function init(ctx, { fields }) {
  ctx.importCSS("main.css");

  const form = element("form", "fil-cell");
  form.addEventListener("submit", (event) => event.preventDefault());

  const inputs = {};

  const header = element("div", "fil-cell-row fil-cell-header");
  inputs.adapter = select(["local", "Local"], ["s3", "S3"], ["memory", "Memory"]);
  inputs.variable = textInput("disk");
  header.append(field("Adapter", inputs.adapter), field("Assign to", inputs.variable));

  const common = element("div", "fil-cell-row");
  inputs.root = textInput("");
  const rootField = field(ROOT_LABELS.local, inputs.root, "fil-cell-grow");
  common.append(rootField);

  const s3 = element("div", "fil-cell-s3");
  const bucketRow = element("div", "fil-cell-row");
  inputs.bucket = textInput("my-bucket");
  inputs.region = textInput("us-east-1");
  inputs.endpoint = textInput("empty for AWS");
  bucketRow.append(
    field("Bucket", inputs.bucket, "fil-cell-grow"),
    field("Region", inputs.region),
    field("Endpoint (S3-compatible)", inputs.endpoint, "fil-cell-grow")
  );

  const optionsRow = element("div", "fil-cell-row");
  inputs.path_style = element("input");
  inputs.path_style.type = "checkbox";
  const pathStyle = element("label", "fil-cell-check");
  pathStyle.append(inputs.path_style, document.createTextNode(" Path-style URLs"));
  optionsRow.append(pathStyle);

  const secretsRow = element("div", "fil-cell-row");
  const accessKey = secret("access_key_id_secret", "Access key ID", "AWS_ACCESS_KEY_ID");
  const secretKey = secret("secret_access_key_secret", "Secret access key", "AWS_SECRET_ACCESS_KEY");
  secretsRow.append(accessKey.field, secretKey.field);

  const note = element(
    "p",
    "fil-cell-note",
    "Credentials come from Livebook secrets. Without them, the disk accesses a public bucket without signing."
  );

  s3.append(bucketRow, optionsRow, secretsRow, note);
  form.append(header, common, s3);
  ctx.root.append(form);

  for (const name of ["variable", "root", "bucket", "region", "endpoint"]) {
    inputs[name].addEventListener("change", () => push(name, inputs[name].value));
  }

  inputs.adapter.addEventListener("change", () => {
    push("adapter", inputs.adapter.value);
    showAdapter(inputs.adapter.value);
  });

  inputs.path_style.addEventListener("change", () => push("path_style", inputs.path_style.checked));

  function push(name, value) {
    ctx.pushEvent("update_field", { field: name, value });
  }

  // A secret field shows the name of the Livebook secret. Clicking it opens Livebook's secret picker, and the button
  // next to it removes the secret again.
  function secret(name, label, preselect) {
    const input = textInput("Select a secret");
    input.readOnly = true;
    input.classList.add("fil-cell-secret");
    input.addEventListener("click", () => {
      ctx.selectSecret((secretName) => push(name, secretName), input.value || preselect, { title: label });
    });

    const clear = element("button", "fil-cell-clear", "×");
    clear.type = "button";
    clear.title = "Remove the secret";
    clear.addEventListener("click", () => push(name, ""));

    const wrapper = element("div", "fil-cell-secret-wrapper");
    wrapper.append(input, clear);
    inputs[name] = input;

    return { field: field(label, wrapper, "fil-cell-grow") };
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
    }
  }

  function showAdapter(adapter) {
    s3.hidden = adapter !== "s3";
    rootField.querySelector(".fil-cell-label").textContent = ROOT_LABELS[adapter];
    inputs.root.placeholder = adapter === "local" ? "the current directory" : "";
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

function element(tag, className, text) {
  const el = document.createElement(tag);
  if (className) el.className = className;
  if (text !== undefined) el.textContent = text;
  return el;
}

function textInput(placeholder) {
  const input = element("input", "fil-cell-input");
  input.type = "text";
  input.placeholder = placeholder;
  input.spellcheck = false;
  input.autocomplete = "off";
  return input;
}

function select(...options) {
  const el = element("select", "fil-cell-input");

  for (const [value, label] of options) {
    const option = element("option", null, label);
    option.value = value;
    el.append(option);
  }

  return el;
}

function field(label, input, className) {
  const wrapper = element("label", className ? `fil-cell-field ${className}` : "fil-cell-field");
  wrapper.append(element("span", "fil-cell-label", label), input);
  return wrapper;
}
