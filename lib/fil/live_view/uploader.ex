if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Fil.LiveView.Uploader do
    @moduledoc false

    # The browser side of `Fil.LiveView.external/2`, as colocated JS. The component is never rendered: LiveView's
    # compiler extracts the script when Fil compiles and exports it under `uploaders` in the manifest
    # `phoenix-colocated/fil/index.js`, so an app passes `import {uploaders} from "phoenix-colocated/fil"` to its
    # `LiveSocket`. LiveView picks the uploader by the `uploader: "Fil"` of an entry's meta.

    use Phoenix.Component

    def uploader(assigns) do
      ~H"""
      <script :type={Phoenix.LiveView.ColocatedJS} name="Fil" key="uploaders">
        // Sends each file as `Fil.LiveView.external/2` signed it, with the method, headers and form fields
        // `Fil.signed_upload/3` gave: the file as the body of a PUT, or after the fields of a form for a POST. XHR
        // instead of fetch, because only XHR reports upload progress. LiveView turns `entry.error()` into
        // `:external_client_failure`.
        export default function Fil(entries, onViewError) {
          for (const entry of entries) {
            const xhr = new XMLHttpRequest()

            onViewError(() => xhr.abort())
            entry.onCancel(() => xhr.abort())

            xhr.upload.addEventListener("progress", (event) => {
              if (event.lengthComputable) {
                // 100 comes from the response, once the storage has the file.
                entry.progress(Math.min(Math.round((event.loaded / event.total) * 100), 99))
              }
            })

            xhr.onload = () => {
              if (xhr.status >= 200 && xhr.status < 300) {
                entry.progress(100)
              } else {
                entry.error()
              }
            }
            xhr.onerror = () => entry.error()

            const {method, url, headers, fields} = entry.meta
            xhr.open(method.toUpperCase(), url, true)

            for (const [name, value] of Object.entries(headers)) {
              xhr.setRequestHeader(name, value)
            }

            if (method === "post") {
              const form = new FormData()
              for (const [name, value] of fields) form.append(name, value)
              form.append("file", entry.file)
              xhr.send(form)
            } else {
              xhr.send(entry.file)
            }
          }
        }
      </script>
      """
    end
  end
end
