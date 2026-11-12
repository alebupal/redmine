#!/usr/bin/env bash
# Imputación de horas en Redmine vía API REST.
# Ejecuta con --help para ver la ayuda completa.
set -euo pipefail
# awk/printf con punto decimal aunque el locale sea es_ES
unset LC_ALL
export LC_NUMERIC=C

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
CONFIG_FILE="${REDMINE_CONFIG:-$SCRIPT_DIR/imputar-redmine.conf}"
HOLIDAYS_FILE="${REDMINE_HOLIDAYS:-$SCRIPT_DIR/festivos.json}"
CAL_API="https://calendariosnacionales.com/es/v1"
CAL_DIR="$SCRIPT_DIR/calendario"   # copia local de los festivos descargados (se lee siempre de aquí)
CACHE_DIR="$SCRIPT_DIR/.cache"     # listados de comunidades/provincias/localidades
CAL_CACHE_DAYS=7
CAL_LOCAL_MAX_DAYS=30              # a partir de aquí se avisa de que la copia local de festivos puede estar desfasada
LOCK_FILE="${REDMINE_LOCK:-$SCRIPT_DIR/.imputar.lock}"   # evita que dos ejecuciones escriban en Redmine a la vez
LOCK_HELD=0

C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_RED=$'\e[31m'; C_GREEN=$'\e[32m'
C_YELLOW=$'\e[33m'; C_BLUE=$'\e[34m'; C_CYAN=$'\e[36m'; C_DIM=$'\e[2m'
DOW_NAMES=(lun mar mié jue vie sáb dom)
BOX_LINE="────────────────────────────────────────────────────────────────────────"

# ---------------------------------------------------------------- configuración (valores por defecto)
CONFIG_KEYS=(REDMINE_URL REDMINE_API_KEY TASK_ID VAC_ID HOURS TASK_ACTIVITY VAC_ACTIVITY COMMENT VAC_COMMENT CAL_CCAA CAL_PROV CAL_MUN CAL_LABEL)
ENV_REDMINE_URL="${REDMINE_URL:-}"
ENV_API_KEY="${REDMINE_API_KEY:-}"
REDMINE_URL=""
REDMINE_API_KEY=""
WIZARD=0                # 1 mientras corre el asistente inicial: no se guarda nada hasta el final
AUTO_YES=0              # 1 con -y/--yes: usa valores por defecto sin preguntar
QUICK_CONFIRM=0         # 1 en imputación rápida desde el menú: solo pide la confirmación final
TASK_ID=""
VAC_ID=""
HOURS="8"
TASK_ACTIVITY=""
VAC_ACTIVITY=""
COMMENT=""
VAC_COMMENT="Vacaciones"
CAL_CCAA=""             # localidad para festivos (calendariosnacionales.com); se elige en el asistente
CAL_PROV=""
CAL_MUN=""
CAL_LABEL=""

WORK_MONTH="$(date +%Y-%m)"
API_KEY=""
USER_NAME=""
USER_ID=""
ACTIVITIES=""
TASK_LABEL=""
VAC_LABEL=""
KEY=""
declare -A STATUS_CACHE=() ISSUE_SUBJECT=() ISSUE_PROJECT=()
# Resultado de analyze_month
M_FROM=""; M_TO=""; M_LINES=""; M_HOLIDAYS_OK=1; M_CURRENT=0; M_FUTURE_MONTH=0
M_DAY_LINES=(); M_MISSING=(); M_EXTRA=(); M_FUTURE=0; M_MISSING_HOURS=0
M_WORK_DAYS=0; M_WORK_DAYS_TD=0; M_HOL_WEEKDAY=0
M_EXPECTED=0; M_EXPECTED_TD=0; M_IMPUTED=0; M_IMPUTED_TD=0; M_WEEKEND=0
declare -A M_CAL_STATE=()
declare -A HOLIDAY=() HOLIDAY_SRC=() RANGE_HOL=() CAL_STALE_WARNED=()
RANGE_DATES=(); PERIOD=""; PERIOD_LABEL=""; FROM_DATE=""; TO_DATE=""
HOLIDAYS_NO_LOCAL=0
HOLIDAY_DATE_RE='^([0-9]{4}-)?(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$'

TMP_RESP=$(mktemp)
TMP_FILES=("$TMP_RESP")
cleanup() { rm -f "${TMP_FILES[@]}"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ---------------------------------------------------------------- utilidades e interfaz visual
die()  { echo "${C_RED}✖ $*${C_RESET}" >&2; exit 1; }
info() { echo "${C_BLUE}ℹ${C_RESET} $*"; }
ok()   { echo "${C_GREEN}✔${C_RESET} $*"; }
warn() { echo "${C_YELLOW}⚠${C_RESET} $*"; }
title(){ echo; echo "${C_CYAN}──${C_RESET} ${C_BOLD}$*${C_RESET}"; }
ui_hr(){ echo "   ${C_DIM}${BOX_LINE:0:68}${C_RESET}"; }

pad() { # pad "texto" ancho: rellena con espacios contando letras, no bytes
    local n=$(( $2 - ${#1} ))
    (( n > 0 )) || n=0
    printf '%s%*s' "$1" "$n" ''
}

ui_box() { # ui_box "título" ["subtítulo"]
    local w=72 t="$1" sub="${2:-}"
    echo "${C_CYAN}╭${BOX_LINE:0:$w}╮${C_RESET}"
    if [[ -n "$sub" ]]; then
        local left_w=$(( w - 4 - ${#sub} ))
        (( left_w < ${#t} )) && left_w=${#t}
        printf '%s│%s %s%s%s  %s%s%s %s│%s\n' \
            "$C_CYAN" "$C_RESET" "$C_BOLD" "$(pad "$t" "$left_w")" "$C_RESET" \
            "$C_DIM" "$sub" "$C_RESET" "$C_CYAN" "$C_RESET"
    else
        printf '%s│%s %s%s%s %s│%s\n' \
            "$C_CYAN" "$C_RESET" "$C_BOLD" "$(pad "$t" "$((w - 2))")" "$C_RESET" "$C_CYAN" "$C_RESET"
    fi
    echo "${C_CYAN}╰${BOX_LINE:0:$w}╯${C_RESET}"
}

progress_bar() { # progress_bar imputado esperado [ancho] [color_forzado]
    local imp="$1" exp="$2" width="${3:-14}" col="${4:-}" pct filled empty i bar_f="" bar_e=""
    pct=$(awk -v a="$imp" -v b="$exp" 'BEGIN {
        if (b <= 0) print 100
        else { p = int((a * 100 / b) + 0.5); if (p > 100) p = 100; if (p < 0) p = 0; print p }
    }')
    filled=$(( pct * width / 100 ))
    empty=$(( width - filled ))
    if [[ -z "$col" ]]; then
        if (( pct >= 100 )); then col="$C_GREEN"
        elif (( pct >= 50 )); then col="$C_CYAN"
        else col="$C_YELLOW"; fi
    fi
    for ((i = 0; i < filled; i++)); do bar_f+="█"; done
    for ((i = 0; i < empty; i++)); do bar_e+="░"; done
    printf '%s[%s%s%s%s]%s %3d%%' "$col" "$bar_f" "$C_DIM" "$bar_e" "$col" "$C_RESET" "$pct"
}

# Si la entrada se cierra (EOF: sin terminal, Ctrl+D, tubería vacía) nunca se toma la respuesta por defecto:
# se aborta el script entero. ask suele ejecutarse dentro de $(…) anidados, donde exit solo terminaría esa
# subshell y el llamador seguiría con un valor vacío (o en bucle): se terminan todas las subshells hasta el
# proceso principal, cuyo trap de TERM sale (y limpia los temporales).
input_closed() {
    local pid="$BASHPID" ppid
    local -a chain=()
    echo >&2
    echo "${C_RED}✖ Entrada cerrada (EOF): se cancela sin escribir nada en Redmine${C_RESET}" >&2
    while [[ "$pid" != "$$" ]]; do
        chain+=("$pid")
        ppid=$(awk '/^PPid:/ { print $2 }' "/proc/$pid/status" 2>/dev/null) || break
        [[ -n "$ppid" && "$ppid" != "$pid" && "$ppid" -gt 1 ]] || break
        pid="$ppid"
    done
    kill -s TERM "$$" 2>/dev/null || true
    (( ${#chain[@]} )) && kill -s TERM "${chain[@]}" 2>/dev/null
    exit 1
}

ask() { # ask "pregunta" [defecto]
    local ans
    if [[ -n "${2:-}" ]]; then read -r -p "$1 [$2]: " ans || input_closed; else read -r -p "$1: " ans || input_closed; fi
    echo "${ans:-${2:-}}"
}

confirm() {
    (( AUTO_YES )) && return 0
    local a; read -r -p "$1 [S/n]: " a || input_closed; [[ ! "$a" =~ ^[nN] ]]
}
confirm_no() { local a; read -r -p "$1 [s/N]: " a || input_closed; [[ "$a" =~ ^[sSyY] ]]; }
pause() { read -r -p "${C_DIM}Pulsa Intro para continuar…${C_RESET}" _; }

calc() { # calc "expr" -> resultado; solo números, + - * (la expresión va por -v, nunca como código awk)
    awk -v e="$1" '
        function num() {
            if (match(s, /^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?/)) { v = substr(s, 1, RLENGTH); s = substr(s, RLENGTH + 1); return v + 0 }
            bad = 1; return 0
        }
        function term(   t) { t = num(); while (!bad && substr(s, 1, 1) == "*") { s = substr(s, 2); t *= num() } return t }
        BEGIN {
            s = e; gsub(/[ \t]/, "", s); r = term()
            while (!bad && s != "") {
                op = substr(s, 1, 1); s = substr(s, 2)
                if (op == "+") r += term(); else if (op == "-") r -= term(); else bad = 1
            }
            if (bad) { print "calc: expresión no válida: " e > "/dev/stderr"; exit 1 }
            printf "%g", r
        }'
}
is_gt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'; }
valid_hours() { [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]] && is_gt "$1" 0 && ! is_gt "$1" 24; } # horas de un día: >0 y <=24

load_config() {
    local k val
    if [[ -r "$CONFIG_FILE" ]]; then
        for k in "${CONFIG_KEYS[@]}"; do
            if grep -q "^$k=" "$CONFIG_FILE"; then
                val=$(sed -n "s/^$k=//p" "$CONFIG_FILE" | tail -1)
                val="${val%$'\r'}"   # fichero editado en Windows
                if [[ "$val" =~ ^\"(.*)\"$ || "$val" =~ ^\'(.*)\'$ ]]; then val="${BASH_REMATCH[1]}"; fi
                printf -v "$k" '%s' "$val"
            fi
        done
    fi
    HOURS="${HOURS/,/.}"
    valid_hours "$HOURS" \
        || die "HOURS no válido en $CONFIG_FILE: «$HOURS» (número mayor que 0 y hasta 24, p. ej. 8 o 7.5)"
    REDMINE_URL="${ENV_REDMINE_URL:-$REDMINE_URL}"
    REDMINE_URL="${REDMINE_URL%/}"
    API_KEY="${ENV_API_KEY:-$REDMINE_API_KEY}"
}

save_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")"
    (
        umask 077
        cat > "$CONFIG_FILE" <<EOF
# Configuración de $SCRIPT_NAME (se puede editar a mano; formato CLAVE=valor)
# REDMINE_URL      URL base de Redmine (sin / final)
# REDMINE_API_KEY  Clave de la API (Redmine → Mi cuenta → Clave de acceso a la API)
# TASK_ID          Tarea donde se imputa el trabajo
# VAC_ID           Tarea de vacaciones
# HOURS            Horas por día laborable
# TASK_ACTIVITY    Id de actividad para la tarea (vacío = la de por defecto)
# VAC_ACTIVITY     Id de actividad para vacaciones
# COMMENT          Comentario por defecto de la tarea
# VAC_COMMENT      Comentario por defecto de vacaciones
# CAL_CCAA/CAL_PROV/CAL_MUN  Localidad para festivos en calendariosnacionales.com (CAL_LABEL = nombre)
# Los festivos propios (añadidos o anulados) van aparte, en festivos.json
EOF
        for k in "${CONFIG_KEYS[@]}"; do printf '%s=%s\n' "$k" "${!k}"; done >> "$CONFIG_FILE"
    )
    chmod 600 "$CONFIG_FILE"
    ok "Configuración guardada en $CONFIG_FILE"
}

# ---------------------------------------------------------------- API Redmine
api_curl() { # api_curl args… -> curl con la API key en un fichero de config (-K): no aparece en la lista de procesos
    local k="${API_KEY//\\/\\\\}"
    k="${k//\"/\\\"}"
    curl -K <(printf 'header = "X-Redmine-API-Key: %s"\n' "$k") "$@"
}

api_get() {
    api_curl -fsSg --max-time 30 -H "Accept: application/json" "$REDMINE_URL$1"
}

api_send() { # api_send METODO ruta [json] -> código HTTP (cuerpo de la respuesta en $TMP_RESP; el JSON va por stdin)
    local -a body=()
    (( $# >= 3 )) && body=(-H "Content-Type: application/json" --data-binary @-)
    api_curl -sSg --max-time 30 -o "$TMP_RESP" -w '%{http_code}' -X "$1" "${body[@]}" "$REDMINE_URL$2" <<<"${3:-}"
}

api_errors() { # mensajes de error de la última respuesta de Redmine ($TMP_RESP), separados por comas
    jq -r '(.errors // []) | join(", ")' "$TMP_RESP" 2>/dev/null || true
}

lock_writes() { # bloqueo exclusivo (no espera) antes de escribir en Redmine; 1 si otra ejecución lo tiene
    (( LOCK_HELD )) && return 0
    if ! { exec 9>"$LOCK_FILE"; } 2>/dev/null; then
        warn "No se pudo crear el fichero de bloqueo $LOCK_FILE: no se escribe nada en Redmine"
        return 1
    fi
    if ! flock -n 9; then
        exec 9>&-
        warn "Ya hay otra ejecución de $SCRIPT_NAME escribiendo en Redmine (bloqueo $LOCK_FILE). Espera a que termine y vuelve a intentarlo; no se ha escrito nada."
        return 1
    fi
    LOCK_HELD=1
}

unlock_writes() {
    (( LOCK_HELD )) || return 0
    flock -u 9 || true
    exec 9>&-
    LOCK_HELD=0
}

ensure_api() { # pide/valida la URL y la API key una vez por sesión
    [[ -n "$USER_NAME" ]] && return 0
    local prompted=0 url_prompted=0
    if [[ -z "$REDMINE_URL" ]]; then
        REDMINE_URL=$(ask "URL base de Redmine (ej: https://redmine.ejemplo.com)")
        REDMINE_URL="${REDMINE_URL%/}"
        url_prompted=1
    fi
    if [[ -z "$REDMINE_URL" ]]; then warn "URL de Redmine vacía"; return 1; fi
    if [[ -z "$API_KEY" ]]; then
        read -r -s -p "API key de Redmine (Mi cuenta → Clave de acceso a la API): " API_KEY; echo
        prompted=1
    fi
    if [[ -z "$API_KEY" ]]; then warn "API key vacía"; return 1; fi
    local me
    if ! me=$(api_get "/users/current.json" 2>/dev/null) \
        || ! USER_NAME=$(jq -er '.user | "\(.firstname) \(.lastname)"' <<<"$me"); then
        USER_NAME=""
        (( url_prompted )) && REDMINE_URL=""
        (( prompted )) && API_KEY=""
        warn "No se pudo autenticar en Redmine (¿URL o API key correcta? ¿VPN?)"
        return 1
    fi
    USER_ID=$(jq -r '.user.id' <<<"$me")
    ok "Conectado como $USER_NAME"
    if (( (prompted || url_prompted) && ! WIZARD && ! AUTO_YES )) && confirm "¿Guardar acceso en la configuración?"; then
        REDMINE_API_KEY="$API_KEY"; save_config
    fi
    ACTIVITIES=$(api_get "/enumerations/time_entry_activities.json" 2>/dev/null || true)
    jq -e '.time_entry_activities | length > 0' <<<"$ACTIVITIES" >/dev/null 2>&1 || ACTIVITIES=""
    return 0
}

parse_issue_id() { # acepta "12345", "#12345" o la URL completa
    local v="${1%%\?*}"
    v="${v%/}"; v="${v##*/}"; v="${v#\#}"
    [[ "$v" =~ ^[0-9]+$ ]] || return 1
    echo "$v"
}

fetch_issue() { # fetch_issue id -> consulta Redmine una sola vez por sesión y cachea asunto/proyecto
    local id="$1" json subj proj
    [[ -n "${ISSUE_SUBJECT[$id]:-}" ]] && return 0
    json=$(api_get "/issues/$id.json" 2>/dev/null) || return 1
    subj=$(jq -er '.issue.subject' <<<"$json" 2>/dev/null) || return 1
    proj=$(jq -r '.issue.project.name // ""' <<<"$json" 2>/dev/null)
    ISSUE_SUBJECT[$id]="$subj"
    ISSUE_PROJECT[$id]="$proj"
    return 0
}

issue_label() {
    fetch_issue "$1" || return 1
    printf '#%s %s  %s(%s)%s\n' "$1" "${ISSUE_SUBJECT[$1]}" "$C_DIM" "${ISSUE_PROJECT[$1]}" "$C_RESET"
}

select_assigned_issue() { # selector interactivo de tareas abiertas asignadas al usuario -> id
    local json lines choice id subj proj
    info "Consultando tus tareas abiertas en Redmine…" >&2
    if ! json=$(api_get "/issues.json?assigned_to_id=me&status_id=open&limit=100&sort=updated_on:desc" 2>/dev/null); then
        warn "No se pudieron consultar tus tareas asignadas" >&2
        return 1
    fi
    lines=$(jq -r '.issues[]? | "\(.id)|#\(.id) \(.subject) (\(.project.name))"' <<<"$json")
    if [[ -z "$lines" ]]; then
        warn "No tienes tareas abiertas asignadas directamente" >&2
        return 1
    fi
    while IFS=$'\t' read -r id subj proj; do
        [[ -n "$id" ]] || continue
        ISSUE_SUBJECT[$id]="$subj"
        ISSUE_PROJECT[$id]="$proj"
    done < <(jq -r '.issues[]? | "\(.id)\t\(.subject)\t\(.project.name)"' <<<"$json")
    choice=$(pick_option "tarea" "$lines") || return 1
    echo "${choice%%|*}"
}

ask_issue() { # ask_issue "pregunta" [defecto] [vacío_ok] -> id ("" si vacío_ok y no se escribe nada)
    local raw id label
    while true; do
        raw=$(ask "$1 ('?' = mis tareas)" "${2:-}")
        if [[ -z "$raw" && -n "${3:-}" ]]; then echo ""; return 0; fi
        if [[ "$raw" == "?" || "${raw,,}" == "l" ]]; then
            if id=$(select_assigned_issue); then
                echo "$id"
                return 0
            fi
            continue
        fi
        if ! id=$(parse_issue_id "$raw"); then warn "ID o URL no válida: $raw" >&2; continue; fi
        if ! label=$(issue_label "$id" 2>/dev/null); then warn "No se encuentra la tarea #$id o no tienes acceso" >&2; continue; fi
        echo "   → $label" >&2
        echo "$id"
        return 0
    done
}

pick_issue() { # pick_issue id_configurado "descripción" -> id (confirma el configurado o pide otro)
    local label
    if [[ -n "$1" ]]; then
        if label=$(issue_label "$1" 2>/dev/null); then
            echo "   ${2^}: $label" >&2
            if (( AUTO_YES )) || confirm "   ¿Usar esta tarea?"; then echo "$1"; return 0; fi
        else
            warn "La $2 configurada (#$1) no es accesible" >&2
        fi
    fi
    ask_issue "ID o URL de la $2"
}

activity_valid() {
    [[ -n "$1" && -n "$ACTIVITIES" ]] \
        && jq -e --argjson id "$1" '.time_entry_activities | any(.id == $id)' <<<"$ACTIVITIES" >/dev/null 2>&1
}

activity_name() {
    if activity_valid "${1:-}"; then
        jq -r --argjson id "$1" '.time_entry_activities[] | select(.id == $id) | .name' <<<"$ACTIVITIES"
    else
        echo "por defecto"
    fi
}

choose_activity() { # choose_activity "etiqueta" [defecto] -> id (vacío si no hay actividades)
    [[ -z "$ACTIVITIES" ]] && return 0
    local def="${2:-}" id
    activity_valid "$def" \
        || def=$(jq -r '(.time_entry_activities | (map(select(.is_default))[0] // .[0]) | .id) // empty' <<<"$ACTIVITIES")
    if (( AUTO_YES )) && [[ -n "$def" ]]; then echo "$def"; return 0; fi
    echo "   Actividades disponibles:" >&2
    jq -r '.time_entry_activities[] | "     \(.id)\t\(.name)"' <<<"$ACTIVITIES" >&2
    while true; do
        id=$(ask "   Actividad para $1 (id)" "$def")
        if activity_valid "$id"; then echo "$id"; return 0; fi
        warn "Actividad no válida: $id" >&2
    done
}

resolve_activity() { # usa la configurada si es válida; si no, la pregunta
    if [[ -z "$ACTIVITIES" ]]; then echo ""; return 0; fi
    if activity_valid "$1"; then echo "$1"; return 0; fi
    choose_activity "$2" "${3:-}"
}

fetch_entries() { # fetch_entries desde hasta -> "fecha issue_id horas entry_id actividad|comentario" de mis imputaciones
    # Algunas instancias de Redmine ignoran user_id/from/to sueltos: hay que usar la sintaxis de filtros f[]/op/v
    # Si una página no es la respuesta esperada se aborta: tomarla como «nada imputado» duplicaría horas.
    local offset=0 total page lines
    local filter="f[]=spent_on&op[spent_on]=><&v[spent_on][]=$1&v[spent_on][]=$2&f[]=user_id&op[user_id]==&v[user_id][]=me"
    while :; do
        page=$(api_get "/time_entries.json?$filter&limit=100&offset=$offset") || return 1
        if ! jq -e '(.time_entries | type == "array") and (.total_count | type == "number")' <<<"$page" >/dev/null 2>&1; then
            warn "Respuesta inesperada de Redmine al leer las imputaciones (no es JSON o falta time_entries/total_count)" >&2
            return 1
        fi
        total=$(jq -r '.total_count | floor' <<<"$page")
        if (( total > 1000 )); then warn "Redmine devuelve $total imputaciones: el filtro no se está aplicando" >&2; return 1; fi
        lines=$(jq -r --argjson uid "$USER_ID" --arg from "$1" --arg to "$2" '.time_entries[]
            | select(.user.id == $uid and .spent_on >= $from and .spent_on <= $to)
            | "\(.spent_on) \(.issue.id // "-") \(.hours) \(.id) \((.activity.name // "-") | gsub("[|\\r\\n]+"; " "))|\((.comments // "") | gsub("[|\\r\\n]+"; " "))"' <<<"$page") \
            || { warn "No se pudieron interpretar las imputaciones devueltas por Redmine" >&2; return 1; }
        [[ -z "$lines" ]] || printf '%s\n' "$lines"
        offset=$((offset + 100))
        (( offset < total )) || break
    done
}

# ---------------------------------------------------------------- días y festivos
parse_days() { # parse_days "3 5,7 10-14" último_día [sin_ceros] -> números ordenados, uno por línea
    local tok a b d fmt="%02d"
    [[ -n "${3:-}" ]] && fmt="%d"
    local -a days=()
    for tok in ${1//,/ }; do
        if [[ "$tok" =~ ^([0-9]{1,3})-([0-9]{1,3})$ ]]; then
            a=$((10#${BASH_REMATCH[1]})); b=$((10#${BASH_REMATCH[2]}))
        elif [[ "$tok" =~ ^[0-9]{1,3}$ ]]; then
            a=$((10#$tok)); b=$a
        else
            warn "Valor no válido: $tok" >&2; return 1
        fi
        if (( a < 1 || b > $2 || a > b )); then warn "Fuera de rango (1-$2): $tok" >&2; return 1; fi
        for ((d = a; d <= b; d++)); do days+=("$(printf "$fmt" "$d")"); done
    done
    (( ${#days[@]} )) && printf '%s\n' "${days[@]}" | sort -u -n
    return 0
}

ask_days() { # ask_days "pregunta" último_día -> días
    local raw out
    while true; do
        raw=$(ask "$1 (ej: 3 5,7 10-14; vacío = ninguno)")
        [[ -z "$raw" ]] && return 0
        if out=$(parse_days "$raw" "$2"); then
            [[ -n "$out" ]] && echo "$out"
            return 0
        fi
    done
}

ask_hours() {
    (( AUTO_YES )) && { echo "$2"; return 0; }
    local h
    while true; do
        h=$(ask "$1" "$2"); h="${h/,/.}"
        if valid_hours "$h"; then echo "$h"; return 0; fi
        warn "Número de horas no válido: $h" >&2
    done
}

valid_month() { [[ "$1" =~ ^[0-9]{4}-(0[1-9]|1[0-2])$ ]]; }

ask_month() { # ask_month [AAAA-MM] -> fija MONTH YEAR MON LAST_DAY (por defecto el mes de trabajo), sin preguntar
    MONTH="${1:-$WORK_MONTH}"
    YEAR="${MONTH%-*}"; MON="${MONTH#*-}"
    LAST_DAY=$((10#$(ddate -d "$MONTH-01 +1 month -1 day" +%d)))
    if [[ -z "${1:-}" ]]; then
        info "Mes: ${C_BOLD}$MONTH${C_RESET} ${C_DIM}(cámbialo con ←/→ en el menú)${C_RESET}"
    fi
}

change_month() {
    local m
    while true; do
        m=$(ask "Mes de trabajo (AAAA-MM; vacío = mes actual)" "$WORK_MONTH")
        [[ -z "$m" ]] && m=$(date +%Y-%m)
        if valid_month "$m"; then WORK_MONTH="$m"; ok "Mes de trabajo: $WORK_MONTH"; return 0; fi
        warn "Formato no válido: $m"
    done
}

ask_range() { # fija FROM_DAY TO_DAY FROM_DATE TO_DATE
    while true; do
        FROM_DAY=$(ask "Desde el día" "1")
        TO_DAY=$(ask "Hasta el día" "$LAST_DAY")
        if [[ "$FROM_DAY" =~ ^[0-9]+$ && "$TO_DAY" =~ ^[0-9]+$ ]] \
            && (( 10#$FROM_DAY >= 1 && 10#$TO_DAY <= LAST_DAY && 10#$FROM_DAY <= 10#$TO_DAY )); then
            FROM_DAY=$((10#$FROM_DAY)); TO_DAY=$((10#$TO_DAY)); break
        fi
        warn "Rango no válido (1-$LAST_DAY)"
    done
    FROM_DATE=$(printf '%s-%02d' "$MONTH" "$FROM_DAY")
    TO_DATE=$(printf '%s-%02d' "$MONTH" "$TO_DAY")
}

# ---------------------------------------------------------------- calendario laboral (calendariosnacionales.com)
location_label() {
    if [[ -n "$CAL_MUN" ]]; then echo "$CAL_LABEL"; else echo "solo nacionales"; fi
}

cal_fetch() { # cal_fetch ruta -> JSON de la API (caché de CAL_CACHE_DAYS días; si falla la red, usa la caché antigua)
    local file="$CACHE_DIR/${1//\//_}"
    mkdir -p "$CACHE_DIR"
    if [[ -s "$file" && -n "$(find "$file" -mtime -"$CAL_CACHE_DAYS" 2>/dev/null)" ]]; then cat "$file"; return 0; fi
    if curl -fsS --max-time 20 "$CAL_API/$1" -o "$file.tmp" 2>/dev/null && jq -e . "$file.tmp" >/dev/null 2>&1; then
        mv "$file.tmp" "$file"; cat "$file"; return 0
    fi
    rm -f "$file.tmp"
    if [[ -s "$file" ]]; then cat "$file"; return 0; fi
    return 1
}

cal_holidays_path() { # ruta de la API con los festivos de un año para la localidad configurada
    if [[ -n "$CAL_MUN" ]]; then echo "$1/localidades/$CAL_CCAA/$CAL_PROV/$CAL_MUN.json"; else echo "$1/nacionales.json"; fi
}

cal_holidays_file() { # fichero local con los festivos de un año para la localidad configurada
    if [[ -n "$CAL_MUN" ]]; then echo "$CAL_DIR/$1-$CAL_CCAA-$CAL_PROV-$CAL_MUN.json"; else echo "$CAL_DIR/$1-nacionales.json"; fi
}

cal_download() { # cal_download año fichero_destino -> 0 ok, 2 la API no tiene ese año, 1 error de red/JSON
    local code tmp
    mkdir -p "$CAL_DIR"
    tmp=$(mktemp "$CAL_DIR/.descarga.XXXXXX")
    TMP_FILES+=("$tmp")
    code=$(curl -sS --max-time 20 -o "$tmp" -w '%{http_code}' "$CAL_API/$(cal_holidays_path "$1")" 2>/dev/null) || true
    code=${code:-000}
    if [[ "$code" == "200" ]] && jq -e '.holidays' "$tmp" >/dev/null 2>&1; then mv "$tmp" "$2"; return 0; fi
    rm -f "$tmp"
    [[ "$code" == "404" ]] && return 2
    return 1
}

cal_holidays_json() { # cal_holidays_json año -> JSON de festivos desde la copia local (la descarga si aún no existe)
    local file
    file=$(cal_holidays_file "$1")
    if [[ ! -s "$file" ]]; then cal_download "$1" "$file" || return 1; fi
    cat "$file"
}

cal_warn_stale() { # cal_warn_stale año: avisa (una vez por sesión y solo si se ve) si la copia local puede estar desfasada
    # Llamar directamente, no dentro de $(...), para que se recuerde el aviso.
    local file
    file=$(cal_holidays_file "$1")
    (( $1 >= $(date +%Y) )) && [[ -t 2 && -z "${CAL_STALE_WARNED[$1]:-}" && -s "$file" ]] || return 0
    [[ -n "$(find "$file" -mtime +"$CAL_LOCAL_MAX_DAYS" 2>/dev/null)" ]] || return 0
    CAL_STALE_WARNED[$1]=1
    warn "La copia local de festivos de $1 es del $(cal_local_date "$1") (más de $CAL_LOCAL_MAX_DAYS días): actualízala con $SCRIPT_NAME -u o la tecla u en «Ver festivos»" >&2
}

cal_holiday_lines() { # stdin JSON de festivos, $1 prefijo de fecha (AAAA o AAAA-MM) -> "fecha|nombre|ámbito"
    jq -r --arg m "$1" '
        if (.holidays | type) == "array" then
            .holidays[] | select(.date | startswith($m)) | "\(.date)|\(.name)|nacional"
        else
            .holidays as $h | (.region.name // "autonómico") as $reg | (.municipality.name // "local") as $mun
            | ((($h.national // []) | map({key: .date, value: "nacional"}))
               + (($h.regional // []) | map({key: .date, value: $reg}))
               + (($h.local // []) | map({key: .date, value: $mun}))) | from_entries as $g
            | ($h.calendar // [])[] | select(.date | startswith($m)) | "\(.date)|\(.name)|\($g[.date] // .scope)"
        end'
}

cal_local_date() { # fecha de la última descarga de un año ("" si no hay copia local)
    local file
    file=$(cal_holidays_file "$1")
    [[ -s "$file" ]] && date -r "$file" +%d/%m/%Y
    return 0
}

cal_source_line() { # cal_source_line año -> pie con la atribución (obligatoria) y la fecha de la copia local
    local fecha
    fecha=$(cal_local_date "$1")
    echo "   ${C_DIM}Fuente: calendariosnacionales.com (copia local de $1${fecha:+ descargada el $fecha}) · propios: $(basename "$HOLIDAYS_FILE")${C_RESET}"
}

cal_update() { # cal_update [años…] -> descarga de nuevo y enseña qué ha cambiado (por defecto: este año y el siguiente)
    local y file tmp rc changes
    local -a years=("$@")
    (( ${#years[@]} )) || years=("$(date +%Y)" "$(( $(date +%Y) + 1 ))")
    title "Actualizar festivos  ${C_DIM}($(location_label) · calendariosnacionales.com)${C_RESET}"
    for y in "${years[@]}"; do
        file=$(cal_holidays_file "$y")
        tmp=$(mktemp)
        TMP_FILES+=("$tmp")
        rc=0; cal_download "$y" "$tmp" || rc=$?
        if (( rc == 2 )); then warn "$y: la API aún no tiene ese año"; rm -f "$tmp"; continue; fi
        if (( rc )); then warn "$y: no se pudo descargar (sin conexión?); se mantiene la copia local"; rm -f "$tmp"; continue; fi
        if [[ ! -s "$file" ]]; then
            mkdir -p "$CAL_DIR"; mv "$tmp" "$file"
            ok "$y: descargados $(cal_holiday_lines "$y" < "$file" | grep -c . || true) festivos"
        else
            changes=$(awk -F'|' '
                NR == FNR { old[$1] = $2 " (" $3 ")"; next }
                { new[$1] = $2 " (" $3 ")" }
                END {
                    for (d in new) if (!(d in old)) print d "  + " new[d]
                    for (d in old) if (!(d in new)) print d "  - " old[d]
                    for (d in new) if ((d in old) && old[d] != new[d]) print d "  ~ " old[d] " → " new[d]
                }' <(cal_holiday_lines "$y" < "$file") <(cal_holiday_lines "$y" < "$tmp") | sort)
            mv "$tmp" "$file"
            if [[ -z "$changes" ]]; then
                ok "$y: sin cambios"
            else
                ok "$y: hay cambios"
                while IFS= read -r line; do
                    case "$line" in
                        *"  + "*) echo "     ${C_GREEN}$line${C_RESET}" ;;
                        *"  - "*) echo "     ${C_RED}$line${C_RESET}" ;;
                        *)        echo "     ${C_YELLOW}$line${C_RESET}" ;;
                    esac
                done <<<"$changes"
            fi
        fi
        if [[ -n "$CAL_MUN" ]] && ! jq -e '(.holidays.local // []) | length > 0' "$file" >/dev/null 2>&1; then
            warn "$y: todavía sin festivos locales publicados para $CAL_LABEL"
        fi
    done
    echo "   ${C_DIM}Copia local en $CAL_DIR${C_RESET}"
    STATUS_CACHE=()
    return 0
}

norm() { iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null | tr '[:upper:]' '[:lower:]'; } # sin tildes ni mayúsculas

pick_option() { # pick_option "qué" "slug|nombre (una por línea)" -> línea elegida; lista numerada, con buscador si es larga
    local what="$1" filter="" n i pat
    local -a all=() shown=()
    mapfile -t all <<<"$2"
    (( ${#all[@]} )) && [[ -n "${all[0]}" ]] || return 1
    while true; do
        if (( ${#all[@]} > 25 )); then
            filter=$(ask "   Busca la $what (parte del nombre; vacío = cancelar)")
            [[ -z "$filter" ]] && return 1
            pat=$(printf '%s' "$filter" | norm)
            mapfile -t shown < <(paste -d'\t' <(printf '%s\n' "${all[@]}" | cut -d'|' -f2 | norm) <(printf '%s\n' "${all[@]}") \
                | awk -F'\t' -v p="$pat" 'index($1, p) { print $2 }')
            if (( ${#shown[@]} == 0 )); then warn "Ninguna $what coincide con «$filter»" >&2; continue; fi
            # si una coincide exactamente con lo escrito (sin tildes ni mayúsculas), se elige directamente
            for i in "${!shown[@]}"; do
                if [[ "$(printf '%s' "${shown[$i]#*|}" | norm)" == "$pat" ]]; then shown=("${shown[$i]}"); break; fi
            done
        else
            shown=("${all[@]}")
        fi
        if (( ${#shown[@]} == 1 )); then echo "   → ${shown[0]#*|}" >&2; echo "${shown[0]}"; return 0; fi
        for i in "${!shown[@]}"; do printf '   %s%3d%s  %s\n' "$C_BOLD" "$((i + 1))" "$C_RESET" "${shown[$i]#*|}" >&2; done
        n=$(ask "   Número de la $what (vacío = $( (( ${#all[@]} > 25 )) && echo 'buscar otra vez' || echo cancelar))")
        if [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#shown[@]} )); then
            echo "   → ${shown[$((n - 1))]#*|}" >&2; echo "${shown[$((n - 1))]}"; return 0
        fi
        [[ -n "$n" ]] && warn "Número no válido: $n" >&2
        (( ${#all[@]} > 25 )) || [[ -n "$n" ]] || return 1
    done
}

select_location() { # Comunidad > Provincia > Localidad, y se guarda en la configuración
    local year json ccaa prov mun
    year=$(date +%Y)
    title "Localidad para los festivos"
    echo "   ${C_DIM}Actual: $(location_label) · datos de calendariosnacionales.com${C_RESET}"
    json=$(cal_fetch "$year/comunidades.json") || { warn "No se pudo consultar calendariosnacionales.com"; return 1; }
    ccaa=$(pick_option "comunidad" "$(jq -r '.communities[] | "\(.slug)|\(.name)"' <<<"$json")") || return 0
    json=$(cal_fetch "$year/regiones/${ccaa%%|*}/provincias.json") || { warn "No se pudieron leer las provincias"; return 1; }
    prov=$(pick_option "provincia" "$(jq -r '.provinces[] | "\(.slug)|\(.name)"' <<<"$json")") || return 0
    json=$(cal_fetch "$year/regiones/${ccaa%%|*}/provincias/${prov%%|*}/localidades.json") || { warn "No se pudieron leer las localidades"; return 1; }
    mun=$(pick_option "localidad" "$(jq -r '.municipalities[] | "\(.slug)|\(.name)"' <<<"$json")") || return 0
    CAL_CCAA="${ccaa%%|*}"; CAL_PROV="${prov%%|*}"; CAL_MUN="${mun%%|*}"
    CAL_LABEL="${mun#*|} (${prov#*|}, ${ccaa#*|})"
    ok "Localidad para festivos: $CAL_LABEL"
    (( WIZARD )) && return 0
    save_config
    cal_update
}

local_holiday_entries() { # festivos.json -> "fecha|descripción|tipo" por línea (tipo: festivo | laborable)
    [[ -s "$HOLIDAYS_FILE" ]] || return 0
    if ! jq -r --arg re "$HOLIDAY_DATE_RE" \
        '.[] | select((.fecha // "") | test($re))
             | "\(.fecha)|\(.descripcion // "")|\(if .tipo == "laborable" then "laborable" else "festivo" end)"' "$HOLIDAYS_FILE" 2>/dev/null; then
        warn "$HOLIDAYS_FILE no es un JSON válido; se ignora" >&2
    fi
    return 0
}

set_local_holidays() { # set_local_holidays < "fecha|descripción|tipo" por línea -> reescribe festivos.json
    local tmp
    tmp=$(mktemp "$HOLIDAYS_FILE.XXXXXX")
    TMP_FILES+=("$tmp")
    jq -R -n '[inputs | select(length > 0) | split("|")
               | {fecha: .[0], descripcion: (.[1] // ""), tipo: (if .[2] == "laborable" then "laborable" else "festivo" end)}]
              | unique_by(.fecha) | sort_by(.fecha)' > "$tmp" \
        && mv "$tmp" "$HOLIDAYS_FILE" && ok "Festivos guardados en $HOLIDAYS_FILE"
}

add_holiday() { # add_holiday DD descripción origen
    local d="$1" name="$2" src="$3"
    if [[ -z "${HOLIDAY[$d]:-}" ]]; then
        HOLIDAY[$d]="$name"; HOLIDAY_SRC[$d]="$src"; return 0
    fi
    if [[ "${HOLIDAY[$d],,}" != *"${name,,}"* ]]; then HOLIDAY[$d]+=" / $name"; fi
    if [[ "${HOLIDAY_SRC[$d]:-}" != *"$src"* ]]; then HOLIDAY_SRC[$d]+="${HOLIDAY_SRC[$d]:+, }$src"; fi
    return 0
}

load_holidays() { # load_holidays año mes -> HOLIDAY[DD]=descripción, HOLIDAY_SRC[DD]=ámbito; 1 si no hay datos oficiales
    # Oficiales: copia local de calendariosnacionales.com (calendario/), se descarga solo si falta ese año.
    # Después los propios de festivos.json: añaden festivos, renombran oficiales o los anulan (tipo laborable).
    local d name src date tipo lines json rc=0
    HOLIDAY=(); HOLIDAY_SRC=(); HOLIDAYS_NO_LOCAL=0
    if json=$(cal_holidays_json "$1"); then
        lines=$(cal_holiday_lines "$1-$2" <<<"$json")
        while IFS='|' read -r date name src; do
            [[ -z "$date" ]] && continue
            [[ "$name" == "Fiesta Local" ]] && name="Fiesta local"
            add_holiday "${date:8:2}" "$name" "$src"
        done <<<"$lines"
        if [[ -n "$CAL_MUN" ]] && ! jq -e '(.holidays.local // []) | length > 0' <<<"$json" >/dev/null 2>&1; then
            HOLIDAYS_NO_LOCAL=1
        fi
        cal_warn_stale "$1"
    else
        rc=1
    fi
    while IFS='|' read -r date name tipo; do
        [[ "$date" == "$2-"?? || "$date" == "$1-$2-"?? ]] || continue
        d="${date: -2}"
        if [[ "$tipo" == "laborable" ]]; then
            unset "HOLIDAY[$d]" "HOLIDAY_SRC[$d]"
        elif [[ -n "${HOLIDAY[$d]:-}" ]]; then
            if [[ -n "$name" ]]; then HOLIDAY[$d]="$name"; fi
        else
            HOLIDAY[$d]="${name:-Festivo propio}"; HOLIDAY_SRC[$d]="propio"
        fi
    done < <(local_holiday_entries)
    return $rc
}

print_holidays() {
    local d
    for d in $(printf '%s\n' "${!HOLIDAY[@]}" | sort); do
        echo "     $MONTH-$d ${DOW_NAMES[$(( $(ddate -d "$MONTH-$d" +%u) - 1 ))]}  $(pad "${HOLIDAY[$d]}" 48) ${C_DIM}${HOLIDAY_SRC[$d]:-}${C_RESET}"
    done
}

# ---------------------------------------------------------------- imputar
# Aritmética de fechas civiles (AAAA-MM-DD) en UTC: sin cambios de hora, la medianoche siempre existe
ddate() { TZ=UTC date "$@"; }

short_date() { # 2026-10-26 -> "lun 26/10"
    echo "${DOW_NAMES[$(( $(ddate -d "$1" +%u) - 1 ))]} $(ddate -d "$1" +%d/%m)"
}

date_list() { # date_list desde hasta -> una fecha por línea
    local d="$1"
    while [[ ! "$d" > "$2" ]]; do echo "$d"; d=$(ddate -d "$d +1 day" +%F); done
}

week_start() { ddate -d "$1 -$(( $(ddate -d "$1" +%u) - 1 )) days" +%F; } # lunes de la semana de una fecha

parse_date() { # acepta 15, 15/10, 15/10/2026, 2026-10-15, hoy, ayer -> AAAA-MM-DD
    local v="${1,,}" y="${WORK_MONTH%-*}" m="${WORK_MONTH#*-}" out
    case "$v" in
        hoy)  date +%F; return 0 ;;
        ayer) date -d yesterday +%F; return 0 ;;
    esac
    if [[ "$v" =~ ^([0-9]{1,2})$ ]]; then
        out=$(printf '%s-%s-%02d' "$y" "$m" "$((10#$v))")
    elif [[ "$v" =~ ^([0-9]{1,2})/([0-9]{1,2})(/([0-9]{4}))?$ ]]; then
        out=$(printf '%s-%02d-%02d' "${BASH_REMATCH[4]:-$y}" "$((10#${BASH_REMATCH[2]}))" "$((10#${BASH_REMATCH[1]}))")
    elif [[ "$v" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        out="$v"
    else
        return 1
    fi
    [[ "$(ddate -d "$out" +%F 2>/dev/null)" == "$out" ]] || return 1
    echo "$out"
}

choose_period() { # choose_period [mes|semana|semana-pasada|hoy] -> fija FROM_DATE TO_DATE PERIOD PERIOD_LABEL
    local today mon d choice="${1:-}"
    today=$(date +%F); mon=$(week_start "$today")
    if [[ -z "$choice" ]]; then
        if (( AUTO_YES )); then
            choice="mes"
        else
            echo "   ¿Qué quieres imputar?"
            menu_item m "Mes completo" "$(month_label "$WORK_MONTH")"
            menu_item s "Esta semana" "$(short_date "$mon") – $(short_date "$(ddate -d "$mon +4 days" +%F)")"
            menu_item p "Semana pasada" "$(short_date "$(ddate -d "$mon -7 days" +%F)") – $(short_date "$(ddate -d "$mon -3 days" +%F)")"
            menu_item d "Hoy" "$(short_date "$today")"
            menu_item o "Otro día"
            menu_item r "Rango de días del mes" "$(month_label "$WORK_MONTH")"
            menu_item q "Cancelar"
            read_key "Periodo [m]:"
            case "$KEY" in
                m|M|enter) choice="mes" ;;
                s|S) choice="semana" ;;
                p|P) choice="semana-pasada" ;;
                d|D) choice="hoy" ;;
                o|O) choice="dia" ;;
                r|R) choice="rango" ;;
                *)   return 1 ;;
            esac
        fi
    fi
    PERIOD="$choice"
    case "$choice" in
        mes)
            ask_month
            FROM_DATE="$MONTH-01"; TO_DATE=$(printf '%s-%02d' "$MONTH" "$LAST_DAY")
            PERIOD_LABEL="$(month_label "$MONTH")" ;;
        semana)
            FROM_DATE="$mon"; TO_DATE=$(ddate -d "$mon +6 days" +%F)
            PERIOD_LABEL="semana del $(short_date "$FROM_DATE")" ;;
        semana-pasada)
            FROM_DATE=$(ddate -d "$mon -7 days" +%F); TO_DATE=$(ddate -d "$mon -1 day" +%F)
            PERIOD_LABEL="semana del $(short_date "$FROM_DATE")" ;;
        hoy)
            FROM_DATE="$today"; TO_DATE="$today"; PERIOD="dia"
            PERIOD_LABEL="$(short_date "$today")" ;;
        dia)
            while true; do
                d=$(ask "Día (15, 15/10, 2026-10-15, ayer…)")
                [[ -z "$d" ]] && return 1
                if FROM_DATE=$(parse_date "$d"); then break; fi
                warn "Fecha no válida: $d"
            done
            TO_DATE="$FROM_DATE"; PERIOD_LABEL="$(short_date "$FROM_DATE") $(ddate -d "$FROM_DATE" +%Y)" ;;
        rango)
            ask_month; ask_range
            PERIOD_LABEL="$(short_date "$FROM_DATE") – $(short_date "$TO_DATE")" ;;
        *) return 1 ;;
    esac
    info "Periodo: ${C_BOLD}$PERIOD_LABEL${C_RESET}  ${C_DIM}($FROM_DATE → $TO_DATE)${C_RESET}"
}

load_holidays_range() { # load_holidays_range desde hasta -> RANGE_HOL[fecha]="descripción"; 1 si falla alguna consulta
    local m end_m d rc=0 no_local=0
    RANGE_HOL=()
    m="${1:0:7}"; end_m="${2:0:7}"
    while :; do
        load_holidays "${m%-*}" "${m#*-}" || rc=1
        (( HOLIDAYS_NO_LOCAL )) && no_local=1
        for d in "${!HOLIDAY[@]}"; do
            if [[ ! "$m-$d" < "$1" && ! "$m-$d" > "$2" ]]; then RANGE_HOL["$m-$d"]="${HOLIDAY[$d]}"; fi
        done
        [[ "$m" == "$end_m" ]] && break
        m=$(ddate -d "$m-01 +1 month" +%Y-%m)
    done
    HOLIDAYS_NO_LOCAL=$no_local
    return $rc
}

ask_range_days() { # ask_range_days "pregunta" -> fechas del periodo (se escriben como días del mes: 3 5,7 10-14)
    local d dt
    local -A wanted=()
    while read -r d; do [[ -n "$d" ]] && wanted[$d]=1; done < <(ask_days "$1" 31)
    (( ${#wanted[@]} )) || return 0
    for dt in "${RANGE_DATES[@]}"; do
        if [[ -n "${wanted[${dt:8:2}]:-}" ]]; then echo "$dt"; unset "wanted[${dt:8:2}]"; fi
    done
    for d in "${!wanted[@]}"; do warn "El día $d no está en el periodo; se ignora" >&2; done
    return 0
}

cmd_imputar() { # cmd_imputar dry_run(0|1) [mes|semana|semana-pasada|hoy]
    local dry="$1"
    local task_id task_hours task_act task_comment
    local vac_id="" vac_hours vac_act="" vac_comment=""
    local d dt dow label kind issue target act comment existing remaining extra code err payload h f total_plan idx
    local -A VACATION=() EXISTING=()
    local -a PLAN_DATES=() PLAN_ISSUES=() PLAN_HOURS=() PLAN_ACTS=() PLAN_COMMENTS=() PLAN_KINDS=() PLAN_TARGETS=()
    local -a SKIP_HOLIDAYS=() SKIP_DONE=() FAILED=() CHANGES=()
    local weekends=0 ok_task_days=0 ok_task_hours=0 ok_vac_days=0 ok_vac_hours=0

    ensure_api || return 1
    if (( dry )); then warn "Simulación: no se imputará nada"; fi

    title "Periodo"
    choose_period "${2:-}" || { warn "Cancelado"; return 0; }
    if (( AUTO_YES )) && [[ "$TO_DATE" > "$(date +%F)" ]]; then
        if [[ "$FROM_DATE" > "$(date +%F)" ]]; then warn "Con -y no se imputan días futuros: no hay nada que imputar"; return 0; fi
        TO_DATE=$(date +%F)
        info "Con -y no se imputan días futuros: solo hasta hoy ${C_DIM}($FROM_DATE → $TO_DATE)${C_RESET}"
    fi
    mapfile -t RANGE_DATES < <(date_list "$FROM_DATE" "$TO_DATE")

    title "Tarea"
    task_id=$(pick_issue "$TASK_ID" "tarea principal")
    task_hours=$(ask_hours "Horas por día" "$HOURS")
    task_act=$(resolve_activity "$TASK_ACTIVITY" "la tarea")
    echo "   Actividad: $(activity_name "$task_act")"
    if (( AUTO_YES )); then
        task_comment="$COMMENT"
    else
        task_comment=$(ask "Comentario (opcional)" "$COMMENT")
    fi

    if (( ! AUTO_YES )); then
        title "Vacaciones"
        if [[ "$PERIOD" == "dia" ]]; then
            if confirm_no "¿Es día de vacaciones?"; then VACATION[$FROM_DATE]=1; fi
        else
            while read -r dt; do [[ -n "$dt" ]] && VACATION[$dt]=1; done \
                < <(ask_range_days "Días de vacaciones (día del mes)")
        fi
        vac_hours="$task_hours"
        if (( ${#VACATION[@]} )); then
            vac_id=$(pick_issue "$VAC_ID" "tarea de vacaciones")
            vac_act=$(resolve_activity "$VAC_ACTIVITY" "vacaciones" "$task_act")
            echo "   Actividad: $(activity_name "$vac_act")"
            vac_comment=$(ask "Comentario vacaciones" "$VAC_COMMENT")
        fi

        [[ "$task_id" != "$TASK_ID" ]] && CHANGES+=("tarea principal #$task_id")
        [[ "$task_hours" != "$HOURS" && "$PERIOD" != "dia" ]] && CHANGES+=("${task_hours}h/día")
        [[ -n "$task_act" && "$task_act" != "$TASK_ACTIVITY" ]] && CHANGES+=("actividad tarea")
        [[ -n "$vac_id" && "$vac_id" != "$VAC_ID" ]] && CHANGES+=("vacaciones #$vac_id")
        [[ -n "$vac_act" && "$vac_act" != "$VAC_ACTIVITY" ]] && CHANGES+=("actividad vacaciones")
        if (( ${#CHANGES[@]} && ! dry )) && confirm "¿Guardar como predeterminado: $(IFS=,; echo "${CHANGES[*]}")?"; then
            TASK_ID="$task_id"
            [[ "$PERIOD" != "dia" ]] && HOURS="$task_hours"
            [[ -n "$task_act" ]] && TASK_ACTIVITY="$task_act"
            [[ -n "$vac_id" ]] && VAC_ID="$vac_id"
            [[ -n "$vac_act" ]] && VAC_ACTIVITY="$vac_act"
            save_config
        fi
    fi

    title "Festivos"
    # Con -y nadie revisa los festivos: si no son fiables se aborta (la imputación rápida del menú sí se confirma)
    local strict=$(( AUTO_YES && ! QUICK_CONFIRM ))
    if ! load_holidays_range "$FROM_DATE" "$TO_DATE"; then
        if (( strict )); then warn "No se pudieron consultar los festivos oficiales: con -y no se imputa (ejecuta sin -y para indicarlos a mano)"; return 1; fi
        warn "No se pudieron consultar los festivos oficiales; indícalos a mano"
    fi
    if (( HOLIDAYS_NO_LOCAL )); then
        if (( strict )); then warn "Aún no hay festivos locales publicados para $CAL_LABEL en ese año: con -y no se imputa (ejecuta sin -y para revisarlos)"; return 1; fi
        warn "Aún no hay festivos locales publicados para $CAL_LABEL en ese año; revisa si falta alguno"
    fi
    if [[ "$PERIOD" == "dia" ]]; then
        if [[ -n "${RANGE_HOL[$FROM_DATE]:-}" ]]; then
            warn "$(short_date "$FROM_DATE") es festivo: ${RANGE_HOL[$FROM_DATE]}"
            if (( ! AUTO_YES )) && confirm_no "¿Imputar igualmente?"; then unset "RANGE_HOL[$FROM_DATE]"; fi
        else
            info "No es festivo"
        fi
    else
        if (( ${#RANGE_HOL[@]} )); then
            info "Festivos en el periodo:"
            for dt in $(printf '%s\n' "${!RANGE_HOL[@]}" | sort); do echo "     $(short_date "$dt")  ${RANGE_HOL[$dt]}"; done
            if (( ! AUTO_YES )); then
                while read -r dt; do [[ -n "$dt" ]] && unset "RANGE_HOL[$dt]"; done \
                    < <(ask_range_days "¿Alguno NO es festivo para ti? Días a quitar")
            fi
        else
            info "No hay festivos en el periodo"
        fi
        if (( ! AUTO_YES )); then
            while read -r dt; do [[ -n "$dt" ]] && RANGE_HOL[$dt]="Festivo (manual)"; done \
                < <(ask_range_days "Otros festivos en el periodo")
        fi
    fi

    info "Consultando lo ya imputado entre $FROM_DATE y $TO_DATE…"
    local existing_lines
    existing_lines=$(fetch_entries "$FROM_DATE" "$TO_DATE") || { warn "No se pudieron leer las imputaciones existentes"; return 1; }
    while read -r dt _ h _; do
        [[ -z "$dt" ]] && continue
        EXISTING[$dt]=$(calc "${EXISTING[$dt]:-0} + $h")
    done <<<"$existing_lines"

    title "Plan de imputación — $PERIOD_LABEL"
    for dt in "${RANGE_DATES[@]}"; do
        dow=$(ddate -d "$dt" +%u)
        label="$dt ${DOW_NAMES[$((dow - 1))]}"
        if (( dow >= 6 )); then
            weekends=$((weekends + 1)); echo "  ${C_DIM}$label  fin de semana${C_RESET}"; continue
        fi
        if [[ -n "${RANGE_HOL[$dt]:-}" ]]; then
            [[ -n "${VACATION[$dt]:-}" ]] && warn "$dt es festivo y estaba marcado como vacaciones: no se imputa"
            SKIP_HOLIDAYS+=("$dt ${RANGE_HOL[$dt]}")
            echo "  ${C_YELLOW}$label  festivo: ${RANGE_HOL[$dt]}${C_RESET}"; continue
        fi

        if [[ -n "${VACATION[$dt]:-}" ]]; then
            kind="vacaciones"; issue="$vac_id"; target="$vac_hours"; act="$vac_act"; comment="$vac_comment"
        else
            kind="tarea"; issue="$task_id"; target="$task_hours"; act="$task_act"; comment="$task_comment"
        fi
        existing="${EXISTING[$dt]:-0}"
        remaining=$(calc "$target - $existing")
        if ! is_gt "$remaining" 0; then
            SKIP_DONE+=("$dt")
            echo "  ${C_DIM}$label  ya imputado (${existing}h)${C_RESET}"; continue
        fi

        PLAN_DATES+=("$dt"); PLAN_ISSUES+=("$issue"); PLAN_HOURS+=("$remaining")
        PLAN_ACTS+=("$act"); PLAN_COMMENTS+=("$comment"); PLAN_KINDS+=("$kind"); PLAN_TARGETS+=("$target")
        extra=""
        if is_gt "$existing" 0; then extra=" ${C_DIM}(ya había ${existing}h)${C_RESET}"; fi
        if [[ "$kind" == "vacaciones" ]]; then
            echo "  ${C_BLUE}$label  ${remaining}h → #$issue (vacaciones)${C_RESET}$extra"
        else
            echo "  ${C_GREEN}$label  ${remaining}h → #$issue${C_RESET}$extra"
        fi
    done

    if (( ${#PLAN_DATES[@]} == 0 )); then ok "No hay nada que imputar"; return 0; fi

    echo
    info "Se van a imputar ${C_BOLD}$(calc "$(IFS=+; echo "${PLAN_HOURS[*]}")")h${C_RESET} en ${#PLAN_DATES[@]} $( (( ${#PLAN_DATES[@]} == 1 )) && echo día || echo días)"
    if (( dry )); then warn "Simulación terminada: no se ha imputado nada"; return 0; fi
    if (( QUICK_CONFIRM )); then
        local ans; read -r -p "¿Imputar? [S/n]: " ans || input_closed
        [[ "$ans" =~ ^[nN] ]] && { warn "Cancelado"; return 0; }
    elif ! confirm "¿Imputar?"; then
        warn "Cancelado"; return 0
    fi

    # Bloqueo + segunda lectura: entre el plan y la confirmación pueden haberse imputado horas
    # (otra ejecución, la web de Redmine…). Se recalcula lo pendiente de cada día con el bloqueo ya tomado.
    lock_writes || return 1
    info "Comprobando de nuevo lo ya imputado antes de escribir…"
    if ! existing_lines=$(fetch_entries "$FROM_DATE" "$TO_DATE"); then
        warn "No se pudieron releer las imputaciones: no se imputa nada"
        unlock_writes; return 1
    fi
    EXISTING=()
    while read -r dt _ h _; do
        [[ -z "$dt" ]] && continue
        EXISTING[$dt]=$(calc "${EXISTING[$dt]:-0} + $h")
    done <<<"$existing_lines"
    local -a keep=()
    for i in "${!PLAN_DATES[@]}"; do
        dt="${PLAN_DATES[$i]}"
        existing="${EXISTING[$dt]:-0}"
        remaining=$(calc "${PLAN_TARGETS[$i]} - $existing")
        if ! is_gt "$remaining" 0; then
            warn "$dt: mientras tanto se imputaron horas (ya hay ${existing}h); se salta"
            SKIP_DONE+=("$dt"); continue
        fi
        if [[ "$remaining" != "${PLAN_HOURS[$i]}" ]]; then
            warn "$dt: lo imputado cambió mientras tanto (ya hay ${existing}h); se imputan ${remaining}h en vez de ${PLAN_HOURS[$i]}h"
            PLAN_HOURS[i]="$remaining"
        fi
        keep+=("$i")
    done
    if (( ${#keep[@]} == 0 )); then
        ok "No queda nada que imputar"
        unlock_writes; return 0
    fi

    title "Imputando"
    total_plan=${#keep[@]}
    local n_done=0
    for i in "${keep[@]}"; do
        n_done=$((n_done + 1))
        idx=$(printf '[%2d/%2d]' "$n_done" "$total_plan")
        payload=$(jq -n \
            --argjson issue "${PLAN_ISSUES[$i]}" --arg date "${PLAN_DATES[$i]}" \
            --argjson hours "${PLAN_HOURS[$i]}" --arg comments "${PLAN_COMMENTS[$i]}" \
            --arg act "${PLAN_ACTS[$i]}" \
            '{time_entry: ({issue_id: $issue, spent_on: $date, hours: $hours, comments: $comments}
                + (if $act == "" then {} else {activity_id: ($act | tonumber)} end))}')
        code=$(api_send POST "/time_entries.json" "$payload") || true
        code=${code:-000}
        if [[ "$code" == "201" ]]; then
            ok "${C_DIM}$idx${C_RESET} ${PLAN_DATES[$i]}  ${PLAN_HOURS[$i]}h → #${PLAN_ISSUES[$i]}"
            if [[ "${PLAN_KINDS[$i]}" == "vacaciones" ]]; then
                ok_vac_days=$((ok_vac_days + 1)); ok_vac_hours=$(calc "$ok_vac_hours + ${PLAN_HOURS[$i]}")
            else
                ok_task_days=$((ok_task_days + 1)); ok_task_hours=$(calc "$ok_task_hours + ${PLAN_HOURS[$i]}")
            fi
        else
            err=$(api_errors)
            echo "${C_RED}✖ $idx ${PLAN_DATES[$i]}  HTTP $code ${err}${C_RESET}"
            FAILED+=("${PLAN_DATES[$i]} (HTTP $code${err:+: $err})")
        fi
    done
    unlock_writes

    title "Resumen $FROM_DATE → $TO_DATE"
    printf '  %-28s %3s días  %6sh\n' "Tarea #$task_id" "$ok_task_days" "$ok_task_hours"
    [[ -n "$vac_id" ]] && printf '  %-28s %3s días  %6sh\n' "Vacaciones #$vac_id" "$ok_vac_days" "$ok_vac_hours"
    printf '  %-28s %3s días\n' "Festivos (no imputados)" "${#SKIP_HOLIDAYS[@]}"
    for h in "${SKIP_HOLIDAYS[@]}"; do echo "     ${C_DIM}$h${C_RESET}"; done
    printf '  %-28s %3s días\n' "Ya imputados (saltados)" "${#SKIP_DONE[@]}"
    printf '  %-28s %3s días\n' "Fines de semana" "$weekends"
    if (( ${#FAILED[@]} )); then
        echo "  ${C_RED}Errores (${#FAILED[@]}):${C_RESET}"
        for f in "${FAILED[@]}"; do echo "     ${C_RED}$f${C_RESET}"; done
    fi
    echo
    print_totals_by_issue "$FROM_DATE" "$TO_DATE"
    (( ${#FAILED[@]} == 0 ))
}

cmd_imputar_hoy_rapido() { # imputa hoy directamente con los valores por defecto pidiendo solo confirmar el plan
    local prev_yes="$AUTO_YES"
    AUTO_YES=1; QUICK_CONFIRM=1
    cmd_imputar 0 hoy || true
    AUTO_YES="$prev_yes"; QUICK_CONFIRM=0
}

print_totals_by_issue() { # print_totals_by_issue desde hasta [imputaciones ya leídas]: total real por tarea
    local lines id hours
    info "Total imputado en Redmine entre $1 y $2, por tarea:"
    if (( $# >= 3 )); then
        lines="$3"
    elif ! lines=$(fetch_entries "$1" "$2"); then
        warn "No se pudo obtener desde Redmine"; return 1
    fi
    if [[ -z "$lines" ]]; then echo "     (nada)"; return 0; fi
    while read -r id hours; do
        if [[ "$id" == "-" ]]; then
            printf '     %6sh  (sin tarea)\n' "$hours"
        else
            printf '     %6sh  %s\n' "$hours" "$(issue_label "$id" 2>/dev/null || echo "#$id")"
        fi
    done < <(awk '{ s[$2] += $3 } END { for (k in s) printf "%s %g\n", k, s[k] }' <<<"$lines" | sort)
    printf '     %6sh  %sTOTAL%s\n' "$(awk '{ t += $3 } END { printf "%g", t }' <<<"$lines")" "$C_BOLD" "$C_RESET"
}

# ---------------------------------------------------------------- gestionar / borrar imputaciones
cmd_gestionar() { # lista las imputaciones del mes de trabajo y permite borrarlas o editarlas
    local dt issue h entry_id rest act comm i n sel_raw code err new_issue new_hours new_comm payload
    local -a entries=() sel_nums=()
    ensure_api || return 1

    while true; do
        ask_month "$WORK_MONTH" >/dev/null
        M_FROM="$MONTH-01"; M_TO=$(printf '%s-%02d' "$MONTH" "$LAST_DAY")
        clear_screen
        ui_box "Gestionar imputaciones — $(month_label "$MONTH")" "$M_FROM → $M_TO"
        echo
        if ! M_LINES=$(fetch_entries "$M_FROM" "$M_TO"); then
            warn "No se pudieron leer las imputaciones de Redmine"
            return 1
        fi
        entries=()
        if [[ -n "$M_LINES" ]]; then
            while read -r dt issue h entry_id rest; do
                [[ -z "$dt" ]] && continue
                entries+=("$dt|$issue|$h|$entry_id|$rest")
            done < <(sort <<<"$M_LINES")
        fi

        if (( ${#entries[@]} == 0 )); then
            info "No hay imputaciones registradas en $(month_label "$MONTH")."
        else
            printf '   %s%3s  %-14s %6s  %s%s\n' "$C_BOLD" "Nº" "Fecha" "Horas" "Tarea / Actividad / Comentario" "$C_RESET"
            ui_hr
            for i in "${!entries[@]}"; do
                IFS='|' read -r dt issue h entry_id act comm <<<"${entries[$i]}"
                local dow_str="${DOW_NAMES[$(( $(ddate -d "$dt" +%u) - 1 ))]}"
                local col="$C_RESET" tag="#$issue"
                if [[ -n "$VAC_ID" && "$issue" == "$VAC_ID" ]]; then
                    col="$C_BLUE"; tag="#$issue (vacaciones)"
                elif [[ "$issue" != "-" ]] && fetch_issue "$issue" 2>/dev/null; then
                    tag="#$issue ${ISSUE_SUBJECT[$issue]}"
                fi
                (( ${#tag} > 34 )) && tag="${tag:0:33}…"
                printf '   %s%3d%s  %s %s  %s%5sh%s  %s%s%s' \
                    "$C_BOLD" "$((i + 1))" "$C_RESET" "$dt" "$dow_str" \
                    "$col" "$h" "$C_RESET" "$col" "$tag" "$C_RESET"
                printf ' %s· %s%s\n' "$C_DIM" "$act${comm:+ · \"$comm\"}" "$C_RESET"
            done
            ui_hr
            printf '   %sTotal: %d imputaciones (%sh)%s\n' \
                "$C_DIM" "${#entries[@]}" "$(awk '{ t += $3 } END { printf "%g", t }' <<<"$M_LINES")" "$C_RESET"
        fi

        echo
        if (( ${#entries[@]} > 0 )); then
            menu_item b "Borrar imputaciones" "por número o rango (ej: 1 3,5 8-12)"
            menu_item e "Editar una imputación" "cambiar horas, tarea o comentario"
        fi
        echo "   ${C_DIM}←/a mes anterior · →/s mes siguiente · h mes actual · q/Intro volver${C_RESET}"
        [[ -t 0 ]] || return 0
        echo
        read_key "Opción:"
        case "$KEY" in
            b|B)
                (( ${#entries[@]} )) || continue
                sel_raw=$(ask "Números a borrar (ej: 1 3,5 8-10; vacío = cancelar)")
                [[ -z "$sel_raw" ]] && continue
                if ! mapfile -t sel_nums < <(parse_days "$sel_raw" "${#entries[@]}" 1); then
                    pause; continue
                fi
                (( ${#sel_nums[@]} )) || continue
                echo
                warn "Se van a BORRAR de Redmine (${#sel_nums[@]}):"
                for n in "${sel_nums[@]}"; do
                    IFS='|' read -r dt issue h entry_id act comm <<<"${entries[$((n - 1))]}"
                    echo "     #$n → $dt (${h}h en tarea #$issue${comm:+ · $comm}) [id:$entry_id]"
                done
                if confirm_no "¿Confirmas el borrado definitivo?"; then
                    lock_writes || { pause; continue; }
                    for n in "${sel_nums[@]}"; do
                        IFS='|' read -r dt issue h entry_id act comm <<<"${entries[$((n - 1))]}"
                        code=$(api_send DELETE "/time_entries/$entry_id.json") || true
                        code=${code:-000}
                        if [[ "$code" == "204" || "$code" == "200" ]]; then
                            ok "Borrada imputación de $dt (${h}h → #$issue)"
                        else
                            err=$(api_errors)
                            warn "Error al borrar $dt [id:$entry_id]: HTTP $code ${err}"
                        fi
                    done
                    unlock_writes
                    STATUS_CACHE=()
                    pause
                fi
                ;;
            e|E)
                (( ${#entries[@]} )) || continue
                n=$(ask "Número de imputación a editar (1-${#entries[@]}; vacío = cancelar)")
                [[ -z "$n" ]] && continue
                if ! [[ "$n" =~ ^[0-9]+$ ]] || (( n < 1 || n > ${#entries[@]} )); then
                    warn "Número no válido: $n"; pause; continue
                fi
                IFS='|' read -r dt issue h entry_id act comm <<<"${entries[$((n - 1))]}"
                echo "   Editando imputación del ${C_BOLD}$dt${C_RESET} [id:$entry_id]"
                if [[ "$issue" == "-" ]]; then   # imputación sin tarea (solo proyecto): vacío = dejarla así
                    new_issue=$(ask_issue "Tarea (vacío = seguir sin tarea)" "" 1)
                else
                    new_issue=$(ask_issue "Tarea" "$issue")
                fi
                new_hours=$(ask_hours "Horas" "$h")
                new_comm=$(ask "Comentario ('-' = vaciar)" "${comm:--}")
                [[ "$new_comm" == "-" ]] && new_comm=""
                payload=$(jq -n \
                    --arg issue "$new_issue" --argjson hours "$new_hours" --arg comments "$new_comm" \
                    '{time_entry: ({hours: $hours, comments: $comments}
                        + (if $issue == "" then {} else {issue_id: ($issue | tonumber)} end))}')
                lock_writes || { pause; continue; }
                code=$(api_send PUT "/time_entries/$entry_id.json" "$payload") || true
                unlock_writes
                code=${code:-000}
                if [[ "$code" == "204" || "$code" == "200" ]]; then
                    ok "Imputación actualizada ($dt: ${new_hours}h → ${new_issue:+#}${new_issue:-sin tarea})"
                    STATUS_CACHE=()
                else
                    err=$(api_errors)
                    warn "No se pudo actualizar: HTTP $code ${err}"
                fi
                pause
                ;;
            left|a|A)  month_shift -1 ;;
            right|s|S) month_shift +1 ;;
            h|H)       WORK_MONTH=$(date +%Y-%m) ;;
            *)         return 0 ;;
        esac
    done
}

# ---------------------------------------------------------------- resumen de un mes
analyze_month() { # analyze_month AAAA-MM -> rellena las variables M_* sin imprimir nada
    local -A per_day=() day_vac=() day_tasks=()
    local dt issue h entry_id rest comm tag day dd dow label hrs today diff
    ask_month "$1"
    M_FROM="$MONTH-01"; M_TO=$(printf '%s-%02d' "$MONTH" "$LAST_DAY")
    M_LINES=$(fetch_entries "$M_FROM" "$M_TO") || return 1
    M_HOLIDAYS_OK=1
    load_holidays "$YEAR" "$MON" || M_HOLIDAYS_OK=0
    while read -r dt issue h entry_id rest; do
        [[ -z "$dt" ]] && continue
        per_day[$dt]=$(calc "${per_day[$dt]:-0} + $h")
        comm="${rest#*|}"
        if [[ -n "$VAC_ID" && "$issue" == "$VAC_ID" ]]; then
            day_vac[$dt]=$(calc "${day_vac[$dt]:-0} + $h")
            tag="vacaciones (#$issue)"
        else
            tag="#$issue"
        fi
        [[ -n "$comm" ]] && tag+=" · $comm"
        if [[ -z "${day_tasks[$dt]:-}" ]]; then
            day_tasks[$dt]="$tag"
        elif [[ "${day_tasks[$dt]}" != *"$tag"* ]]; then
            day_tasks[$dt]+=", $tag"
        fi
    done <<<"$M_LINES"

    today=$(date +%F)
    M_CURRENT=0
    if [[ ! "$today" < "$M_FROM" && ! "$today" > "$M_TO" ]]; then M_CURRENT=1; fi
    M_FUTURE_MONTH=0
    if [[ "$today" < "$M_FROM" ]]; then M_FUTURE_MONTH=1; fi
    M_DAY_LINES=(); M_MISSING=(); M_EXTRA=(); M_FUTURE=0; M_MISSING_HOURS=0
    M_WORK_DAYS=0; M_WORK_DAYS_TD=0; M_HOL_WEEKDAY=0
    M_EXPECTED=0; M_EXPECTED_TD=0; M_IMPUTED=0; M_IMPUTED_TD=0; M_WEEKEND=0
    M_CAL_STATE=()

    for ((day = 1; day <= LAST_DAY; day++)); do
        dd=$(printf '%02d' "$day"); dt="$MONTH-$dd"
        dow=$(ddate -d "$dt" +%u)
        label="$dt ${DOW_NAMES[$((dow - 1))]}"
        hrs="${per_day[$dt]:-0}"
        M_IMPUTED=$(calc "$M_IMPUTED + $hrs")
        [[ "$dt" > "$today" ]] || M_IMPUTED_TD=$(calc "$M_IMPUTED_TD + $hrs")
        if (( dow >= 6 )); then
            if is_gt "$hrs" 0; then
                M_WEEKEND=$(calc "$M_WEEKEND + $hrs")
                M_CAL_STATE[$dd]="extra"
                M_DAY_LINES+=("  ${C_DIM}$label  $(pad "${hrs}h" 6) (fin de semana)${day_tasks[$dt]:+ · ${day_tasks[$dt]}}${C_RESET}")
            else
                M_CAL_STATE[$dd]="weekend"
            fi
            continue
        fi
        if [[ -n "${HOLIDAY[$dd]:-}" ]]; then
            M_HOL_WEEKDAY=$((M_HOL_WEEKDAY + 1))
            M_CAL_STATE[$dd]="hol"
            M_DAY_LINES+=("  ${C_YELLOW}$label  $(pad "${hrs}h" 6) festivo: ${HOLIDAY[$dd]}${C_RESET}")
            continue
        fi

        M_WORK_DAYS=$((M_WORK_DAYS + 1)); M_EXPECTED=$(calc "$M_EXPECTED + $HOURS")
        if [[ ! "$dt" > "$today" ]]; then
            M_WORK_DAYS_TD=$((M_WORK_DAYS_TD + 1)); M_EXPECTED_TD=$(calc "$M_EXPECTED_TD + $HOURS")
        fi
        diff=$(calc "$HOURS - $hrs")
        if is_gt "$diff" 0; then
            if [[ "$dt" > "$today" ]]; then
                M_FUTURE=$((M_FUTURE + 1))
                M_CAL_STATE[$dd]="future"
                M_DAY_LINES+=("  ${C_DIM}$label  $(pad "${hrs}h" 6) (pendiente, día futuro)${C_RESET}")
            else
                M_MISSING+=("$label  ${hrs}h → faltan ${diff}h")
                M_MISSING_HOURS=$(calc "$M_MISSING_HOURS + $diff")
                M_CAL_STATE[$dd]="missing"
                M_DAY_LINES+=("  ${C_RED}$label  $(pad "${hrs}h" 6) (faltan ${diff}h)${C_RESET}${day_tasks[$dt]:+ ${C_DIM}${day_tasks[$dt]}${C_RESET}}")
            fi
        elif is_gt 0 "$diff"; then
            M_EXTRA+=("$label  ${hrs}h → sobran $(calc "0 - $diff")h")
            M_CAL_STATE[$dd]="extra"
            M_DAY_LINES+=("  ${C_YELLOW}$label  $(pad "${hrs}h" 6) (sobran $(calc "0 - $diff")h)${C_RESET}${day_tasks[$dt]:+ ${C_DIM}${day_tasks[$dt]}${C_RESET}}")
        else
            if is_gt "${day_vac[$dt]:-0}" 0; then
                M_CAL_STATE[$dd]="vac"
                M_DAY_LINES+=("  ${C_BLUE}$label  $(pad "${hrs}h" 6) ${day_tasks[$dt]:-vacaciones}${C_RESET}")
            else
                M_CAL_STATE[$dd]="ok"
                M_DAY_LINES+=("  ${C_GREEN}$label  $(pad "${hrs}h" 6)${C_RESET}${day_tasks[$dt]:+ ${C_DIM}${day_tasks[$dt]}${C_RESET}}")
            fi
        fi
    done
    return 0
}

print_month_calendar() { # pinta la cuadrícula visual del mes analizado
    local day dd dow first_dow col=0 cell
    first_dow=$(ddate -d "$MONTH-01" +%u)
    echo "   ${C_BOLD} lu   ma   mi   ju   vi   ${C_DIM}sá   do${C_RESET}"
    printf '   '
    for ((col = 1; col < first_dow; col++)); do printf '     '; done
    for ((day = 1; day <= LAST_DAY; day++)); do
        dd=$(printf '%02d' "$day")
        dow=$(( (first_dow + day - 2) % 7 + 1 ))
        case "${M_CAL_STATE[$dd]:-future}" in
            ok)      cell="${C_GREEN} ${dd}✔${C_RESET} " ;;
            vac)     cell="${C_BLUE} ${dd}v${C_RESET} " ;;
            missing) cell="${C_RED} ${dd}✖${C_RESET} " ;;
            extra)   cell="${C_YELLOW} ${dd}+${C_RESET} " ;;
            hol)     cell="${C_YELLOW}[${dd}]${C_RESET} " ;;
            *)       cell="${C_DIM} ${dd} ${C_RESET} " ;;
        esac
        printf '%s' "$cell"
        if (( dow == 7 && day < LAST_DAY )); then printf '\n   '; fi
    done
    echo
    echo "   ${C_DIM}Leyenda:${C_RESET} ${C_GREEN}✔ completo${C_RESET} · ${C_BLUE}v vacaciones${C_RESET} · ${C_RED}✖ falta${C_RESET} · ${C_YELLOW}[n] festivo${C_RESET} · ${C_YELLOW}+ exceso${C_RESET} · ${C_DIM}finde/futuro${C_RESET}"
}

update_status() { # calcula la línea de estado del mes de trabajo para el menú (se cachea por mes)
    local m="$WORK_MONTH" s bar_col=""
    if [[ -z "$USER_NAME" ]]; then STATUS_CACHE[$m]="${C_DIM}sin conexión con Redmine${C_RESET}"; return 0; fi
    printf '%s' "${C_DIM}Consultando $(month_label "$m")…${C_RESET}"
    if ! analyze_month "$m" >/dev/null 2>&1; then
        printf '\r\e[K'
        STATUS_CACHE[$m]="${C_RED}no se pudo consultar Redmine${C_RESET}"
        return 0
    fi
    printf '\r\e[K'
    if (( M_FUTURE_MONTH )); then
        s="${C_DIM}mes futuro${C_RESET}"; bar_col="$C_DIM"
    elif (( ${#M_MISSING[@]} )); then
        s="${C_RED}✖ faltan ${M_MISSING_HOURS}h en ${#M_MISSING[@]} días${C_RESET}"; bar_col="$C_RED"
    elif (( M_CURRENT )); then
        s="${C_GREEN}✔ al día${C_RESET}"; bar_col="$C_GREEN"
    else
        s="${C_GREEN}✔ completo${C_RESET}"; bar_col="$C_GREEN"
    fi
    s+="  $(progress_bar "$M_IMPUTED" "$M_EXPECTED" 12 "$bar_col") ${C_DIM}(${M_IMPUTED}/${M_EXPECTED}h)${C_RESET}"
    if (( ${#M_EXTRA[@]} )); then s+="  ${C_YELLOW}· ${#M_EXTRA[@]} con exceso${C_RESET}"; fi
    STATUS_CACHE[$m]="$s"
}

cmd_resumen() {
    local h diff
    ensure_api || return 1
    if ! analyze_month "${1:-$WORK_MONTH}"; then warn "No se pudieron leer las imputaciones"; return 1; fi
    ui_box "Horas imputadas — $(month_label "$MONTH")" "${M_IMPUTED}h / ${M_EXPECTED}h"
    (( M_HOLIDAYS_OK )) || warn "No se pudieron consultar los festivos oficiales"
    echo
    print_month_calendar
    title "Detalle diario"
    printf '%s\n' "${M_DAY_LINES[@]}"
    echo
    print_totals_by_issue "$M_FROM" "$M_TO" "$M_LINES"

    title "Resumen  ${C_DIM}(${HOURS}h/día, festivos $(location_label))${C_RESET}"
    printf '  %s %5s\n' "$(pad "Días laborables del mes" 40)" "$M_WORK_DAYS"
    printf '  %s %5s\n' "$(pad "Festivos entre semana" 40)" "$M_HOL_WEEKDAY"
    printf '  %s %5sh\n' "$(pad "Horas a imputar (mes completo)" 40)" "$M_EXPECTED"
    printf '  %s %5sh   %s\n' "$(pad "Horas imputadas (mes completo)" 40)" "$M_IMPUTED" "$(progress_bar "$M_IMPUTED" "$M_EXPECTED" 14)"
    diff=$(calc "$M_EXPECTED - $M_IMPUTED")
    if is_gt "$diff" 0; then
        printf '  %s%s %5sh%s\n' "$C_RED" "$(pad "Faltan en el mes" 40)" "$diff" "$C_RESET"
    elif is_gt 0 "$diff"; then
        printf '  %s%s %5sh%s\n' "$C_YELLOW" "$(pad "Sobran en el mes" 40)" "$(calc "0 - $diff")" "$C_RESET"
    else
        printf '  %s%s %5s%s\n' "$C_GREEN" "$(pad "Mes completo" 40)" "✔" "$C_RESET"
    fi
    if (( M_CURRENT )); then
        echo
        printf '  %s %5s\n' "$(pad "Días laborables hasta hoy ($(date +%F))" 40)" "$M_WORK_DAYS_TD"
        printf '  %s %5sh\n' "$(pad "Horas a imputar hasta hoy" 40)" "$M_EXPECTED_TD"
        printf '  %s %5sh   %s\n' "$(pad "Horas imputadas hasta hoy" 40)" "$M_IMPUTED_TD" "$(progress_bar "$M_IMPUTED_TD" "$M_EXPECTED_TD" 14)"
        diff=$(calc "$M_EXPECTED_TD - $M_IMPUTED_TD")
        if is_gt "$diff" 0; then
            printf '  %s%s %5sh%s\n' "$C_RED" "$(pad "Faltan hasta hoy" 40)" "$diff" "$C_RESET"
        else
            printf '  %s%s %5s%s\n' "$C_GREEN" "$(pad "Al día" 40)" "✔" "$C_RESET"
        fi
    fi
    if is_gt "$M_WEEKEND" 0; then printf '  %s %5sh\n' "$(pad "Horas en fin de semana" 40)" "$M_WEEKEND"; fi

    echo
    if (( ${#M_MISSING[@]} )); then
        warn "Días con horas pendientes (${#M_MISSING[@]}):"
        for h in "${M_MISSING[@]}"; do echo "     ${C_RED}$h${C_RESET}"; done
    elif (( ! M_FUTURE_MONTH )); then
        ok "No falta ningún día hasta hoy"
    fi
    if (( M_FUTURE )); then
        info "Días futuros sin imputar: $M_FUTURE ($(calc "$M_FUTURE * $HOURS")h)"
    fi
    if (( ${#M_EXTRA[@]} )); then
        warn "Días con más de ${HOURS}h:"
        for h in "${M_EXTRA[@]}"; do echo "     ${C_YELLOW}$h${C_RESET}"; done
    fi
    return 0
}

# ---------------------------------------------------------------- festivos
cmd_festivos_year() { # cmd_festivos_year [AAAA] -> todos los festivos del año, agrupados por mes
    local year="${1:-${WORK_MONTH%-*}}" mon d dow rc=0 no_local=0 total=0 weekday=0
    ui_box "Festivos $year" "$(location_label)"
    for mon in 01 02 03 04 05 06 07 08 09 10 11 12; do
        load_holidays "$year" "$mon" || rc=1
        (( HOLIDAYS_NO_LOCAL )) && no_local=1
        (( ${#HOLIDAY[@]} )) || continue
        MONTH="$year-$mon"
        echo
        echo "  ${C_BOLD}$(month_label "$MONTH" | sed 's/ [0-9]*$//')${C_RESET}"
        print_holidays
        for d in "${!HOLIDAY[@]}"; do
            total=$((total + 1))
            dow=$(ddate -d "$MONTH-$d" +%u)
            (( dow < 6 )) && weekday=$((weekday + 1))
        done
    done
    echo
    if (( rc )); then
        warn "No hay festivos oficiales de $year en local y no se pudieron descargar: solo se muestran los propios"
    else
        info "$total festivos · ${C_BOLD}$weekday entre semana${C_RESET} (no se imputan) · $((total - weekday)) en sábado o domingo"
    fi
    (( no_local )) && warn "Aún no hay festivos locales de $year publicados para $CAL_LABEL; pulsa u más adelante para actualizar"
    cal_source_line "$year"
    return 0
}

browse_years() { browse_months cmd_festivos_year 12; } # festivos del año del mes de trabajo, de año en año

cmd_festivos() {
    local rc=0
    ask_month "${1:-}"
    load_holidays "$YEAR" "$MON" || rc=1
    ui_box "Festivos — $(month_label "$MONTH")" "$(location_label)"
    echo
    (( rc )) && warn "No hay festivos oficiales de $YEAR en local y no se pudieron descargar: solo se muestran los propios"
    [[ -z "$CAL_MUN" ]] && warn "No hay localidad configurada: solo festivos nacionales (Configuración → Localidad)"
    (( HOLIDAYS_NO_LOCAL )) && warn "Aún no hay festivos locales de $YEAR publicados para $CAL_LABEL; si los conoces, añádelos como propios"
    if (( ${#HOLIDAY[@]} )); then print_holidays; else info "No hay festivos este mes"; fi
    echo
    cal_source_line "$YEAR"
    return 0
}

# ---------------------------------------------------------------- configuración
edit_task() { ensure_api || return 1; TASK_ID=$(ask_issue "ID o URL de la tarea principal" "$TASK_ID"); save_config; refresh_labels; }
edit_vac()  { ensure_api || return 1; VAC_ID=$(ask_issue "ID o URL de la tarea de vacaciones" "$VAC_ID"); save_config; refresh_labels; }
edit_hours(){ HOURS=$(ask_hours "Horas por día laborable" "$HOURS"); save_config; }

edit_local_holidays() {
    local -a entries
    local i date name tipo n
    while true; do
        mapfile -t entries < <(local_holiday_entries)
        clear_screen
        ui_box "Festivos propios" "$HOLIDAYS_FILE"
        echo
        if (( ${#entries[@]} == 0 )); then echo "   (ninguno)"; fi
        for i in "${!entries[@]}"; do
            IFS='|' read -r date name tipo <<<"${entries[$i]}"
            printf '   %s%2d%s  %-10s  %s %s%s%s\n' "$C_BOLD" "$((i + 1))" "$C_RESET" "$date" \
                "$(pad "${name:-(sin descripción)}" 48)" "$C_DIM" "$tipo" "$C_RESET"
        done
        echo
        echo "   ${C_DIM}Se suman a los oficiales de $(location_label)."
        echo "   festivo   = añade un festivo, o cambia la descripción de uno oficial de ese día"
        echo "   laborable = anula un festivo oficial (ese día se trabaja)"
        echo "   Fecha AAAA-MM-DD = solo ese año · MM-DD = todos los años."
        echo "   Usa la fecha en que se disfruta (si cae en domingo y pasa al lunes, el lunes).${C_RESET}"
        echo
        menu_item a "Añadir festivo"
        menu_item b "Borrar festivo"
        menu_item e "Editar el JSON a mano" "$HOLIDAYS_FILE"
        menu_item q "Volver"
        echo
        read_key "Opción:"
        case "$KEY" in
            a|A)
                while true; do
                    date=$(ask "Fecha (AAAA-MM-DD o MM-DD; vacío = cancelar)")
                    [[ -z "$date" || "$date" =~ $HOLIDAY_DATE_RE ]] && break
                    warn "Fecha no válida: $date"
                done
                [[ -z "$date" ]] && continue
                name=$(ask "Descripción" "Festivo propio")
                tipo=$(ask "Tipo: f = festivo · l = laborable (anula un festivo oficial)" "f")
                if [[ "${tipo,,}" == l* ]]; then tipo="laborable"; else tipo="festivo"; fi
                name="${name//|/ }"
                set_local_holidays < <(printf '%s\n' "${entries[@]}" "$date|$name|$tipo")
                ;;
            b|B)
                (( ${#entries[@]} )) || continue
                n=$(ask "Número a borrar (vacío = cancelar)")
                if [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#entries[@]} )); then
                    unset "entries[$((n - 1))]"
                    set_local_holidays < <(printf '%s\n' "${entries[@]}")
                elif [[ -n "$n" ]]; then
                    warn "Número no válido: $n"; pause
                fi
                ;;
            e|E)
                [[ -f "$HOLIDAYS_FILE" ]] || echo "[]" > "$HOLIDAYS_FILE"
                "${EDITOR:-nano}" "$HOLIDAYS_FILE"
                jq -e 'type == "array"' "$HOLIDAYS_FILE" >/dev/null 2>&1 || { warn "El fichero no es un JSON válido (debe ser una lista)"; pause; }
                ;;
            *) return 0 ;;
        esac
    done
}

edit_activities() {
    ensure_api || return 1
    if [[ -z "$ACTIVITIES" ]]; then warn "Redmine no devuelve actividades; se usará la de por defecto"; return 0; fi
    TASK_ACTIVITY=$(choose_activity "la tarea" "$TASK_ACTIVITY")
    VAC_ACTIVITY=$(choose_activity "vacaciones" "${VAC_ACTIVITY:-$TASK_ACTIVITY}")
    save_config
}

edit_comments() {
    COMMENT=$(ask "Comentario por defecto de la tarea ('-' = ninguno)" "${COMMENT:--}"); [[ "$COMMENT" == "-" ]] && COMMENT=""
    VAC_COMMENT=$(ask "Comentario por defecto de vacaciones" "$VAC_COMMENT")
    save_config
}

edit_url() {
    local u
    u=$(ask "URL base de Redmine" "$REDMINE_URL")
    u="${u%/}"
    [[ -z "$u" ]] && return 0
    REDMINE_URL="$u"; USER_NAME=""
    save_config
    ensure_api || return 1
    refresh_labels
}

edit_api_key() {
    local k
    read -r -s -p "Nueva API key (vacío = borrar la guardada): " k; echo
    REDMINE_API_KEY="$k"; API_KEY="${ENV_API_KEY:-$k}"; USER_NAME=""
    save_config
    if [[ -n "$API_KEY" ]]; then ensure_api || return 1; fi
    refresh_labels
}

edit_file() {
    [[ -f "$CONFIG_FILE" ]] || save_config
    "${EDITOR:-nano}" "$CONFIG_FILE"
    load_config; USER_NAME=""
    ensure_api || true
    refresh_labels
}

setup_wizard() { # asistente obligatorio cuando no existe el .conf; solo escribe al final, si se confirma
    WIZARD=1
    clear_screen
    ui_box "Configuración inicial" "$SCRIPT_NAME"
    echo
    echo "   No existe $CONFIG_FILE, así que vamos a crearlo."
    echo "   No se guarda nada hasta el final. ${C_DIM}Ctrl+C para salir sin guardar.${C_RESET}"

    title "1/5 · Acceso a Redmine"
    echo "   ${C_DIM}La API key está en Redmine → Mi cuenta → «Clave de acceso a la API» → Mostrar.${C_RESET}"
    until ensure_api; do
        confirm "¿Probar otra vez?" || { WIZARD=0; return 1; }
    done
    if [[ -n "$ENV_API_KEY" ]]; then
        info "Se usa la API key de la variable REDMINE_API_KEY (no se guarda en el fichero)"
        REDMINE_API_KEY=""
    elif confirm "¿Guardar la API key en el fichero de configuración? (si no, se pedirá cada vez)"; then
        REDMINE_API_KEY="$API_KEY"
    else
        REDMINE_API_KEY=""
    fi

    title "2/5 · Tareas"
    TASK_ID=$(ask_issue "ID o URL de la tarea donde imputas el trabajo")
    TASK_ACTIVITY=$(choose_activity "la tarea")
    VAC_ID=$(ask_issue "ID o URL de la tarea de vacaciones")
    VAC_ACTIVITY=$(choose_activity "vacaciones" "$TASK_ACTIVITY")

    title "3/5 · Jornada"
    HOURS=$(ask_hours "Horas por día laborable" "$HOURS")

    title "4/5 · Comentarios por defecto"
    COMMENT=$(ask "Comentario de las imputaciones de la tarea (opcional)" "$COMMENT")
    VAC_COMMENT=$(ask "Comentario de las vacaciones" "$VAC_COMMENT")

    title "5/5 · Localidad para los festivos"
    until [[ -n "$CAL_MUN" ]]; do
        select_location || true
        if [[ -z "$CAL_MUN" ]]; then
            warn "Hace falta elegir una localidad para calcular los festivos"
            confirm "¿Elegirla ahora?" || { WIZARD=0; return 1; }
        fi
    done

    refresh_labels
    title "Resumen"
    printf '   %s %s\n' "$(pad "URL Redmine" 22)" "$REDMINE_URL"
    printf '   %s %s\n' "$(pad "Usuario" 22)" "$USER_NAME"
    printf '   %s %s\n' "$(pad "API key" 22)" "$( [[ -n "$REDMINE_API_KEY" ]] && echo 'se guarda' || echo 'no se guarda')"
    printf '   %s %s\n' "$(pad "Tarea" 22)" "$(issue_text "$TASK_ID" "$TASK_LABEL") · actividad: $(activity_name "$TASK_ACTIVITY")"
    printf '   %s %s\n' "$(pad "Vacaciones" 22)" "$(issue_text "$VAC_ID" "$VAC_LABEL") · actividad: $(activity_name "$VAC_ACTIVITY")"
    printf '   %s %s\n' "$(pad "Horas por día" 22)" "$HOURS"
    printf '   %s %s\n' "$(pad "Comentarios" 22)" "tarea: ${COMMENT:-(vacío)} · vacaciones: ${VAC_COMMENT:-(vacío)}"
    printf '   %s %s\n' "$(pad "Festivos de" 22)" "$CAL_LABEL"
    echo
    WIZARD=0
    confirm "¿Guardar esta configuración?" || return 1
    save_config
    cal_update
    echo
    ok "Listo. Puedes cambiar cualquier cosa luego en Configuración (tecla c)."
    pause
    return 0
}

cmd_config() {
    local api_state
    while true; do
        clear_screen
        if [[ -n "$ENV_API_KEY" ]]; then api_state="desde la variable REDMINE_API_KEY"
        elif [[ -n "$REDMINE_API_KEY" ]]; then api_state="guardada"
        else api_state="${C_YELLOW}no guardada${C_RESET}"; fi

        ui_box "Configuración" "$CONFIG_FILE"
        echo
        echo "  ${C_BOLD}Tareas${C_RESET}"
        menu_item 1 "Tarea principal" "$(issue_text "$TASK_ID" "$TASK_LABEL")"
        menu_item 2 "Tarea de vacaciones" "$(issue_text "$VAC_ID" "$VAC_LABEL")"
        menu_item 3 "Actividades" "tarea: $(activity_name "$TASK_ACTIVITY") · vacaciones: $(activity_name "$VAC_ACTIVITY")"
        menu_item 4 "Comentarios" "tarea: ${COMMENT:-(vacío)} · vacaciones: ${VAC_COMMENT:-(vacío)}"
        echo
        echo "  ${C_BOLD}Jornada y calendario${C_RESET}"
        menu_item 5 "Horas por día" "$HOURS"
        menu_item 6 "Localidad (festivos)" "$(location_label)"
        menu_item u "Actualizar festivos" "copia local de $(date +%Y): $(cal_local_date "$(date +%Y)" | grep . || echo 'sin descargar')"
        menu_item 7 "Festivos propios" "$(local_holiday_entries | grep -c . || true) en $(basename "$HOLIDAYS_FILE")"
        echo
        echo "  ${C_BOLD}Acceso${C_RESET}"
        menu_item 8 "API key" "$api_state"
        menu_item r "URL de Redmine" "${REDMINE_URL:-(sin definir)}"
        menu_item 9 "Editar el fichero a mano" "${EDITOR:-nano}"
        echo
        menu_item q "Volver"
        echo
        read_key "Opción:"
        case "$KEY" in
            1) edit_task || pause ;;
            2) edit_vac || pause ;;
            3) edit_activities || pause ;;
            4) edit_comments ;;
            5) edit_hours ;;
            6) select_location || true; pause ;;
            u|U) cal_update; pause ;;
            7) edit_local_holidays ;;
            8) edit_api_key || pause ;;
            r|R) edit_url || pause ;;
            9) edit_file ;;
            q|Q|0|esc|enter|left|eof) return 0 ;;
        esac
    done
}

# ---------------------------------------------------------------- ayuda
show_help() {
    cat <<EOF
${C_BOLD}$SCRIPT_NAME${C_RESET} — imputa horas en Redmine${REDMINE_URL:+ ($REDMINE_URL)}

${C_BOLD}USO${C_RESET}
  $SCRIPT_NAME                 Menú interactivo
  $SCRIPT_NAME -i, --imputar   Imputar horas (pregunta el periodo: mes, semana, día…)
  $SCRIPT_NAME -s, --semana    Imputar la semana actual
  $SCRIPT_NAME -d, --hoy       Imputar hoy
  $SCRIPT_NAME -y, --yes       Modo rápido sin preguntas (combinable con -d, -s, -i, -n)
  $SCRIPT_NAME -n, --simular   Simular la imputación (muestra el plan, no imputa)
  $SCRIPT_NAME -r, --resumen   Ver las horas imputadas (calendario visual y desglose)
  $SCRIPT_NAME -b, --borrar    Gestionar, editar o borrar imputaciones existentes
  $SCRIPT_NAME -f, --festivos  Ver los festivos del año (-f 2027 otro año; -f 2026-12 un solo mes)
  $SCRIPT_NAME -c, --config    Editar la configuración
  $SCRIPT_NAME -u, --actualizar-festivos  Descargar de nuevo los festivos y ver qué ha cambiado
  $SCRIPT_NAME -h, --help      Esta ayuda
  Todas trabajan sobre el mes actual; para otro mes añádelo detrás: $SCRIPT_NAME -r 2026-09

${C_BOLD}MENÚ PRINCIPAL${C_RESET}  (se elige pulsando una tecla, sin Intro)
  Arriba aparece el mes de trabajo, su barra de progreso y su estado:
    ✔ al día / ✔ completo   no falta nada hasta hoy
    ✖ faltan Xh en N días    hay días laborables pasados sin completar
  Teclas:
    i   Imputar horas (mes, semana o día)
    d   Imputar hoy rápido (con los valores configurados en un solo paso)
    v   Ver horas imputadas (calendario mensual, día a día, total por tarea y resumen)
    b   Borrar o editar imputaciones del mes
    f   Ver festivos de todo el año (←/→ cambia de año, u actualiza desde la API)
    c   Configuración
    ?   Ayuda
    q   Salir
    ←/→ Mes anterior / siguiente  (también a / s)
    h   Volver al mes actual
    m   Ir a un mes concreto (AAAA-MM)
    r   Recargar los datos de Redmine
    n   Simular imputación (oculta; igual que i pero sin imputar)
  Al arrancar, el mes de trabajo es siempre el mes actual.

${C_BOLD}IMPUTAR HORAS${C_RESET}
  Primero eliges el periodo:
    m  Mes completo (el mes de trabajo)     s  Esta semana      p  Semana pasada
    d  Hoy      o  Otro día (15, 15/10, 2026-10-15, ayer…)      r  Rango de días del mes
  Las semanas pueden cruzar de mes sin problema. Después confirma la tarea configurada (o escribe
  '?' para elegir entre tus tareas abiertas asignadas en Redmine), las horas por día y los días
  de vacaciones (se imputan en la tarea de vacaciones). Después muestra los festivos del mes
  para quitar o añadir alguno, enseña el plan día a día y solo imputa si lo confirmas.
  Con -y / --yes usa directamente los valores configurados sin preguntas interactivas.
  Reglas:
    · Los sábados y domingos no se imputan.
    · Los festivos (nacionales, autonómicos y locales) no se imputan.
    · Si un día ya tiene horas, solo imputa lo que falta hasta las horas del día;
      si ya está completo, lo salta. Así puedes relanzarlo sin duplicar horas.
    · Si un día es festivo y también vacaciones, gana el festivo.

${C_BOLD}VER Y GESTIONAR HORAS IMPUTADAS${C_RESET}
  La vista de resumen (-r / tecla v) muestra una cuadrícula de calendario mensual coloreada,
  el desglose día a día distinguiendo vacaciones y tareas, el total por tarea y el resumen
  con barra de progreso del mes completo y hasta hoy. Con ←/→ pasas de mes sin salir.
  En «Borrar / editar imputaciones» (-b / tecla b) puedes eliminar o modificar imputaciones
  directamente vía API sin tener que entrar en la web de Redmine.

${C_BOLD}CONFIGURACIÓN${C_RESET}
  Fichero: $CONFIG_FILE  (permisos 600; formato CLAVE=valor, editable a mano)
    REDMINE_URL      URL base de Redmine (p. ej. https://redmine.ejemplo.com)
    TASK_ID          Tarea donde imputar (p. ej. 12345)
    VAC_ID           Tarea de vacaciones
    HOURS            Horas por día laborable (por defecto 8; admite decimales: 7.5)
    CAL_CCAA / CAL_PROV / CAL_MUN  Localidad para los festivos (se elige en Configuración → Localidad)
    TASK_ACTIVITY / VAC_ACTIVITY   Id de actividad de Redmine (vacío = la de por defecto)
    COMMENT / VAC_COMMENT          Comentarios por defecto
    REDMINE_API_KEY  Tu clave de la API
  Si no existe el fichero, al arrancar (con cualquier opción salvo --help) se lanza un
  asistente obligatorio: URL y API key, tareas y actividades, horas, comentarios y localidad
  de festivos. No escribe nada hasta el final y solo si lo confirmas.
  Si cambias algo durante una imputación, el script ofrece guardarlo como predeterminado.

  Festivos propios: $HOLIDAYS_FILE
    Se suman a los oficiales. Lista JSON:
      [
        { "fecha": "2026-01-02", "descripcion": "Toma de Granada", "tipo": "festivo" },
        { "fecha": "2026-12-24", "descripcion": "Nochebuena (empresa)", "tipo": "festivo" },
        { "fecha": "2026-05-01", "descripcion": "Se trabaja", "tipo": "laborable" }
      ]
    · festivo: añade un festivo; si ese día ya hay uno oficial, cambia su descripción.
    · laborable: anula un festivo oficial (ese día se imputa).
    · AAAA-MM-DD vale solo ese año; MM-DD se repite todos los años.
    Se gestionan en Configuración → Festivos propios (o editando el JSON a mano).

${C_BOLD}API KEY${C_RESET}
  Redmine → Mi cuenta → "Clave de acceso a la API" → Mostrar.
  También se puede pasar con la variable de entorno REDMINE_API_KEY (tiene prioridad).
  Hace falta tener acceso de red o VPN si la instancia de Redmine lo requiere.

${C_BOLD}FESTIVOS${C_RESET}
  Los oficiales salen de calendariosnacionales.com (https://calendariosnacionales.com):
  nacionales, de la comunidad y locales de tu localidad, con los traslados de domingo a
  lunes ya aplicados. La localidad se elige en Configuración → Localidad con un
  selector Comunidad > Provincia > Localidad y queda guardada.
  Los festivos se guardan en local, en $CAL_DIR (un fichero por año y localidad),
  y el script lee SIEMPRE de ahí: no depende de la API en el día a día. Solo descarga un
  año la primera vez que lo necesita.
  Para traer cambios (p. ej. cuando se publiquen los locales del año que viene):
    · tecla u en «Ver festivos», Configuración → u, o $SCRIPT_NAME -u
  Al actualizar enseña lo que ha cambiado (+ nuevo, - quitado, ~ cambiado). Si no hay red,
  se mantiene la copia local.
  Los festivos locales de un año a veces se publican tarde: si faltan, el script avisa y
  puedes añadirlos como festivos propios.

${C_BOLD}FORMATO DE DÍAS${C_RESET}
  Días del mes separados por espacios o comas, con rangos: 3 5,7 10-14

${C_BOLD}VARIABLES DE ENTORNO${C_RESET}
  REDMINE_API_KEY   API key (prioridad sobre el fichero)
  REDMINE_URL       URL base de Redmine (prioridad sobre el fichero)
  REDMINE_CONFIG    Ruta alternativa del fichero de configuración
  REDMINE_HOLIDAYS  Ruta alternativa del JSON de festivos
EOF
}

# ---------------------------------------------------------------- menús
read_key() { # read_key "texto" -> KEY: la tecla pulsada, o enter/left/right/up/down/esc
    local k rest=""
    if ! read -r -s -n1 -p "$1 " k; then echo; KEY="eof"; return 0; fi
    if [[ "$k" == $'\e' ]]; then
        read -r -s -n2 -t 0.1 rest || true
        case "$rest" in
            "[D") k="left" ;; "[C") k="right" ;; "[A") k="up" ;; "[B") k="down" ;;
            "")   k="esc" ;; *) k="other" ;;
        esac
    elif [[ -z "$k" ]]; then
        k="enter"
    fi
    echo
    KEY="$k"
}

clear_screen() { if [[ -t 1 ]]; then printf '\e[H\e[2J\e[3J'; fi; }

menu_item() { # menu_item tecla "texto" ["valor"]
    if [[ -n "${3:-}" ]]; then
        printf '   %s%s%s  %s %s%s%s\n' "$C_BOLD" "$1" "$C_RESET" "$(pad "$2" 28)" "$C_DIM" "$3" "$C_RESET"
    else
        printf '   %s%s%s  %s\n' "$C_BOLD" "$1" "$C_RESET" "$2"
    fi
}

month_label() { # 2026-10 -> octubre 2026
    local names=(enero febrero marzo abril mayo junio julio agosto septiembre octubre noviembre diciembre)
    echo "${names[$((10#${1#*-} - 1))]} ${1%-*}"
}

month_shift() { WORK_MONTH=$(ddate -d "$WORK_MONTH-01 $1 month" +%Y-%m); }

issue_text() { # issue_text id título -> "#id título" o "(sin definir)"
    if [[ -z "$1" ]]; then echo "(sin definir)"; else echo "#$1${2:+ $2}"; fi
}

refresh_labels() { # títulos de las tareas configuradas, para los menús (usa la caché ISSUE_SUBJECT)
    TASK_LABEL=""; VAC_LABEL=""
    [[ -z "$USER_NAME" ]] && return 0
    if [[ -n "$TASK_ID" ]] && fetch_issue "$TASK_ID"; then TASK_LABEL="${ISSUE_SUBJECT[$TASK_ID]}"; fi
    if [[ -n "$VAC_ID" ]]  && fetch_issue "$VAC_ID";  then VAC_LABEL="${ISSUE_SUBJECT[$VAC_ID]}"; fi
    return 0
}

browse_months() { # browse_months comando [paso]: muestra el mes de trabajo (paso 12: su año) y permite moverse
    local cmd="$1" step="${2:-1}" unit="mes" arg extra="b borrar/editar"
    (( step == 12 )) && unit="año"
    [[ "$cmd" == cmd_festivos* ]] && extra="u actualizar desde la API"
    while true; do
        clear_screen
        if (( step == 12 )); then arg="${WORK_MONTH%-*}"; else arg="$WORK_MONTH"; fi
        "$cmd" "$arg" || true
        [[ -t 0 ]] || return 0
        echo
        read_key "${C_DIM}←/a $unit anterior · →/s $unit siguiente · h $unit actual · $extra · Intro volver${C_RESET}"
        case "$KEY" in
            u|U) if [[ "$cmd" == cmd_festivos* ]]; then cal_update "${WORK_MONTH%-*}"; pause; else return 0; fi ;;
            b|B) if [[ "$cmd" == "cmd_resumen" ]]; then cmd_gestionar || true; else return 0; fi ;;
            left|a|A)  month_shift "-$step" ;;
            right|s|S) month_shift "+$step" ;;
            h|H)       WORK_MONTH=$(date +%Y-%m) ;;
            *)         return 0 ;;
        esac
    done
}

main_menu() {
    local status
    ensure_api || warn "Sin conexión con Redmine: solo podrás ver festivos y configuración"
    refresh_labels

    while true; do
        [[ -n "${STATUS_CACHE[$WORK_MONTH]:-}" ]] || update_status
        status="${STATUS_CACHE[$WORK_MONTH]}"
        clear_screen
        ui_box "Imputación Redmine" "${USER_NAME:-sin conexión}${REDMINE_URL:+ · ${REDMINE_URL#https://}}"
        echo
        echo "   ${C_CYAN}◀${C_RESET}  ${C_BOLD}$(pad "$(month_label "$WORK_MONTH")" 16)${C_RESET} ${C_CYAN}▶${C_RESET}   $status"
        ui_hr
        echo "   ${C_DIM}Tarea       $(issue_text "$TASK_ID" "$TASK_LABEL")${C_RESET}"
        echo "   ${C_DIM}Vacaciones  $(issue_text "$VAC_ID" "$VAC_LABEL")${C_RESET}"
        echo "   ${C_DIM}Jornada     ${HOURS}h/día · festivos $(location_label)${C_RESET}"
        ui_hr
        echo
        menu_item i "Imputar horas" "mes, semana, día o rango"
        menu_item d "Imputar hoy rápido" "$(short_date "$(date +%F)") · ${HOURS}h → #${TASK_ID:-?}"
        menu_item v "Ver horas imputadas" "calendario mensual y resumen"
        menu_item b "Borrar / editar imputaciones" "gestionar entradas del mes"
        menu_item f "Ver festivos" "todo el año"
        menu_item c "Configuración"
        menu_item '?' "Ayuda"
        menu_item q "Salir"
        echo
        echo "   ${C_DIM}←/→ cambiar de mes · h mes actual · m ir a un mes · r recargar · n simular${C_RESET}"
        echo
        read_key "Opción:"
        case "$KEY" in
            i|I|1)    cmd_imputar 0 || true; STATUS_CACHE=(); pause ;;
            d|D)      cmd_imputar_hoy_rapido; STATUS_CACHE=(); pause ;;
            n|N)      cmd_imputar 1 || true; pause ;;
            v|V|2)    browse_months cmd_resumen ;;
            b|B)      cmd_gestionar || true ;;
            f|F|3)    browse_years ;;
            c|C|4)    cmd_config; STATUS_CACHE=() ;;
            '?'|5)    show_help | less -R -F -X ;;
            left|a|A) month_shift -1 ;;
            right|s|S) month_shift +1 ;;
            h|H)      WORK_MONTH=$(date +%Y-%m) ;;
            m|M)      change_month ;;
            r|R)      STATUS_CACHE=(); ISSUE_SUBJECT=(); ISSUE_PROJECT=(); ensure_api || true; refresh_labels ;;
            q|Q|0|esc|eof) exit 0 ;;
        esac
    done
}

# ---------------------------------------------------------------- arranque
command -v curl >/dev/null || die "Falta curl"
command -v jq   >/dev/null || die "Falta jq (sudo apt install jq)"
command -v flock >/dev/null || die "Falta flock (paquete util-linux)"
date -d "2000-01-01 +1 day" >/dev/null 2>&1 || die "Se necesita GNU date"

load_config

# Extraer flag -y/--yes en cualquier posición conservando el resto de argumentos
ARGS=()
for arg in "$@"; do
    case "$arg" in
        -y|--yes) AUTO_YES=1 ;;
        *)        ARGS+=("$arg") ;;
    esac
done
set -- "${ARGS[@]}"

if [[ ! -f "$CONFIG_FILE" && "${1:-}" != "-h" && "${1:-}" != "--help" ]]; then
    [[ -t 0 ]] || die "No existe $CONFIG_FILE. Ejecuta el script en una terminal para crear la configuración."
    setup_wizard || die "Configuración cancelada: no se ha guardado nada."
fi

if [[ -n "${1:-}" ]] && valid_month "$1"; then
    WORK_MONTH="$1"
    shift
elif [[ -n "${2:-}" ]]; then
    if [[ "$2" =~ ^[0-9]{4}$ ]]; then
        WORK_MONTH="$2-$(date +%m)"
    else
        valid_month "$2" || die "Mes no válido: $2 (formato AAAA-MM, o AAAA para los festivos)"
        WORK_MONTH="$2"
    fi
fi

# Sin terminal (cron, tuberías…) solo se escribe en Redmine con -y: sin él, las preguntas no tendrían respuesta
# y antes se tomaba el «sí» por defecto saltándose las salvaguardas de -y. Gestionar (-b) siempre es interactivo.
case "${1:-}" in
    -i|--imputar|-s|--semana|-d|--hoy)
        [[ -t 0 ]] || (( AUTO_YES )) || die "Sin terminal no se imputa sin -y (p. ej. $SCRIPT_NAME ${1} -y); no se ha escrito nada." ;;
    -b|--borrar|--gestionar)
        [[ -t 0 ]] || die "Gestionar imputaciones (-b) necesita una terminal; no se ha escrito nada." ;;
esac

case "${1:-}" in
    "")               main_menu ;;
    -h|--help)        show_help ;;
    -i|--imputar)     cmd_imputar 0 ;;
    -s|--semana)      cmd_imputar 0 semana ;;
    -d|--hoy)         cmd_imputar 0 hoy ;;
    -n|--simular|--dry-run) cmd_imputar 1 ;;
    -r|--resumen)     browse_months cmd_resumen ;;
    -b|--borrar|--gestionar) cmd_gestionar ;;
    -f|--festivos)    if [[ "${2:-}" =~ ^[0-9]{4}-[0-9]{2}$ ]]; then browse_months cmd_festivos; else browse_years; fi ;;
    -u|--actualizar-festivos) cal_update ;;
    -c|--config)      cmd_config ;;
    *)                die "Opción desconocida: $1 (usa --help)" ;;
esac
