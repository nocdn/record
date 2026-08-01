# record

A small library to record internal and external audio on mac easily through CLI

## Install and run

Run without installing:

```bash
npx @nocdn/record
```

Or with bun, pnpm, or yarn:

```bash
bunx @nocdn/record
pnpm dlx @nocdn/record
yarn dlx @nocdn/record
```

## Usage

```bash
record [options]
```

| flag | description |
| --- | --- |
| `-h`, `--help` | show help |
| `-v`, `--version` | show version |

## Develop

```bash
npm install
npm start
```

The CLI entry point lives in [`bin/cli.js`](./bin/cli.js). The package is built
with plain Node.js and npm for maximum runtime compatibility, but the published
binary can be invoked with any package runner (`npx`, `bunx`, `pnpm dlx`, ...).

## Publishing

This project includes a GitHub Actions workflow at
[`.github/workflows/publish.yml`](./.github/workflows/publish.yml) that publishes
the package to npm with [trusted publishing](https://docs.npmjs.com/trusted-publishers)
from the `main` branch, as long as the version in `package.json` is not already
on npm. `package.json` sets `publishConfig.access` to `public`, so scoped
packages are published publicly by default.

To enable it once:

1. Push the repository to GitHub.
2. Add a `repository.url` field to `package.json` that exactly matches the
   GitHub repository URL.
3. On npmjs.com, configure the package as a GitHub Actions trusted publisher:
   use this repository owner/name, workflow filename `publish.yml`, and allow
   `npm publish`.
4. Bump the version in `package.json` and push to `main` - the workflow will
   publish without an npm token.
