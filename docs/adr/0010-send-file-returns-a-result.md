# `Fil.Plug.send_file/3` returns a result

`Fil.Plug.send_file/2,3,4` returns `{:ok, conn}`, or `{:error, exception}` before anything is sent, following `Fil`'s
rule for functions that can fail.

## Considered options

- Returning `conn | {:error, _}`, which fits an `action_fallback` directly but breaks the rule.
- A `redirect:` option to a signed URL. `redirect(conn, external: Fil.signed_url!(...))` is already one line. A redirect
  can't set `content_type:`, and the URL outlives the controller's auth check.
