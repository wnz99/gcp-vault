#!/usr/bin/env bash
set -euo pipefail

TEST_DIR=$(mktemp -d)
TEST_DIR=$(cd "$TEST_DIR" && pwd -P); readonly TEST_DIR
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); readonly REPO_ROOT
readonly GCP_VAULT="$REPO_ROOT/gcp-vault"
REAL_JQ=$(command -v jq); readonly REAL_JQ; export REAL_JQ
REAL_FIND=$(command -v find); readonly REAL_FIND; export REAL_FIND
trap 'rm -rf "$TEST_DIR"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { [[ $1 == *"$2"* ]] || fail "expected output to contain: $2"; }

HOME_DIR="$TEST_DIR/home"; PROFILE="$HOME_DIR/.config/gcloud-mama"; ACCOUNTS="$HOME_DIR/.config/gcp-vault/accounts"
mkdir -p "$TEST_DIR/bin" "$PROFILE" "$ACCOUNTS"
printf '{}\n' > "$PROFILE/application_default_credentials.json"
write_config() {
  printf 'cloudsdk_config=%s\n' "${1:-$PROFILE}" > "$ACCOUNTS/${4:-mama}"
  [[ -z ${5:-} ]] || printf 'description=%s\n' "$5" >> "$ACCOUNTS/${4:-mama}"
  printf 'expected_account=%s\nallowed_projects=%s\n' "${2:-mama@example.com}" "${3:-mama-dev,mama-stg,mama-prd}" >> "$ACCOUNTS/${4:-mama}"
}
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
  'auth application-default login')
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
if [[ ${FAKE_CHECK_BROWSER:-0} == 1 ]]; then
  case "$*" in
    'auth login mama@example.com'|'auth application-default login')
      python3 - <<'PY'
import os, time, webbrowser
from pathlib import Path
assert webbrowser.open('https://accounts.google.com/o/oauth2/auth?state=a%20b&code=x', new=1)
expected = len(Path(os.environ['FAKE_GCLOUD_LOG']).read_text().splitlines())
for _ in range(200):
    path = Path(os.environ['FAKE_BROWSER_LOG'])
    if path.exists() and len(path.read_text().splitlines()) == expected:
        break
    time.sleep(0.01)
else:
    raise AssertionError('browser did not receive both login URLs')
Path(os.environ['FAKE_LAUNCHER_LOG']).write_text(os.environ['BROWSER'])
PY
      ;;
    *) [[ ${BROWSER:-} == "$FAKE_BROWSER_AMBIENT" ]] || exit 88 ;;
  esac
fi
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
if [[ ${1:-} == -cn ]]; then exec "$REAL_JQ" "$@"; fi
[[ "$*" == '-er .email' ]] || { printf 'bad jq argv: <%s>\n' "$*" >&2; exit 95; }
IFS= read -r input
[[ $input == *'"email"'* ]] || { printf 'bad jq input: <%s>\n' "$input" >&2; exit 1; }
printf '%s\n' "${FAKE_ADC_EMAIL:-mama@example.com}"
EOF
cat > "$TEST_DIR/bin/find" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${FAKE_FIND_FAIL:-0} == 1 ]]; then
  printf 'find leaked-secret-content\n' >&2
  exit 73
fi
exec "$REAL_FIND" "$@"
EOF
chmod +x "$TEST_DIR/bin/"{gcloud,curl,jq,find}

cat > "$TEST_DIR/bin/uname" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_PLATFORM:-Linux}"
EOF
cat > "$TEST_DIR/bin/browser-stub" <<'EOF'
#!/usr/bin/env python3
import json, os, sys
with open(os.environ['FAKE_BROWSER_LOG'], 'a') as log:
    log.write(json.dumps([os.path.basename(sys.argv[0])] + sys.argv[1:]) + '\n')
EOF
chmod +x "$TEST_DIR/bin/"{uname,browser-stub}
for browser_binary in google-chrome firefox brave-browser open; do
  ln -s browser-stub "$TEST_DIR/bin/$browser_binary"
done

run_vault() {
  env -u GOOGLE_CREDENTIALS -u GOOGLE_APPLICATION_CREDENTIALS -u GOOGLE_BACKEND_CREDENTIALS \
    -u GOOGLE_OAUTH_ACCESS_TOKEN -u GOOGLE_IMPERSONATE_SERVICE_ACCOUNT -u GOOGLE_BACKEND_IMPERSONATE_SERVICE_ACCOUNT \
    -u CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE -u CLOUDSDK_AUTH_ACCESS_TOKEN -u CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT \
    -u CLOUDSDK_CONFIG -u CLOUDSDK_CORE_ACCOUNT -u GCP_VAULT_ACCOUNT \
    PATH="${VAULT_TEST_PATH:-$TEST_DIR/bin:$PATH}" HOME="$HOME_DIR" FAKE_PROFILE="$PROFILE" \
    FAKE_GCLOUD_LOG="$TEST_DIR/gcloud.log" "$GCP_VAULT" "$@"
}

assert_status() {
  local expected=$1; shift
  set +e
  "$@" >"$TEST_DIR/stdout" 2>"$TEST_DIR/stderr"
  local actual=$?
  set -e
  [[ $actual == "$expected" ]] || fail "expected status $expected, got $actual for: $*"
}

# Help is available before installation and is stdout-only.
for help_arg in help --help; do
  assert_status 0 run_vault "$help_arg"
  [[ ! -s $TEST_DIR/stderr ]] || fail "$help_arg wrote stderr"
  for phrase in 'list --json' 'describe <alias>' 'cloudsdk_config' 'description' 'expected_account' 'allowed_projects' 'GCP_VAULT_ACCOUNT' 'never put secrets' 'native gcloud' 'exactly one alias'; do
    assert_contains "$(<"$TEST_DIR/stdout")" "$phrase"
  done
done
assert_status 2 run_vault help extra
[[ ! -s $TEST_DIR/stdout ]] || fail 'invalid help usage wrote stdout'

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
run_vault install --replace || fail 'explicit replacement rejected a symlink'
[[ $(readlink "$INSTALL_PATH") == "$GCP_VAULT" ]] || fail 'explicit replacement created the wrong symlink target'
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

rm "$INSTALL_PATH"
printf 'occupied\n' > "$INSTALL_PATH"
if output=$(run_vault install --replace 2>&1); then fail 'explicit replacement overwrote a regular file'; fi
assert_contains "$output" 'refusing to overwrite existing file'
rm "$INSTALL_PATH"
run_vault install || fail 'install after regular-file replacement test failed'

# shellcheck disable=SC2016
output=$(run_vault mama -- bash -c 'printf "%s|%s|%s|%s|%s|%s" "$CLOUDSDK_CONFIG" "$CLOUDSDK_CORE_ACCOUNT" "$GOOGLE_APPLICATION_CREDENTIALS" "$GCP_VAULT_ACCOUNT" "$GCP_VAULT_EXPECTED_ACCOUNT" "$GCP_VAULT_ALLOWED_PROJECTS"')
[[ $output == "$PROFILE|mama@example.com|$PROFILE/application_default_credentials.json|mama|mama@example.com|mama-dev,mama-stg,mama-prd" ]] || fail 'vault exports were incorrect'
# shellcheck disable=SC2016
output=$(run_vault mama bash -c 'printf "<%s><%s><%s>" "$1" "$2" "$3"' _ 'space arg' '*' '$(no-exec)')
# shellcheck disable=SC2016
[[ $output == '<space arg><*><$(no-exec)>' ]] || fail 'command arguments were not preserved'
[[ $(run_vault list) == mama ]] || fail 'list did not print aliases only'

# Inspection accepts optional descriptions and emits exact allowlisted contracts.
write_config "$PROFILE" mama@example.com 'mama-prd,mama-dev' zeta 'Production "primary" \ team'
write_config "$PROFILE" mama@example.com mama-stg Alpha
expected_json='[{"alias":"Alpha","description":null,"expected_account":"mama@example.com","allowed_projects":["mama-stg"]},{"alias":"mama","description":null,"expected_account":"mama@example.com","allowed_projects":["mama-dev","mama-stg","mama-prd"]},{"alias":"zeta","description":"Production \"primary\" \\ team","expected_account":"mama@example.com","allowed_projects":["mama-prd","mama-dev"]}]'
assert_status 0 run_vault list --json
[[ $(<"$TEST_DIR/stdout") == "$expected_json" ]] || fail "JSON inventory mismatch: $(<"$TEST_DIR/stdout")"
[[ ! -s $TEST_DIR/stderr ]] || fail 'list --json wrote stderr'
assert_status 0 run_vault describe zeta
[[ $(<"$TEST_DIR/stdout") == $'alias: zeta\ndescription: Production "primary" \\ team\nexpected_account: mama@example.com\nallowed_projects: mama-prd,mama-dev' ]] || fail 'describe output mismatch'
[[ ! -s $TEST_DIR/stderr ]] || fail 'describe wrote stderr'
[[ $(run_vault describe Alpha) == $'alias: Alpha\ndescription: <none>\nexpected_account: mama@example.com\nallowed_projects: mama-stg' ]] || fail 'legacy describe mismatch'
rm "$ACCOUNTS/Alpha" "$ACCOUNTS/zeta"

# Empty JSON inventory is exact, while legacy list behavior remains unchanged.
mv "$ACCOUNTS/mama" "$TEST_DIR/mama-config"
[[ $(run_vault list --json) == '[]' ]] || fail 'empty JSON inventory mismatch'
mv "$TEST_DIR/mama-config" "$ACCOUNTS/mama"

# Inspection fails closed on every unsafe direct entry and never emits a partial inventory.
mkdir "$ACCOUNTS/directory"
assert_status 1 run_vault list --json
[[ ! -s $TEST_DIR/stdout ]] || fail 'unsafe JSON inventory emitted partial stdout'
rm -r "$ACCOUNTS/directory"
ln -s mama "$ACCOUNTS/symlink"
assert_status 1 run_vault list --json
[[ ! -s $TEST_DIR/stdout ]] || fail 'symlink JSON inventory emitted partial stdout'
rm "$ACCOUNTS/symlink"
printf 'x' > "$ACCOUNTS/bad alias"
assert_status 1 run_vault list --json
[[ ! -s $TEST_DIR/stdout ]] || fail 'unsafe alias emitted partial stdout'
rm "$ACCOUNTS/bad alias"

# A traversal failure is detected before parsing and emits only a sanitized error.
mkdir "$TEST_DIR/list-tmp"
run_vault_find_failure() { FAKE_FIND_FAIL=1 TMPDIR="$TEST_DIR/list-tmp" run_vault "$@"; }
assert_status 1 run_vault_find_failure list --json
[[ ! -s $TEST_DIR/stdout ]] || fail 'failed traversal emitted JSON stdout'
assert_contains "$(<"$TEST_DIR/stderr")" 'failed to enumerate account configs'
[[ "$(<"$TEST_DIR/stderr")" != *leaked-secret-content* ]] || fail 'failed traversal leaked find stderr'
[[ -z $(find "$TEST_DIR/list-tmp" -mindepth 1 -maxdepth 1 -print -quit) ]] || fail 'failed traversal left temporary artifacts'

# Describe validates arity and aliases before path construction.
for args in 'describe' 'describe mama extra' 'list --yaml'; do
  read -r -a argv <<< "$args"
  assert_status 2 run_vault "${argv[@]}"
done
assert_status 1 run_vault describe '../mama'
[[ ! -s $TEST_DIR/stdout ]] || fail 'unsafe describe wrote stdout'
assert_contains "$(<"$TEST_DIR/stderr")" 'unsafe account alias'

# Inspection parser diagnostics never reproduce hostile keys or values.
printf 'cloudsdk_config=%s\nexpected_account=mama@example.com\nallowed_projects=mama-dev\nGOOGLE_OAUTH_ACCESS_TOKEN=super-secret-token\n' "$PROFILE" > "$ACCOUNTS/hostile"
assert_status 1 run_vault list --json
[[ ! -s $TEST_DIR/stdout ]] || fail 'malformed JSON inventory emitted partial stdout'
assert_status 1 run_vault describe hostile
combined="$(<"$TEST_DIR/stdout")$(<"$TEST_DIR/stderr")"
[[ $combined != *GOOGLE_OAUTH_ACCESS_TOKEN* && $combined != *super-secret-token* ]] || fail 'describe leaked hostile config content'
assert_contains "$combined" 'invalid account config: unknown field'
rm "$ACCOUNTS/hostile"

printf 'cloudsdk_config=%s\ndescription=one\ndescription=secret-description\nexpected_account=mama@example.com\nallowed_projects=mama-dev\n' "$PROFILE" > "$ACCOUNTS/duplicate"
assert_status 1 run_vault describe duplicate
[[ "$(<"$TEST_DIR/stderr")" != *secret-description* ]] || fail 'duplicate description leaked value'
rm "$ACCOUNTS/duplicate"

printf 'cloudsdk_config=%s\ndescription=\nexpected_account=mama@example.com\nallowed_projects=mama-dev\n' "$PROFILE" > "$ACCOUNTS/empty-description"
assert_status 1 run_vault describe empty-description
assert_contains "$(<"$TEST_DIR/stderr")" 'invalid account config: empty description'
rm "$ACCOUNTS/empty-description"

# Descriptions permit only ASCII printable bytes; control content is never echoed.
for encoded_description in $'C1-secret-\302\233-tail' $'Unicode-secret-\342\200\256-tail'; do
  printf 'cloudsdk_config=%s\ndescription=%s\nexpected_account=mama@example.com\nallowed_projects=mama-dev\n' \
    "$PROFILE" "$encoded_description" > "$ACCOUNTS/control-description"
  assert_status 1 run_vault describe control-description
  [[ ! -s $TEST_DIR/stdout ]] || fail 'control description wrote stdout'
  assert_contains "$(<"$TEST_DIR/stderr")" 'invalid account config: malformed description'
  [[ "$(<"$TEST_DIR/stderr")" != *secret* ]] || fail 'control description leaked content'
done
rm "$ACCOUNTS/control-description"

rm -f "$TEST_DIR/gcloud.log"
output=$(run_vault login mama)
assert_contains "$output" 'authenticated account mama@example.com for alias mama'
assert_contains "$output" 'Google Workspace password for mama@example.com'
assert_contains "$output" 'not your macOS login, Keychain, aws-vault, or gcp-vault password'
[[ $(<"$TEST_DIR/gcloud.log") == $'named-login\nadc-login' ]] || fail 'login did not refresh named and ADC credentials in order'
if (export FAKE_NAMED_LOGIN_FAIL=1; run_vault login mama) >"$TEST_DIR/out" 2>&1; then fail 'named login failure was accepted'; fi
assert_contains "$(<"$TEST_DIR/out")" 'gcloud account login failed'
if (export FAKE_ADC_LOGIN_FAIL=1; run_vault login mama) >"$TEST_DIR/out" 2>&1; then fail 'ADC login failure was accepted'; fi
assert_contains "$(<"$TEST_DIR/out")" 'ADC login failed'

# Exercise Python webbrowser's real BROWSER parsing, including literal metacharacters,
# both login flows, native platform arguments, cleanup, and override scope.
browser_url='https://accounts.google.com/o/oauth2/auth?state=a%20b&code=x'
# jq expressions and config payloads are literal.
# shellcheck disable=SC2016
for platform in Linux Darwin; do
  mkdir -p "$HOME_DIR/Applications/Google Chrome.app" "$HOME_DIR/Applications/Firefox.app" "$HOME_DIR/Applications/Brave Browser.app"
  for selected_browser in chrome firefox brave; do
    write_config
    printf 'browser=%s\n' "$selected_browser" >> "$ACCOUNTS/mama"
    # shellcheck disable=SC2016
    selected_profile='Work : %s "quoted" $(touch should-not-exist)'
    printf 'browser_profile=%s\n' "$selected_profile" >> "$ACCOUNTS/mama"
    rm -f "$TEST_DIR/gcloud.log" "$TEST_DIR/browser.log" "$TEST_DIR/launcher.log"
    FAKE_PLATFORM="$platform" FAKE_CHECK_BROWSER=1 FAKE_BROWSER_LOG="$TEST_DIR/browser.log" \
      FAKE_LAUNCHER_LOG="$TEST_DIR/launcher.log" FAKE_BROWSER_AMBIENT='ambient-browser' \
      BROWSER='ambient-browser' run_vault login mama >"$TEST_DIR/out"
    case $selected_browser in
      chrome) binary=google-chrome; app='Google Chrome.app' ;;
      firefox) binary=firefox; app='Firefox.app' ;;
      brave) binary=brave-browser; app='Brave Browser.app' ;;
    esac
    if [[ $selected_browser == firefox ]]; then
      profile_args=$("$REAL_JQ" -cn --arg profile "$selected_profile" '["-no-remote","-P",$profile]')
    else
      profile_args=$("$REAL_JQ" -cn --arg profile "$selected_profile" '["--profile-directory="+$profile]')
    fi
    prefix=$("$REAL_JQ" -cn --arg binary "$binary" '[$binary]')
    if [[ $platform == Darwin ]]; then
      prefix=$("$REAL_JQ" -cn --arg app "$HOME_DIR/Applications/$app" '["open","-n","-a",$app,"--args"]')
    fi
    expected=$("$REAL_JQ" -cn --argjson prefix "$prefix" --argjson profile "$profile_args" --arg url "$browser_url" '$prefix + $profile + [$url]')
    [[ $("$REAL_JQ" -sc '.' "$TEST_DIR/browser.log") == "[$expected,$expected]" ]] || fail "$platform $selected_browser received incorrect arguments"
    launcher=$(<"$TEST_DIR/launcher.log"); launcher=${launcher% %s}
    [[ ! -e ${launcher%/*} ]] || fail 'successful login left browser launcher behind'
  done
done

# Browser-only selection omits profile flags; ordinary commands preserve ambient BROWSER.
write_config
printf 'browser=chrome\n' >> "$ACCOUNTS/mama"
rm -f "$TEST_DIR/gcloud.log" "$TEST_DIR/browser.log"
FAKE_CHECK_BROWSER=1 FAKE_BROWSER_LOG="$TEST_DIR/browser.log" FAKE_LAUNCHER_LOG="$TEST_DIR/launcher.log" \
  FAKE_BROWSER_AMBIENT='ambient-browser' BROWSER='ambient-browser' run_vault login mama >/dev/null
# jq expands $url.
# shellcheck disable=SC2016
expected=$("$REAL_JQ" -cn --arg url "$browser_url" '["google-chrome",$url]')
[[ $("$REAL_JQ" -sc '.' "$TEST_DIR/browser.log") == "[$expected,$expected]" ]] || fail 'browser-only login added profile arguments'
# shellcheck disable=SC2016
[[ $(BROWSER='ambient-browser' run_vault mama bash -c 'printf "%s" "$BROWSER"') == ambient-browser ]] || fail 'browser config affected child command'
[[ $(run_vault list --json) == '[{"alias":"mama","description":null,"expected_account":"mama@example.com","allowed_projects":["mama-dev","mama-stg","mama-prd"]}]' ]] || fail 'browser config changed discovery contract'

# Missing browsers fail before either authentication flow; inspection still works.
mkdir "$TEST_DIR/no-browser-bin"
for utility in bash dirname basename readlink; do
  ln -s "$(command -v "$utility")" "$TEST_DIR/no-browser-bin/$utility"
done
for utility in gcloud curl jq uname; do
  ln -s "$TEST_DIR/bin/$utility" "$TEST_DIR/no-browser-bin/$utility"
done
rm -f "$TEST_DIR/gcloud.log"
run_vault_without_browser() { VAULT_TEST_PATH="$TEST_DIR/no-browser-bin" run_vault "$@"; }
assert_status 1 run_vault_without_browser login mama
assert_contains "$(<"$TEST_DIR/stderr")" 'configured browser is not installed on PATH: chrome'
[[ ! -e $TEST_DIR/gcloud.log ]] || fail 'missing browser started authentication'
assert_status 0 run_vault_without_browser describe mama

# Failed authentication also cleans up the launcher.
rm -f "$TEST_DIR/gcloud.log" "$TEST_DIR/browser.log"
if FAKE_ADC_LOGIN_FAIL=1 FAKE_CHECK_BROWSER=1 FAKE_BROWSER_LOG="$TEST_DIR/browser.log" \
  FAKE_LAUNCHER_LOG="$TEST_DIR/launcher.log" FAKE_BROWSER_AMBIENT='' run_vault login mama >"$TEST_DIR/out" 2>&1; then
  fail 'configured browser masked ADC failure'
fi
launcher=$(<"$TEST_DIR/launcher.log"); launcher=${launcher% %s}
[[ ! -e ${launcher%/*} ]] || fail 'failed login left browser launcher behind'

for browser_config in 'browser=safari' 'browser_profile=Work' $'browser=chrome\nbrowser=brave' \
  $'browser=chrome\nbrowser_profile=Work\nbrowser_profile=Other' 'browser=' \
  $'browser=chrome\nbrowser_profile=../Other'; do
  write_config
  printf '%s\n' "$browser_config" >> "$ACCOUNTS/mama"
  assert_status 1 run_vault login mama
  assert_status 1 run_vault describe mama
done
write_config

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
