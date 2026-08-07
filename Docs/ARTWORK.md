# Artwork providers

Sol fetches artwork at runtime for the user's local library. Artwork is not
checked into the source tree and is not included in releases.

## Matching

The primary provider is the public platform catalog search used by the app's
supported game metadata. Sol requests up to eight candidates and chooses them
in this order:

1. Exact 16-character title ID
2. Exact normalized title
3. A high-confidence title-token match

If a response has identity fields and none of those checks pass, Sol rejects it
instead of showing a plausible but incorrect game. Nlib is the fallback for
title-ID covers and banners that the primary catalog does not return.

Hero images must be at least 1000 × 500 and have a wide aspect ratio between
1.6:1 and 2.4:1. Sol tries the original or 1600-pixel source before a preview,
then validates the decoded dimensions. If no valid wide image exists, a cached
cover is used behind the native material treatment rather than leaving a blank
background.

## Cache and privacy

Downloads use ephemeral sessions, HTTPS URLs, timeouts, and a 25 MiB image
limit. Valid images are cached locally by title ID or normalized title. A cache
schema version allows Sol to refresh older low-resolution artwork once without
redownloading it on every launch.

Searches send only the title or title ID needed to find artwork. Local paths,
playtime, profile information, keys, firmware, and save data are never sent to
an artwork provider.

## Other providers

SteamGridDB offers strong community artwork but requires each client to use an
API key. Sol does not bundle a maintainer key, scrape the site, or ask users to
paste a token into an ordinary preferences file. It can be added later as an
optional Keychain-backed provider if there is enough demand.

Artwork belongs to its respective copyright holders. It is displayed as
metadata for content already present in the user's library.
