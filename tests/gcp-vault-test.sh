#!/usr/bin/env bash
set -euo pipefail

TEST_DIR=$(mktemp -d)
TEST_DIR=$(cd "$TEST_DIR" && pwd -P); readonly TEST_DIR
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); readonly REPO_ROOT
readonly GCP_VAULT="$REPO_ROOT/gcp-vault"
trap 'rm -rf "$TEST_DIR"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { [[ $1 == *"$2"* ]] || fail "expected output to contain: $2"; }

HOME_DIR="$TEST_DIR/home"; PROFILE="$HOME_DIR/.config/gcloud-mama"; ACCOUNTS="$HOME_DIR/.config/gcp-vault/accounts"
mkdir -p "$TEST_DIR/bin" "$PROFILE" "$ACCOUNTS"
printf '{}\n' > "$PROFILE/application_default_credentials.json"
write_config() { printf 'cloudsdk_config=%s\nexpected_account=%s\nallowed_projects=%s\n' "${1:-$PROFILE}" "${2:-mama@example.com}" "${3:-mama-dev,mama-stg,mama-prd}" > "$ACCOUNTS/${4:-mama}"; }
write_config

cat > "$TEST_DIR/bin/gcloud" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ ${CLOUDSDK_CONFIG:-} == "$FAKE_PROFILE" ]] || exit 80
[[ ${CLOUDSDK_CORE_ACCOUNT:-} == mama@example.com ]] || exit 81
case "$*" in
  'auth login mama@example.com')
    [[ ${GOOGLE_APPLICATION_CREDENTIALS+x} != x ]] || exit 86
    printf '%s\n' named-login >> "$FAKE_GCLOUD_LOG"
    [[ ${FAKE_NAMED_LOGIN_FAIL:-0} != 1 ]] || exit 1
    ;;
  'auth application-default login mama@example.com')
    [[ ${GOOGLE_APPLICATION_CREDENTIALS+x} != x ]] || exit 87
    printf '%s\n' adc-login >> "$FAKE_GCLOUD_LOG"
    [[ ${FAKE_ADC_LOGIN_FAIL:-0} != 1 ]] || exit 1
    ;;
  'auth list --filter=account=mama@example.com --format=value(account)')
    [[ ${GOOGLE_APPLICATION_CREDENTIALS+x} != x ]] || exit 82
    [[ ${FAKE_NAMED_LIST_FAIL:-0} != 1 ]] || exit 1
    if [[ ${FAKE_NAMED_MISSING:-0} != 1 ]]; then printf '%s\n' mama@example.com; fi
    ;;
  'auth print-access-token --account=mama@example.com')
    [[ ${GOOGLE_APPLICATION_CREDENTIALS+x} != x ]] || exit 83
    [[ ${FAKE_NAMED_TOKEN_FAIL:-0} != 1 ]] || exit 1
    printf '%s\n' named-token
    ;;
  'auth application-default print-access-token')
    [[ ${GOOGLE_APPLICATION_CREDENTIALS:-} == "$FAKE_PROFILE/application_default_credentials.json" ]] || exit 84
    [[ ${FAKE_ADC_TOKEN_FAIL:-0} != 1 ]] || exit 1
    printf '%s\n' adc-token
    ;;
  *) exit 85 ;;
esac
EOF
cat > "$TEST_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == '--disable --noproxy * --proto =https --tlsv1.2 --silent --show-error --fail --request POST --data-binary @- https://oauth2.googleapis.com/tokeninfo' ]] || { printf 'bad curl argv: <%s>\n' "$*" >&2; exit 90; }
[[ ${GOOGLE_APPLICATION_CREDENTIALS:-} == "$FAKE_PROFILE/application_default_credentials.json" ]] || { printf 'bad curl ADC env\n' >&2; exit 91; }
IFS= read -r body || true
[[ $body == access_token=adc-token ]] || { printf 'bad curl body: <%s>\n' "$body" >&2; exit 92; }
[[ ${FAKE_TOKENINFO_FAIL:-0} != 1 ]] || exit 1
printf '{"email":"%s"}\n' "${FAKE_ADC_EMAIL:-mama@example.com}"
EOF
cat > "$TEST_DIR/bin/jq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == '-er .email' ]] || { printf 'bad jq argv: <%s>\n' "$*" >&2; exit 95; }
IFS= read -r input
[[ $input == *'"email"'* ]] || { printf 'bad jq input: <%s>\n' "$input" >&2; exit 1; }
printf '%s\n' "${FAKE_ADC_EMAIL:-mama@example.com}"
EOF
chmod +x "$TEST_DIR/bin/"{gcloud,curl,jq}

run_vault() {
  env -u GOOGLE_CREDENTIALS -u GOOGLE_APPLICATION_CREDENTIALS -u GOOGLE_BACKEND_CREDENTIALS \
    -u GOOGLE_OAUTH_ACCESS_TOKEN -u GOOGLE_IMPERSONATE_SERVICE_ACCOUNT -u GOOGLE_BACKEND_IMPERSONATE_SERVICE_ACCOUNT \
    -u CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE -u CLOUDSDK_AUTH_ACCESS_TOKEN -u CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT \
    -u CLOUDSDK_CONFIG -u CLOUDSDK_CORE_ACCOUNT -u GCP_VAULT_ACCOUNT \
    PATH="$TEST_DIR/bin:$PATH" HOME="$HOME_DIR" FAKE_PROFILE="$PROFILE" \
    FAKE_GCLOUD_LOG="$TEST_DIR/gcloud.log" "$GCP_VAULT" "$@"
}

INSTALL_PATH="$HOME_DIR/.local/bin/gcp-vault"
if output=$(run_vault list 2>&1); then fail 'list accepted a missing installation'; fi
assert_contains "$output" "Run: $GCP_VAULT install"
mkdir -p "$(dirname "$INSTALL_PATH")"
printf 'occupied\n' > "$INSTALL_PATH"
if output=$(run_vault install 2>&1); then fail 'install overwrote an existing file'; fi
assert_contains "$output" 'refusing to overwrite existing file'
rm "$INSTALL_PATH"
ln -s /tmp/wrong-gcp-vault "$INSTALL_PATH"
if output=$(run_vault list 2>&1); then fail 'list accepted a wrong installation target'; fi
assert_contains "$output" "Run: $GCP_VAULT install"
if output=$(run_vault install 2>&1); then fail 'install overwrote a wrong symlink'; fi
assert_contains "$output" 'refusing to overwrite existing symlink'
rm "$INSTALL_PATH"
ALTERNATE_SOURCE="$TEST_DIR/alternate-gcp-vault.sh"
cp "$GCP_VAULT" "$ALTERNATE_SOURCE"
chmod +x "$ALTERNATE_SOURCE"
ln -s "$ALTERNATE_SOURCE" "$INSTALL_PATH"
run_vault install || fail 'install rejected a byte-identical alternate source'
HOME="$HOME_DIR" PATH="$TEST_DIR/bin:$PATH" "$INSTALL_PATH" list >/dev/null || fail 'invocation through byte-identical installed symlink failed'
printf '\n# mismatch\n' >> "$ALTERNATE_SOURCE"
if output=$(run_vault list 2>&1); then fail 'list accepted a mismatched alternate source'; fi
assert_contains "$output" 'not correctly installed'
if output=$(run_vault install 2>&1); then fail 'install accepted a mismatched alternate source'; fi
assert_contains "$output" 'refusing to overwrite existing symlink'
rm "$INSTALL_PATH"
run_vault install || fail 'install failed'
[[ -L $INSTALL_PATH ]] || fail 'install did not create a symlink'
[[ $(readlink "$INSTALL_PATH") == "$GCP_VAULT" ]] || fail 'install created the wrong symlink target'
run_vault install || fail 'idempotent install failed'
HOME="$HOME_DIR" PATH="$TEST_DIR/bin:$PATH" "$INSTALL_PATH" list >/dev/null || fail 'installed symlink was not executable'

# shellcheck disable=SC2016
output=$(run_vault mama -- bash -c 'printf "%s|%s|%s|%s|%s|%s" "$CLOUDSDK_CONFIG" "$CLOUDSDK_CORE_ACCOUNT" "$GOOGLE_APPLICATION_CREDENTIALS" "$GCP_VAULT_ACCOUNT" "$GCP_VAULT_EXPECTED_ACCOUNT" "$GCP_VAULT_ALLOWED_PROJECTS"')
[[ $output == "$PROFILE|mama@example.com|$PROFILE/application_default_credentials.json|mama|mama@example.com|mama-dev,mama-stg,mama-prd" ]] || fail 'vault exports were incorrect'
# shellcheck disable=SC2016
output=$(run_vault mama bash -c 'printf "<%s><%s><%s>" "$1" "$2" "$3"' _ 'space arg' '*' '$(no-exec)')
# shellcheck disable=SC2016
[[ $output == '<space arg><*><$(no-exec)>' ]] || fail 'command arguments were not preserved'
[[ $(run_vault list) == mama ]] || fail 'list did not print aliases only'

rm -f "$TEST_DIR/gcloud.log"
output=$(run_vault login mama)
assert_contains "$output" 'authenticated account mama@example.com for alias mama'
[[ $(<"$TEST_DIR/gcloud.log") == $'named-login\nadc-login' ]] || fail 'login did not refresh named and ADC credentials in order'
if (export FAKE_NAMED_LOGIN_FAIL=1; run_vault login mama) >"$TEST_DIR/out" 2>&1; then fail 'named login failure was accepted'; fi
assert_contains "$(<"$TEST_DIR/out")" 'gcloud account login failed'
if (export FAKE_ADC_LOGIN_FAIL=1; run_vault login mama) >"$TEST_DIR/out" 2>&1; then fail 'ADC login failure was accepted'; fi
assert_contains "$(<"$TEST_DIR/out")" 'ADC login failed'

for var in GOOGLE_CREDENTIALS GOOGLE_APPLICATION_CREDENTIALS GOOGLE_BACKEND_CREDENTIALS GOOGLE_OAUTH_ACCESS_TOKEN GOOGLE_IMPERSONATE_SERVICE_ACCOUNT GOOGLE_BACKEND_IMPERSONATE_SERVICE_ACCOUNT CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE CLOUDSDK_AUTH_ACCESS_TOKEN CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT CLOUDSDK_CONFIG CLOUDSDK_CORE_ACCOUNT GCP_VAULT_ACCOUNT; do
  if env HOME="$HOME_DIR" PATH="$TEST_DIR/bin:$PATH" "$var=unsafe" "$GCP_VAULT" mama true >"$TEST_DIR/out" 2>&1; then fail "override accepted: $var"; fi
  assert_contains "$(<"$TEST_DIR/out")" "refusing pre-set environment variable: $var"
done

for spec in 'FAKE_NAMED_MISSING=1|expected gcloud account is not authenticated' 'FAKE_NAMED_TOKEN_FAIL=1|could not validate gcloud account token' 'FAKE_ADC_TOKEN_FAIL=1|could not obtain ADC access token' 'FAKE_TOKENINFO_FAIL=1|could not validate ADC identity' 'FAKE_ADC_EMAIL=other@example.com|ADC identity does not match'; do
  assignment=${spec%%|*}; expected=${spec#*|}
  if (export "${assignment?}"; run_vault mama true) >"$TEST_DIR/out" 2>&1; then fail "$assignment was accepted"; fi
  assert_contains "$(<"$TEST_DIR/out")" "$expected"
done

write_config "$TEST_DIR/outside" mama@example.com mama-dev unsafe; mkdir -p "$TEST_DIR/outside"
if run_vault unsafe true >"$TEST_DIR/out" 2>&1; then fail 'outside profile accepted'; fi
assert_contains "$(<"$TEST_DIR/out")" 'outside the allowed profile roots'
write_config "$PROFILE/../gcloud-mama" mama@example.com mama-dev noncanonical
if run_vault noncanonical true >"$TEST_DIR/out" 2>&1; then fail 'noncanonical profile accepted'; fi
assert_contains "$(<"$TEST_DIR/out")" 'unsafe cloudsdk_config path'
ln -s "$ACCOUNTS/mama" "$ACCOUNTS/link"
if run_vault link true >"$TEST_DIR/out" 2>&1; then fail 'symlink config accepted'; fi
rm "$ACCOUNTS/link"
mv "$ACCOUNTS" "$ACCOUNTS-real"; ln -s "$ACCOUNTS-real" "$ACCOUNTS"
if run_vault mama true >"$TEST_DIR/out" 2>&1; then fail 'symlink config directory accepted'; fi
assert_contains "$(<"$TEST_DIR/out")" 'account config directory is missing or unsafe'
rm "$ACCOUNTS"; mv "$ACCOUNTS-real" "$ACCOUNTS"
mv "$PROFILE/application_default_credentials.json" "$PROFILE/adc-real"; ln -s adc-real "$PROFILE/application_default_credentials.json"
if run_vault mama true >"$TEST_DIR/out" 2>&1; then fail 'symlink ADC accepted'; fi
rm "$PROFILE/application_default_credentials.json"; mv "$PROFILE/adc-real" "$PROFILE/application_default_credentials.json"

for spec in 'bad account|mama-dev|malformed expected_account' 'mama@example.com|Bad_Project|malformed allowed_projects' 'mama@example.com|short|malformed allowed_projects'; do
  identity=${spec%%|*}; rest=${spec#*|}; projects=${rest%%|*}; expected=${rest#*|}
  write_config "$PROFILE" "$identity" "$projects" malformed
  if run_vault malformed true >"$TEST_DIR/out" 2>&1; then fail 'malformed value accepted'; fi
  assert_contains "$(<"$TEST_DIR/out")" "$expected"
done
printf 'cloudsdk_config=%s\r\nexpected_account=mama@example.com\nallowed_projects=mama-dev\n' "$PROFILE" > "$ACCOUNTS/control"
if run_vault control true >"$TEST_DIR/out" 2>&1; then fail 'control character accepted'; fi
assert_contains "$(<"$TEST_DIR/out")" 'control character'

printf 'PASS: gcp-vault tests\n'
