# AGENTS.md

Project instructions for opencode and other agents working in this repo.

## Personal data must never enter the repo

Hard rule. Do **not** put any real person's information into source, tests,
fixtures, comments, docs, commit messages, tool scripts, asset names, or logs:

- Names of real people the maintainer knows (friends, family, colleagues), in
  any identifying combination — first + last, name + initial, or a first name
  paired with a relationship.
- Contact details: emails, phone numbers, addresses, birthdays, handles.
- Credentials and secrets: passwords, access/refresh tokens, `saltedKeyPass`,
  API keys, session JSON.
- Personal media or data derived from a real library (photos, EXIF, raw
  embeddings, real capture times).
- Absolute local paths that leak a username (`/Users/<name>/...`).

Use the shared fictional personas below for every person in tests and fixtures.
If none fits, add a new **fictional** persona to the shared set — never invent a
plausible real name.

Exception: the maintainer's own developer identifier is allowed. Package /
application IDs, MethodChannel names, module URLs, and copyright lines under
`com.dustinleblanc` / `dustinleblanc` may stay.

If you suspect personal data is already committed, say so explicitly before
continuing; do not silently leave it in place.

## Test fixtures: use the shared personas

Canonical fixtures live in `app/test/support/personas.dart`.

- Write `Personas.alex.name`, `Personas.kim.contactDisplayName`, etc. — never a
  literal person name.
- A persona exposes `name`, `fullName`, `aliases`, and `contactDisplayName`.
- Generic role words (`Mom`, `Dad`) are fine and need no persona.
- New personas must be clearly fictional first/last names, not associated with
  the maintainer or anyone they know.

## Verifying changes

- App (Dart/Flutter): `cd app && flutter analyze && flutter test`
- CLI/Go: `go build -o photon . && go vet ./... && go test -race ./...`
- Android device: `make apk-wifi` (builds, installs, relaunches over Wi-Fi)
