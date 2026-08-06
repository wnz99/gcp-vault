# gcp-vault

`gcp-vault` isolates Google Cloud CLI and Application Default Credentials (ADC) by account or
organization. Each alias selects a dedicated Cloud SDK directory, expected user identity, ADC
file, and project allowlist before running a command.

Use it when one workstation accesses multiple Google Cloud organizations and accidentally mixing
accounts or projects would be unsafe. If you use only one Google identity, the vanilla `gcloud`
workflow may be sufficient.

## Requirements

- Bash
- [Google Cloud CLI](https://cloud.google.com/sdk/docs/install)
- `curl`
- `jq`

## Install

Clone the public repository and install the executable symlink:

```bash
git clone https://github.com/wnz99/gcp-vault.git "$HOME/.local/share/gcp-vault"
"$HOME/.local/share/gcp-vault/gcp-vault" install
```

Ensure `$HOME/.local/bin` is on `PATH`. The installer refuses to overwrite an unrelated file or
symlink.

If migrating from a previously vendored copy whose installed symlink points somewhere else, use
the explicit symlink-only replacement mode:

```bash
"$HOME/.local/share/gcp-vault/gcp-vault" install --replace
```

`--replace` still refuses to overwrite a regular file.

To update:

```bash
git -C "$HOME/.local/share/gcp-vault" pull --ff-only
```

The installed command is a symlink to the clone, so no reinstall is needed after an update.

## Configure an isolated account

Create one Cloud SDK directory and one account definition per identity or organization:

```bash
mkdir -p "$HOME/.config/gcp-vault/accounts" "$HOME/.config/gcloud-example"

cat > "$HOME/.config/gcp-vault/accounts/example" <<EOF
cloudsdk_config=$HOME/.config/gcloud-example
description=Example organization development and production
expected_account=you@example.com
allowed_projects=example-dev,example-stg,example-prd
EOF
```

Configuration files accept exactly these keys:

- `cloudsdk_config`: absolute, canonical Cloud SDK directory under `~/.config/gcloud*`.
- `description`: optional, non-empty printable ASCII operator-authored label. Never put secrets,
  credentials, or token material in a description.
- `expected_account`: Google account that both gcloud and ADC must use.
- `allowed_projects`: comma-separated Google Cloud project IDs exposed to child commands.

List configured aliases:

```bash
gcp-vault list
gcp-vault list --json
gcp-vault describe example
```

Plain `list` remains alias-only. JSON discovery and `describe` expose only the alias, description,
expected account, and allowed projects. Select an alias automatically only when exactly one entry
clearly matches the task; ask when metadata is missing, conflicting, or ambiguous.

## Authenticate

Let the wrapper manage both required Google authentication flows:

```bash
gcp-vault login example
```

This runs the Cloud SDK account login and ADC login inside the alias's isolated profile, then
validates that both tokens resolve to `expected_account`. If Google Cloud CLI displays
`Please enter your password:`, it is asking for the Google Workspace password for the configured
account. It is not asking for the macOS login, Keychain, `aws-vault`, or `gcp-vault` password;
browser reauthentication is also valid when Google offers it.

## Run commands

```bash
gcp-vault example -- gcloud projects describe example-dev
gcp-vault example -- tofu plan
gcp-vault example -- python app.py
```

The wrapper exports these validated values only to the child process:

- `CLOUDSDK_CONFIG`
- `CLOUDSDK_CORE_ACCOUNT`
- `GOOGLE_APPLICATION_CREDENTIALS`
- `GCP_VAULT_ACCOUNT`
- `GCP_VAULT_EXPECTED_ACCOUNT`
- `GCP_VAULT_ALLOWED_PROJECTS`

It rejects pre-existing credential, account, impersonation, and access-token overrides to prevent
ambient state from bypassing profile isolation.
`GCP_VAULT_ACCOUNT` is the current alias only for the invoked child command; there is no durable
global current alias.

## Vanilla gcloud alternative

For a single-account workstation, Google Cloud's standard local workflow is:

```bash
gcloud auth login you@example.com
gcloud config set project example-dev
gcloud auth application-default login
```

Then run commands directly:

```bash
gcloud projects describe example-dev
python app.py
```

The gcloud CLI credential and ADC credential are separate. `gcloud auth login` authenticates CLI
commands; `gcloud auth application-default login` authenticates local application libraries.

Do not mix the vanilla workflow with a `gcp-vault` invocation by pre-exporting
`CLOUDSDK_CONFIG`, `GOOGLE_APPLICATION_CREDENTIALS`, or access-token variables. Choose one workflow
for a command.

## Test

```bash
bash tests/gcp-vault-test.sh
shellcheck gcp-vault tests/gcp-vault-test.sh
```

## Security model

`gcp-vault` does not store passwords or mint credentials itself. Google Cloud CLI owns the
credential files inside each isolated profile. The wrapper validates paths, expected identities,
ADC token identity, and project allowlists before executing a child command.

Never commit profile files, ADC JSON, access tokens, or service-account keys.

## License

MIT
