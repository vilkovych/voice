#!/bin/zsh
# Збирає Voice і ставить у ~/Applications. Автозапуску немає (див. README).
#   ./install.sh          — зібрати, поставити в ~/Applications, (пере)запустити
#   ./install.sh --build  — лише зібрати в ./build (для перевірки)
#   ./install.sh --remove — зупинити і прибрати програму (дані в Application Support/Voice лишаються)
#   VOICE_ADHOC=1 ./install.sh — підпис ad-hoc, без окремої в'язки (дозволи злітатимуть після кожного перезбирання)
set -euo pipefail
cd "$(dirname "$0")"

APP="$HOME/Applications/Voice.app"
BUILT="build/Voice.app"
DATA="$HOME/Library/Application Support/Voice"
STATE="$DATA/state.json"
SIGNDIR="$DATA/signing"
KC="$SIGNDIR/voice-signing.keychain-db"
CN="Voice Local Signing"

# Зупиняє запущений Voice: pid зі state.json, і лише якщо це справді процес Voice.
stop_running() {
  [[ -f "$STATE" ]] || return 0
  local pid comm
  pid=$(/usr/bin/plutil -extract pid raw -o - "$STATE" 2>/dev/null || true)
  [[ "$pid" =~ '^[0-9]+$' ]] || return 0
  comm=$(/bin/ps -p "$pid" -o comm= 2>/dev/null || true)
  [[ "$comm" == */Voice.app/Contents/MacOS/Voice ]] || return 0
  # не обриваємо диктовку: чекаємо, поки Voice стане вільним (до 2 хв)
  local st i
  for i in {1..240}; do
    st=$(/usr/bin/plutil -extract state raw -o - "$STATE" 2>/dev/null || echo idle)
    [[ "$st" == "idle" ]] && break
    (( i == 1 )) && echo "Voice зараз записує або розпізнає — чекаю, поки закінчить…"
    sleep 0.5
  done
  kill "$pid" 2>/dev/null || return 0
  for _ in {1..50}; do
    if ! kill -0 "$pid" 2>/dev/null; then echo "зупинено Voice (pid $pid)"; return 0; fi
    sleep 0.1
  done
  kill -9 "$pid" 2>/dev/null || true
  echo "зупинено Voice примусово (pid $pid)"
}

if [[ "${1:-}" == "--remove" ]]; then
  stop_running
  rm -rf "$APP"
  echo "прибрано: $APP (дані лишились у $DATA)"
  exit 0
fi

# --- Збірка -----------------------------------------------------------------------------
if ! command -v swiftc >/dev/null 2>&1; then
  echo "Немає компілятора Swift. Постав інструменти розробника Apple: xcode-select --install" >&2
  exit 1
fi
TARGET="$(uname -m)-apple-macos13.0"
PROBE=$(mktemp -d)
print -r -- 'import SwiftUI' > "$PROBE/probe.swift"
probe() { swiftc -typecheck "$@" -target "$TARGET" "$PROBE/probe.swift" >/dev/null 2>&1; }

EXTRA=()
if ! probe; then
  # Обхід для Command Line Tools із відомою вадою: компілятор Swift 5.10, а SDK за замовчуванням новіший,
  # і в usr/include/swift лежать і старий module.modulemap, і новий bridging.modulemap
  # («redefinition of module 'SwiftBridging'»). Системне не чіпаємо: беремо старіший SDK,
  # а старий файл підміняємо порожнім через накладку.
  for s in MacOSX14.5.sdk MacOSX14.4.sdk; do
    [[ -d "/Library/Developer/CommandLineTools/SDKs/$s" ]] && { EXTRA=(-sdk "/Library/Developer/CommandLineTools/SDKs/$s"); break; }
  done
  mkdir -p toolchain_fix
  : > toolchain_fix/empty.modulemap
  cat > toolchain_fix/overlay.yaml <<EOF
{
  'version': 0,
  'case-sensitive': 'false',
  'roots': [
    { 'name': '/Library/Developer/CommandLineTools/usr/include/swift', 'type': 'directory',
      'contents': [ { 'name': 'module.modulemap', 'type': 'file',
                      'external-contents': '$PWD/toolchain_fix/empty.modulemap' } ] }
  ]
}
EOF
  EXTRA+=(-vfsoverlay "$PWD/toolchain_fix/overlay.yaml")
  if ! probe "${EXTRA[@]}"; then
    rm -rf "$PROBE"
    echo "Swift не збирає навіть «import SwiftUI». Онови інструменти розробника (xcode-select --install) або Xcode." >&2
    exit 1
  fi
  echo "інструменти розробника з відомою вадою — збираю з обходом"
fi
rm -rf "$PROBE"

rm -rf build
mkdir -p "$BUILT/Contents/MacOS"
swiftc -O -module-name Voice "${EXTRA[@]}" -target "$TARGET" -o "$BUILT/Contents/MacOS/Voice" *.swift
cp Info.plist "$BUILT/Contents/Info.plist"

# --- Підпис -----------------------------------------------------------------------------
# macOS прив'язує дозволи (Мікрофон, Універсальний доступ) до підпису. З ad-hoc кожне перезбирання
# тихо скидало б їх, тому підписуємо постійним самопідписаним сертифікатом з окремої в'язки.
# codesign бачить її лише в списку пошуку користувача — додаємо на час підпису і повертаємо список точно як був.
if [[ -n "${VOICE_ADHOC:-}" ]]; then
  echo "підпис ad-hoc (VOICE_ADHOC): дозволи macOS злітатимуть після кожного перезбирання"
  codesign --force --sign - "$BUILT"
else
  read_list() { security list-keychains -d user | sed -E 's/^[[:space:]]*"(.*)"[[:space:]]*$/\1/'; }

  SAVED=()
  for k in ${(f)"$(read_list)"}; do
    if [[ -n "$k" && "$k" != "$KC" && "${k:t}" != "${KC:t}" ]]; then SAVED+=("$k"); fi
  done

  LIST_TOUCHED=0
  SIGN_TMP=""
  cleanup() {
    if (( LIST_TOUCHED )); then
      security list-keychains -d user -s "${SAVED[@]}" || true
      LIST_TOUCHED=0
    fi
    if [[ -n "$SIGN_TMP" ]]; then rm -rf "$SIGN_TMP"; SIGN_TMP=""; fi
  }
  trap cleanup EXIT
  trap 'cleanup; exit 130' INT TERM

  if (( ${#SAVED} == 0 )); then
    echo "УВАГА: список в'язок користувача порожній — не чіпаю його; підпис ad-hoc." >&2
    echo "УВАГА: з ad-hoc підписом дозволи злітатимуть після кожного перезбирання." >&2
    codesign --force --sign - "$BUILT"
  else
    if [[ ! -f "$KC" ]]; then
      echo "перший раз: створюю сертифікат «$CN» і в'язку $KC"
      mkdir -p "$SIGNDIR"
      chmod 700 "$SIGNDIR"
      SIGN_TMP=$(mktemp -d "$SIGNDIR/tmp.XXXXXX")
      ( umask 077; /usr/bin/openssl rand -hex 24 > "$SIGNDIR/pass" )
      chmod 600 "$SIGNDIR/pass"
      P12PASS=$(/usr/bin/openssl rand -hex 16)
      cat > "$SIGN_TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $CN
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
      # саме /usr/bin/openssl: .p12 від OpenSSL 3 з Homebrew `security import` не приймає
      /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$SIGN_TMP/cert.cnf" \
        -keyout "$SIGN_TMP/key.pem" -out "$SIGN_TMP/cert.pem" 2>/dev/null
      /usr/bin/openssl pkcs12 -export -inkey "$SIGN_TMP/key.pem" -in "$SIGN_TMP/cert.pem" -name "$CN" \
        -out "$SIGN_TMP/id.p12" -passout "pass:$P12PASS"
      PASS=$(<"$SIGNDIR/pass")
      LIST_TOUCHED=1                     # create-keychain дописує в'язку до списку — cleanup поверне
      security create-keychain -p "$PASS" "$KC"
      security set-keychain-settings "$KC"
      security unlock-keychain -p "$PASS" "$KC"
      security import "$SIGN_TMP/id.p12" -k "$KC" -P "$P12PASS" -T /usr/bin/codesign >/dev/null
      security set-key-partition-list -S apple-tool:,apple: -s -k "$PASS" "$KC" >/dev/null
      cleanup                            # ключ і .p12 видалено, список повернуто
    fi
    PASS=$(<"$SIGNDIR/pass")
    security unlock-keychain -p "$PASS" "$KC"
    # у списку буде CSSMERR_TP_NOT_TRUSTED — так і має бути, codesign його бере
    SHA1=$(security find-identity -p codesigning "$KC" | awk -v cn="\"$CN\"" 'index($0, cn) {print $2; exit}')
    [[ "$SHA1" =~ '^[0-9A-F]{40}$' ]] || { echo "не знайшов сертифікат «$CN» у $KC" >&2; exit 1; }
    LIST_TOUCHED=1
    security list-keychains -d user -s "${SAVED[@]}" "$KC"
    codesign --force --timestamp=none --keychain "$KC" --sign "$SHA1" "$BUILT"
    cleanup
    if [[ "$(read_list)" != "$(print -rl -- "${SAVED[@]}")" ]]; then
      echo "УВАГА: список в'язок не збігся з початковим:" >&2
      security list-keychains -d user >&2
      exit 1
    fi
  fi
fi
codesign --verify --strict "$BUILT"
echo "зібрано: $BUILT"
codesign -d -r- "$BUILT" 2>&1 | grep '^designated' || true
[[ "${1:-}" == "--build" ]] && exit 0

# --- Ключ AssemblyAI ----------------------------------------------------------------------
# Розпізнавання йде через AssemblyAI. Ключі — у keys.txt, по одному в рядку
# (якщо ключ не приймається, Voice бере наступний). Voice читає файл перед кожною диктовкою.
KEYS="$DATA/keys.txt"
if [[ ! -s "$KEYS" ]]; then
  mkdir -p "$DATA"
  if [[ -t 0 ]]; then
    echo "Voice розпізнає голос через AssemblyAI, потрібен твій ключ (assemblyai.com → API Keys)."
    print -n "Встав ключ і натисни Enter (порожньо — пропустити): "
    KEY=""
    read -rs KEY || KEY=""
    echo
    KEY="${KEY//[[:space:]]/}"
    if [[ -n "$KEY" ]]; then
      ( umask 077; print -r -- "$KEY" > "$KEYS" )
      echo "ключ збережено в $KEYS (…${KEY[-6,-1]})"
    else
      echo "без ключа Voice писатиме «Немає ключів»; ключ можна дописати пізніше в $KEYS"
    fi
  else
    echo "УВАГА: немає $KEYS — допиши туди ключ AssemblyAI (по одному в рядку)." >&2
  fi
fi

# --- Встановлення -----------------------------------------------------------------------
stop_running
mkdir -p "$HOME/Applications"
rm -rf "$APP"
ditto "$BUILT" "$APP"
open "$APP"
echo "встановлено і запущено: $APP"
echo "Дозволь Мікрофон і Універсальний доступ, коли macOS спитає. Далі: двічі правий Shift — почати диктовку."
