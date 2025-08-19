#!/usr/bin/env bash
set -euo pipefail

cat << "EOF"
                     _____           _        _ _           
    /\              |_   _|         | |      | | |          
   /  \   _ __  _ __  | |  _ __  ___| |_ __ _| | | ___ _ __ 
  / /\ \ | '_ \| '_ \ | | | '_ \/ __| __/ _` | | |/ _ \ '__|
 / ____ \| |_) | |_) || |_| | | \__ \ || (_| | | |  __/ |   
/_/    \_\ .__/| .__/_____|_| |_|___/\__\__,_|_|_|\___|_|   
         | |   | |                                          
         |_|   |_|   
EOF


TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

info() { printf "\n%s\n\n" "$1"; }
err()  { printf "Ошибка: %s\n" "$1" >&2; }
prompt() { read -r -p "$1" REPLY && printf "%s" "$REPLY"; }

need_cmd() {
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Требуется '$cmd' — установите и повторите." >&2
      exit 1
    fi
  done
}

download() {
  local url=$1 out=$2
  if command -v curl >/dev/null 2>&1; then
    curl -L --progress-bar -o "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$out" "$url"
  else
    err "Ни curl, ни wget не установлены."
    exit 1
  fi
}

detect_type_local() {
  local f=$1
  if [[ -z "$f" || ! -e "$f" ]]; then
    echo "unknown"
    return
  fi
  case "${f,,}" in
    *.appimage) echo "appimage"; return;;
    *.sh) echo "shell"; return;;
  esac
  if file "$f" | grep -qi "ELF"; then
    echo "binary"; return
  fi
  if head -n1 "$f" | grep -q '^#!'; then
    echo "shell"; return
  fi
  if strings "$f" 2>/dev/null | grep -q "AppImage"; then
    echo "appimage"; return
  fi
  echo "unknown"
}

backup_if_exists() {
  local target=$1
  if [[ -e "$target" ]]; then
    local bak="${target}.bak.$(date +%s)"
    mv -v "$target" "$bak"
    echo "$bak"
  fi
}

MANIFEST_ROOT="$HOME/.local/share/AppInstaller"
mkdir -p "$MANIFEST_ROOT"

info "Просто Установщик Версии 1.0 by Valentin Stars"

SRC_INPUT=$(prompt "Укажите путь к файлу или URL для скачивания: ")
if [[ -z "$SRC_INPUT" ]]; then
  err "Путь или URL не указан."
  exit 1
fi

if [[ "$SRC_INPUT" =~ ^https?:// ]]; then
  FILENAME=$(basename "${SRC_INPUT%%\?*}")
  OUT="$TMPDIR/$FILENAME"
  info "Скачиваю $SRC_INPUT -> $OUT"
  download "$SRC_INPUT" "$OUT"
else
  if [[ ! -e "$SRC_INPUT" ]]; then
    err "Файл не найден: $SRC_INPUT"
    exit 1
  fi
  FILENAME=$(basename "$SRC_INPUT")
  OUT="$TMPDIR/$FILENAME"
  cp -a "$SRC_INPUT" "$OUT"
fi

chmod +x "$OUT" || true

TYPE=$(detect_type_local "$OUT")
info "Определённый тип: $TYPE"

echo "Где установить приложение?"
echo "  1) В локальную папку пользователя (~/.local/bin)"
echo "  2) В системную папку (/usr/local/bin)"
CHOICE=$(prompt "Выберите 1 или 2 [1]: ")
CHOICE=${CHOICE:-1}
if [[ "$CHOICE" == "2" ]]; then
  INSTALL_DIR="/usr/local/bin"
  NEED_SUDO=true
else
  INSTALL_DIR="$HOME/.local/bin"
  NEED_SUDO=false
fi
mkdir -p "$INSTALL_DIR"

DEFAULT_NAME=$(basename "$FILENAME")
APPNAME=$(prompt "Введите имя команды/исполняемого (по умолчанию: $DEFAULT_NAME): ")
APPNAME=${APPNAME:-$DEFAULT_NAME}
TARGET_PATH="$INSTALL_DIR/$APPNAME"

case "$TYPE" in
  appimage)
    info "Обнаружен AppImage"
    ;;
  shell)
    info "Обнаружен shell-скрипт"
    echo "  a) Установить как исполняемый"
    echo "  b) Выполнить .sh (инсталлятор)"
    SH_CHOICE=$(prompt "Выберите (a/b) [a]: ")
    SH_CHOICE=${SH_CHOICE:-a}
    ;;
  binary)
    info "Обнаружен бинарный ELF"
    ;;
  *)
    info "Не удалось однозначно определить тип"
    GENERIC_CHOICE=$(prompt "Копировать в $INSTALL_DIR как исполняемый (y) или запускать как установщик (n)? [y]: ")
    GENERIC_CHOICE=${GENERIC_CHOICE:-y}
    if [[ "$GENERIC_CHOICE" == "n" ]]; then
      TYPE=run_installer
    else
      TYPE=install_file
    fi
    ;;
esac

if [[ "${TYPE}" == "shell" && "${SH_CHOICE:-a}" == "b" ]]; then
  chmod +x "$OUT"
  if $NEED_SUDO; then
    sudo "$OUT" || { err "Инсталлятор завершился с ошибкой."; exit 1; }
  else
    "$OUT" || { err "Инсталлятор завершился с ошибкой."; exit 1; }
  fi
  EXEC_PATH=$(prompt "Укажите путь к основному исполняемому файлу (или Enter): ")
  if [[ -n "$EXEC_PATH" && -e "$EXEC_PATH" ]]; then
    if $NEED_SUDO; then
      sudo cp -a "$EXEC_PATH" "$TARGET_PATH"
      sudo chmod +x "$TARGET_PATH"
    else
      cp -a "$EXEC_PATH" "$TARGET_PATH"
      chmod +x "$TARGET_PATH"
    fi
  fi
else
  backup=$(backup_if_exists "$TARGET_PATH" || true)
  if [[ -n "${backup:-}" ]]; then
    info "Сделана резервная копия: $backup"
  fi
  if $NEED_SUDO; then
    sudo cp -a "$OUT" "$TARGET_PATH"
    sudo chmod +x "$TARGET_PATH"
  else
    cp -a "$OUT" "$TARGET_PATH"
    chmod +x "$TARGET_PATH"
  fi
  info "Скопировано в: $TARGET_PATH"
fi

APP_ID="$(echo "$APPNAME" | tr ' /' '__')"
APP_DIR_MANIFEST="$MANIFEST_ROOT/$APP_ID"
mkdir -p "$APP_DIR_MANIFEST"

MANIFEST_FILE="$APP_DIR_MANIFEST/manifest.txt"
{
  printf "name=%s\n" "$APPNAME"
  printf "installed=%s\n" "$TARGET_PATH"
  printf "installed_dir=%s\n" "$INSTALL_DIR"
  printf "installed_from=%s\n" "$SRC_INPUT"
  printf "timestamp=%s\n" "$(date --iso-8601=seconds 2>/dev/null || date +%s)"
} > "$MANIFEST_FILE"

UNINSTALLER="$APP_DIR_MANIFEST/uninstall.sh"
cat > "$UNINSTALLER" <<EOF
#!/usr/bin/env bash
set -e
TARGET="$TARGET_PATH"
if [[ -e "\$TARGET" ]]; then
  read -r -p "Удалить \$TARGET ? (y/n) [y]: " c
  c=\${c:-y}
  if [[ "\$c" == "y" ]]; then
    if [[ "$INSTALL_DIR" == /usr/local/bin* ]]; then
      sudo rm -f "\$TARGET"
    else
      rm -f "\$TARGET"
    fi
    echo "Удалено: \$TARGET"
  fi
fi
DESK="$APP_DIR_MANIFEST/$APPNAME.desktop"
if [[ -e "\$DESK" ]]; then
  read -r -p "Удалить ярлык? (y/n) [y]: " c2
  c2=\${c2:-y}
  if [[ "\$c2" == "y" ]]; then
    rm -f "\$DESK"
    update-desktop-database "\$HOME/.local/share/applications/" >/dev/null 2>&1 || true
  fi
fi
EOF
chmod +x "$UNINSTALLER"
info "Создан uninstall-скрипт: $UNINSTALLER"

CREATE_DESK=$(prompt "Создать .desktop ярлык в ~/.local/share/applications ? (y/n) [y]: ")
CREATE_DESK=${CREATE_DESK:-y}
if [[ "$CREATE_DESK" == "y" ]]; then
  DESK_NAME=$(prompt "Название ярлыка [${APPNAME}]: ")
  DESK_NAME=${DESK_NAME:-$APPNAME}
  DESK_FILE="$HOME/.local/share/applications/${APP_ID}.desktop"
  ICON_PATH=""
  WANT_ICON=$(prompt "Добавить иконку? (путь или URL, Enter чтобы пропустить): ")
  if [[ -n "$WANT_ICON" ]]; then
    if [[ "$WANT_ICON" =~ ^https?:// ]]; then
      ICON_DIR="$HOME/.local/share/icons/hicolor/512x512/apps"
      mkdir -p "$ICON_DIR"
      ICON_FILENAME="${APP_ID}.png"
      ICON_PATH="$ICON_DIR/$ICON_FILENAME"
      download "$WANT_ICON" "$ICON_PATH"
    else
      if [[ -e "$WANT_ICON" ]]; then
        ICON_DIR="$HOME/.local/share/icons/hicolor/512x512/apps"
        mkdir -p "$ICON_DIR"
        ICON_FILENAME="${APP_ID}.$(basename "$WANT_ICON" | awk -F. '{print $NF}')"
        ICON_PATH="$ICON_DIR/$ICON_FILENAME"
        cp -a "$WANT_ICON" "$ICON_PATH"
      fi
    fi
  fi
  mkdir -p "$(dirname "$DESK_FILE")"
  cat > "$DESK_FILE" <<DESKTOP
[Desktop Entry]
Name=$DESK_NAME
Exec=$TARGET_PATH
Type=Application
Terminal=false
Categories=Utility;
DESKTOP
  if [[ -n "$ICON_PATH" ]]; then
    echo "Icon=$ICON_PATH" >> "$DESK_FILE"
  fi
  echo "desktop_file=$DESK_FILE" >> "$MANIFEST_FILE"
  cp -a "$DESK_FILE" "$APP_DIR_MANIFEST/" 2>/dev/null || true
  update-desktop-database "$HOME/.local/share/applications/" >/dev/null 2>&1 || true
fi

info "Установка завершена
Исполняемый: $TARGET_PATH
Манифест: $MANIFEST_FILE
Uninstaller: $UNINSTALLER
"
