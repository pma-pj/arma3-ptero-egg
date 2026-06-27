# Arma 3 Steam Workshop Collection Image

A minimal wrapper around `ghcr.io/ptero-eggs/games:arma3`.

`STEAM_WORKSHOP_COLLECTION_URL` accepts a public Steam Workshop collection URL
or numeric collection ID. At every server boot, the wrapper resolves it via
Steam's `ISteamRemoteStorage/GetCollectionDetails` endpoint, appends all
contained Workshop IDs to `MODIFICATIONS`, then executes the original Arma 3
entrypoint.

The original image continues to:

- download/update the Arma 3 dedicated server;
- download/update Steam Workshop mods;
- copy `.bikey` files into `keys/`;
- create and launch the final Arma 3 start command.

## Pterodactyl startup variable

Create this startup variable yourself:

| Field | Value |
|---|---|
| Name | Steam Workshop Collection URL |
| Environment variable | `STEAM_WORKSHOP_COLLECTION_URL` |
| Default value | empty |
| Rules | `nullable|string|max:2048` |
| User viewable | yes |
| User editable | yes |

For a collection-only server set `MOD_FILE` to an empty value, otherwise the
upstream egg will still try to parse its default `modlist.html`.

Also set:

- `UPDATE_SERVER=1`
- `DISABLE_MOD_UPDATES=0`
- A `STEAM_USER` account that owns Arma 3

The package's image path after publishing is:

```text
ghcr.io/<github-owner>/<repository>:latest
```

For production, pin a release tag such as `:v1.0.0` rather than `:latest`.

## Publish

Push `main` to publish `:main`, `:latest`, and a SHA tag. Create and push a
Git tag like `v1.0.0` to publish `:1.0.0` and `:1.0`.

The GitHub Container package initially follows GitHub's package visibility
settings. Make it public once in the package settings if Wings should be able
to pull it anonymously.
