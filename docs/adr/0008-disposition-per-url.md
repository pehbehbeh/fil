# The content disposition is chosen per URL

`disposition:` is an option of `Fil.signed_url/3`, and a disk can set a default with `signed_url:`. The URL's signature
covers it, so nobody can make a link that serves a file under another name.

## Considered options

- Storing the disposition with the file when it's written. The caller decides per URL instead.
