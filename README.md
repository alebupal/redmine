# imputar-redmine.sh

Script interactivo de Bash para imputar y gestionar horas en Redmine mediante su API REST.
Tiene en cuenta fines de semana, festivos oficiales de tu localidad (nacionales, autonómicos y locales), festivos propios y vacaciones, y permite revisar de un vistazo si falta algún día por imputar.

Este documento incluye tanto la **guía de instalación y uso** como la **documentación técnica** para entender y mantener el script.

---

## Índice

1. [Qué hace](#qué-hace)
2. [Requisitos](#requisitos)
3. [Instalación y uso rápido](#instalación-y-uso-rápido)
4. [Ficheros](#ficheros)
5. [Estructura del script](#estructura-del-script)
6. [Flujos principales](#flujos-principales)
7. [APIs externas](#apis-externas)
8. [Formatos de datos](#formatos-de-datos)
9. [Estado global y convenciones](#estado-global-y-convenciones)
10. [Trampas conocidas](#trampas-conocidas-leer-antes-de-tocar)
11. [Cómo extenderlo](#cómo-extenderlo)
12. [Cómo probar sin riesgo](#cómo-probar-sin-riesgo)
13. [Seguridad](#seguridad)
14. [Limitaciones conocidas](#limitaciones-conocidas)

---

## Qué hace

- **Imputar horas** de un mes, una semana (puede cruzar de mes), un día o un rango:
  - Salta fines de semana y festivos.
  - Imputa los días de vacaciones en una tarea aparte.
  - Si un día ya tiene horas, imputa solo las que faltan. Se puede relanzar sin duplicar.
  - Selector interactivo de tareas abiertas asignadas en Redmine (escribiendo `?` o `l`).
  - Modo rápido sin preguntas (`-y` / `--yes` o tecla `d` para imputar hoy en un paso). Con `-y` nunca imputa días futuros y aborta si los festivos no son fiables (no se pudieron cargar o faltan los locales).
  - Antes de enviar nada muestra el plan y pide confirmación, e informa del progreso `[i/N]`.
- **Ver horas imputadas** de un mes: cuadrícula de calendario mensual coloreada, detalle día a día distinguiendo tareas y vacaciones, total por tarea y resumen con barra de progreso del mes completo y hasta hoy.
- **Borrar y editar imputaciones** existentes del mes directamente vía API (`DELETE` / `PUT`) sin entrar en la web de Redmine.
- **Ver festivos** de todo el año (o de un mes) de la localidad configurada.
- **Festivos**:
  - Los oficiales vienen de [calendariosnacionales.com](https://calendariosnacionales.com) y se guardan en local.
  - La API solo se consulta para la primera descarga de un año o cuando se pide actualizar.
  - Los propios (`festivos.json`) se suman a los oficiales o los anulan.
- **Menú interactivo** de una tecla con cabeceras visuales y barra de progreso, más accesos directos por línea de comandos.

## Requisitos

| Herramienta | Uso |
|---|---|
| `bash` ≥ 4.4 | Arrays asociativos, `mapfile`, `${var,,}`. Probado con 5.2. |
| GNU `date` | Aritmética de fechas (`date -d "… +1 month"`, `date -r fichero`). En macOS no funciona sin `gdate`. |
| `curl` | Llamadas HTTP. |
| `jq` | Todo el JSON. |
| `awk`, `sed`, `sort`, `paste`, `iconv`, `find` | Utilidades estándar. `iconv` quita tildes en el buscador de localidades. |

El script comprueba `curl`, `jq` y GNU `date` al arrancar.

Se necesita acceso a la red o a la VPN si la instancia de Redmine lo exige. Para los festivos solo hace falta internet en la primera descarga o al actualizar.

## Instalación y uso rápido

```bash
git clone https://github.com/alebupal/redmine.git
cd redmine
chmod +x imputar-redmine.sh
./imputar-redmine.sh                     # en el primer arranque lanza el asistente de configuración
```

Opciones de línea de comandos:

```bash
./imputar-redmine.sh                     # menú interactivo
./imputar-redmine.sh -i                  # imputar (pregunta el periodo)
./imputar-redmine.sh -s                  # imputar esta semana
./imputar-redmine.sh -d                  # imputar hoy
./imputar-redmine.sh -d -y               # imputar hoy directamente sin preguntas
./imputar-redmine.sh -n [AAAA-MM]        # simular (no imputa nada)
./imputar-redmine.sh -r [AAAA-MM]        # horas imputadas de un mes (calendario + resumen)
./imputar-redmine.sh -b [AAAA-MM]        # borrar o editar imputaciones de un mes
./imputar-redmine.sh -f [AAAA|AAAA-MM]   # festivos del año (o de un mes)
./imputar-redmine.sh -u                  # actualizar festivos desde la API y ver cambios
./imputar-redmine.sh -c                  # configuración
./imputar-redmine.sh -h                  # ayuda
```

El segundo argumento fija el **mes de trabajo** (`WORK_MONTH`). Si no se indica, es el mes actual.

### Primer arranque (sin `.conf`)

Si no existe el fichero de configuración, el bloque de **arranque** lanza `setup_wizard` antes que cualquier otra cosa. Da igual la opción usada; la única excepción es `-h`/`--help`.

- **Es obligatorio.** Si se cancela (o se dice «no» en el resumen), el script termina con `die` y **no crea nada**.
- **Necesita una terminal.** Sin ella (por ejemplo, con stdin redirigido), termina con un error en vez de quedarse esperando respuestas.
- **Cinco pasos:**
  1. URL base de Redmine y API key, validadas contra `/users/current.json`. Se pregunta si guardar la API key (si viene de `REDMINE_API_KEY`, no se guarda).
  2. Tarea principal y tarea de vacaciones, cada una con su actividad.
  3. Horas por día.
  4. Comentarios por defecto.
  5. Localidad para los festivos, con el selector. **No hay localidad por defecto**: `CAL_*` empieza vacío y hay que elegirla.
- **No guarda nada hasta el final.** Mientras corre, `WIZARD=1` impide que `ensure_api` y `select_location` guarden por su cuenta. Al final muestra un resumen, y solo si se confirma llama a `save_config` y descarga los festivos (`cal_update`).
- **Para probarlo** sin tocar la configuración real, usa `REDMINE_CONFIG=/tmp/nuevo.conf` apuntando a un fichero que no exista.

Menú principal: `i` imputar · `d` imputar hoy rápido · `v` horas imputadas · `b` borrar/editar imputaciones · `f` festivos · `c` configuración · `?` ayuda · `q` salir · `←/→` cambiar de mes · `h` mes actual · `m` ir a un mes · `r` recargar · `n` simular.

## Ficheros

Todo vive junto al script, en el directorio que resuelve `SCRIPT_DIR` (se siguen los enlaces simbólicos con `readlink -f`):

```
redmine/
├── imputar-redmine.sh           # el script
├── imputar-redmine.conf         # configuración del usuario (CLAVE=valor). Contiene la API key → permisos 600
├── imputar-redmine.conf.example # plantilla de configuración sin datos sensibles
├── .gitignore                   # ignora imputar-redmine.conf, festivos.json, calendario/ y .cache/
├── festivos.json                # festivos propios (se suman a los oficiales o los anulan). Puede ser []
├── calendario/                  # copia local de festivos oficiales, 1 fichero por año y localidad
│   └── 2026-and-granada-granada.json
├── .cache/                      # listados de comunidades/provincias/localidades (caché de 7 días)
└── README.md
```

Rutas que se pueden cambiar con variables de entorno:

| Variable | Por defecto | Para qué |
|---|---|---|
| `REDMINE_API_KEY` | (vacío) | API key. Si está definida, **tiene prioridad** sobre la del `.conf`. |
| `REDMINE_URL` | (vacío) | URL base de Redmine. Si está definida, **tiene prioridad** sobre la del `.conf`. |
| `REDMINE_CONFIG` | `$SCRIPT_DIR/imputar-redmine.conf` | Fichero de configuración. **Úsala en las pruebas** para no tocar el real. |
| `REDMINE_HOLIDAYS` | `$SCRIPT_DIR/festivos.json` | Festivos propios. |

`calendario/` y `.cache/` se pueden borrar sin problema: se regeneran solos.

---

## Estructura del script

El script es un único fichero dividido en secciones con cabeceras `# ------…------ nombre`. En orden:

| Sección | Qué contiene | Funciones clave |
|---|---|---|
| *(cabecera)* | `set -euo pipefail`, locale, rutas, colores | — |
| **configuración (valores por defecto)** | `CONFIG_KEYS`, valores por defecto y **todo el estado global** | — |
| **utilidades e interfaz visual** | Mensajes, cajas Unicode, barras de progreso, preguntas, cálculo decimal, carga y guardado del `.conf` | `ui_box`, `ui_hr`, `progress_bar`, `ask`, `confirm`, `confirm_no`, `pad`, `calc`, `is_gt`, `valid_hours`, `load_config`, `save_config` |
| **API Redmine** | HTTP con API key (`GET`, `POST`, `PUT`, `DELETE`), caché de tareas, selector de tareas asignadas, actividades, lectura de imputaciones | `api_curl`, `api_get`, `api_send`, `api_errors`, `ensure_api`, `fetch_issue`, `select_assigned_issue`, `pick_issue`, `resolve_activity`, `fetch_entries` |
| **días y festivos** | Lectura y validación de días, horas, mes y rango | `parse_days`, `ask_days`, `ask_hours`, `ask_month`, `ask_range`, `change_month` |
| **calendario laboral** | calendariosnacionales.com, copia local, selector de localidad, festivos propios, carga de festivos de un mes | `cal_download`, `cal_holidays_json`, `cal_holiday_lines`, `cal_update`, `select_location`, `pick_option`, `load_holidays`, `add_holiday` |
| **imputar** | Periodos (mes, semana, día…), festivos de un rango, plan, POST con progreso y resumen | `choose_period`, `parse_date`, `load_holidays_range`, `cmd_imputar`, `cmd_imputar_hoy_rapido`, `print_totals_by_issue` |
| **gestionar / borrar imputaciones** | Listado numerado de imputaciones del mes, borrado por lotes (`DELETE`) y edición (`PUT`) | `cmd_gestionar` |
| **resumen de un mes** | Cuadrícula de calendario mensual, cálculo de horas esperadas frente a imputadas y estado del menú | `analyze_month`, `print_month_calendar`, `update_status`, `cmd_resumen` |
| **festivos** | Vistas de festivos por año y por mes | `cmd_festivos_year`, `browse_years`, `cmd_festivos` |
| **configuración** | Editores de cada ajuste, asistente inicial, menú de configuración | `edit_*`, `setup_wizard`, `cmd_config` |
| **ayuda** | Texto de `--help` | `show_help` |
| **menús** | Lectura de teclas, elementos de menú, navegación por meses, menú principal | `read_key`, `menu_item`, `browse_months`, `main_menu` |
| **arranque** | Comprobación de dependencias, `load_config`, extracción de `-y`, segundo argumento y `case` de opciones | — |

Los comandos de primer nivel se llaman `cmd_*`. Son los que invocan el menú y el `case` final.

---

## Flujos principales

### Imputar (`cmd_imputar dry [periodo]`)

1. `ensure_api` solicita (si faltan) y valida `REDMINE_URL` y la API key con `GET /users/current.json`, y guarda `USER_NAME`, `USER_ID` y `ACTIVITIES`.
2. `choose_period` fija `FROM_DATE`, `TO_DATE`, `PERIOD` y `PERIOD_LABEL`. Valores de `PERIOD`: `mes`, `semana`, `semana-pasada`, `dia` (incluye «hoy») y `rango`. Después se calcula `RANGE_DATES` con todas las fechas del periodo.
3. **Tarea**: `pick_issue` confirma la tarea configurada o pide otra. Luego horas por día, actividad (`resolve_activity`) y comentario.
4. **Vacaciones**: los días se piden como *días del mes* (`3 5,7 10-14`) y `ask_range_days` los traduce a fechas del periodo. Como un periodo dura como mucho 31 días, el número de día no es ambiguo aunque el periodo cruce de mes. En modo `dia` solo se pregunta «¿Es día de vacaciones?».
5. Si algo difiere de la configuración, ofrece guardarlo como predeterminado. Las horas de un día suelto no se guardan.
6. **Festivos**: `load_holidays_range` carga cada mes del rango y rellena `RANGE_HOL[fecha]`. Después el usuario puede quitar o añadir festivos solo para esta imputación.
7. Lee lo ya imputado (`fetch_entries`) en `EXISTING[fecha]`.
8. **Plan** por fecha:
   - fin de semana → se salta;
   - festivo → se salta (si también era vacaciones, gana el festivo);
   - resto → `objetivo - ya imputado`; si sale ≤ 0, «ya imputado».
9. Si es simulación (`dry=1`), termina aquí. Si no, pide confirmación y hace `POST /time_entries.json` por cada día (respuesta esperada: HTTP **201**).
10. Muestra un resumen local y otro real leído de Redmine (`print_totals_by_issue`).

### Horas imputadas (`analyze_month` + `cmd_resumen`)

`analyze_month AAAA-MM` **no imprime nada**: rellena las variables `M_*` (ver [estado global](#estado-global-y-convenciones)). La usan dos sitios:

- `cmd_resumen`, que pinta el detalle día a día, el total por tarea y el resumen.
- `update_status`, que calcula la línea de estado del menú («✔ al día», «✖ faltan Xh en N días»…) y la guarda en `STATUS_CACHE[mes]`.

Cómo se calculan los totales:

- **Horas a imputar** = días laborables × `HOURS`. Laborable significa de lunes a viernes y no festivo. Las vacaciones **sí** son laborables.
- **Horas imputadas** = todo lo imputado en Redmine ese mes, en cualquier tarea (vacaciones incluidas).
- «Hasta hoy» solo se calcula si el mes es el actual (`M_CURRENT`). Los días futuros sin horas no cuentan como pendientes.

### Festivos (`load_holidays año mes`)

Rellena `HOLIDAY[DD]` (descripción) y `HOLIDAY_SRC[DD]` (ámbito: `nacional`, el nombre de la comunidad, el de la localidad o `propio`):

1. **Oficiales**: `cal_holidays_json` lee `calendario/<año>-<ccaa>-<prov>-<mun>.json`. Si no existe, lo descarga **una vez** con `cal_download`. Para pasar el JSON a líneas `fecha|nombre|ámbito` se usa `cal_holiday_lines` (ver formato de la API más abajo).
2. **Propios** (`festivos.json`), aplicados encima:
   - `tipo: laborable` → borra el festivo oficial de ese día.
   - `tipo: festivo` en un día que ya es festivo → solo cambia la descripción.
   - `tipo: festivo` en un día que no lo es → añade un festivo con ámbito `propio`.
3. `HOLIDAYS_NO_LOCAL=1` si la localidad no tiene festivos locales publicados ese año. Se usa para avisar.

**Actualizar** (`cal_update [años…]`, por defecto este año y el siguiente):

- Descarga a un temporal y lo compara con la copia local por fecha: `+` nuevo, `-` quitado, `~` cambiado.
- Si la descarga sale bien, sustituye la copia.
- Si falla (sin red) o la API devuelve 404 (año no publicado), **no toca** la copia local.

---

## APIs externas

### Redmine

Autenticación con la cabecera `X-Redmine-API-Key`. Endpoints usados:

| Método | Ruta | Para qué |
|---|---|---|
| GET | `/users/current.json` | Validar la key y obtener nombre e id |
| GET | `/issues/{id}.json` | Validar una tarea y obtener su título (se cachea en `ISSUE_SUBJECT` / `ISSUE_PROJECT`) |
| GET | `/issues.json?assigned_to_id=me&status_id=open…` | Listar tareas abiertas asignadas al usuario cuando escribe `?` o `l` |
| GET | `/enumerations/time_entry_activities.json` | Actividades (id y nombre) |
| GET | `/time_entries.json?…` | Imputaciones propias de un rango |
| POST | `/time_entries.json` | Crear una imputación: `{"time_entry":{"issue_id","spent_on","hours","comments","activity_id"?}}` |
| PUT | `/time_entries/{id}.json` | Editar una imputación existente (tarea, horas, comentario) |
| DELETE | `/time_entries/{id}.json` | Borrar una imputación existente |

> ⚠️ **Muy importante:** algunas instancias de Redmine **ignoran** los filtros simples `user_id=me`, `from=` y `to=`, devolviendo **todas** las imputaciones globales de la instancia y haciendo que el script pagine indefinidamente. Hay que usar la sintaxis de filtros de Redmine:
>
> ```
> f[]=spent_on&op[spent_on]=><&v[spent_on][]=DESDE&v[spent_on][]=HASTA&f[]=user_id&op[user_id]==&v[user_id][]=me
> ```
>
> Por los corchetes, `curl` necesita `-g` (sin interpretación de patrones). Ya lo hace `api_get`.
>
> `fetch_entries` tiene además estas protecciones:
> - Si una página no es JSON o no trae `time_entries` (lista) y `total_count` (número), aborta: tomarla como «nada imputado» duplicaría horas.
> - Si `total_count > 1000`, aborta.
> - Filtra por `user.id == USER_ID` y por `spent_on` dentro del rango pedido.
>
> No las quites.

### calendariosnacionales.com

API pública, sin clave ni límites declarados. Base: `https://calendariosnacionales.com/es/v1`. Sus condiciones piden **atribución con enlace visible**: el script la muestra al pie de la vista de festivos y en la ayuda. Mantenla si cambias esas pantallas.

| Ruta | Respuesta (campos usados) |
|---|---|
| `/{año}/comunidades.json` | `.communities[] {slug, name}` (p. ej. `and`, Andalucía) |
| `/{año}/regiones/{ccaa}/provincias.json` | `.provinces[] {slug, name}` |
| `/{año}/regiones/{ccaa}/provincias/{prov}/localidades.json` | `.municipalities[] {slug, name, ine}` |
| `/{año}/localidades/{ccaa}/{prov}/{mun}.json` | `.holidays` es un **objeto** (ver abajo), más `.region.name` y `.municipality.name` |
| `/{año}/nacionales.json` | `.holidays` es un **array** de `{date, name, scope}`. Se usa si no hay localidad configurada. |

Estructura de `.holidays` para una localidad:

```json
{
  "national": [ {"date": "2026-01-01", "name": "Año Nuevo", "scope": "nacional"} ],
  "regional": [ {"date": "2026-11-02", "name": "Día siguiente a Todos los Santos", "scope": "nacional"} ],
  "local":    [ {"date": "2026-01-02", "name": "Fiesta Local", "scope": "local"} ],
  "calendar": [ /* la unión final, ya con traslados de domingo a lunes */ ]
}
```

- El script usa **`calendar`** como lista de festivos y `national`/`regional`/`local` **solo para etiquetar el ámbito**.
- El campo `scope` no es fiable para el ámbito: hay festivos autonómicos marcados como `nacional`.
- La API llama «Fiesta Local» a los festivos locales. El script lo muestra como «Fiesta local».
- Los años que no existen devuelven **404**, y `cal_download` lo trata como código 2.
- Los festivos locales del año siguiente suelen publicarse tarde: llegan vacíos y se avisa.

---

## Formatos de datos

### `imputar-redmine.conf`

Formato `CLAVE=valor`, una línea por clave, sin comillas. Se **lee con `sed`, no con `source`**, para no ejecutar nada del fichero. Lo regenera `save_config`, que escribe todas las claves de `CONFIG_KEYS` con una cabecera de comentarios.

| Clave | Ejemplo | Notas |
|---|---|---|
| `REDMINE_URL` | `https://redmine.ejemplo.com` | URL base de Redmine. |
| `REDMINE_API_KEY` | — | Secreta. |
| `TASK_ID` | `12345` | Tarea principal. |
| `VAC_ID` | `10000` | Tarea de vacaciones. |
| `HOURS` | `8` | Admite decimales (`7.5` o `7,5`). Se valida al cargar (mayor que 0 y hasta 24): si no es válido, el script se detiene con un error. |
| `TASK_ACTIVITY` / `VAC_ACTIVITY` | `9` | Id de actividad. Vacío = la de por defecto de Redmine. |
| `COMMENT` / `VAC_COMMENT` | `Vacaciones` | Comentarios por defecto. |
| `CAL_CCAA` / `CAL_PROV` / `CAL_MUN` | `and` / `granada` / `granada` | *Slugs* de calendariosnacionales.com. Sin valor por defecto: se eligen en el asistente o en Configuración → Localidad. |
| `CAL_LABEL` | `Granada (Granada, Andalucía)` | Solo para mostrar. |

### `festivos.json`

```json
[
  { "fecha": "2026-12-24", "descripcion": "Nochebuena (empresa)", "tipo": "festivo" },
  { "fecha": "05-01",      "descripcion": "Se trabaja",           "tipo": "laborable" }
]
```

- `fecha`: `AAAA-MM-DD` vale solo ese año; `MM-DD` se repite todos los años. Validada con `HOLIDAY_DATE_RE`.
- `tipo`: `festivo` (por defecto) o `laborable`.
- Internamente circula como líneas `fecha|descripción|tipo`. Por eso al añadir se quitan los `|` de la descripción.
- `set_local_holidays` lo reescribe ordenado y sin fechas duplicadas (`unique_by(.fecha)`). Si se edita a mano y queda un JSON inválido, se ignora con un aviso.

### `calendario/` y `.cache/`

- `calendario/<año>-<ccaa>-<prov>-<mun>.json` (o `<año>-nacionales.json`): respuesta **tal cual** de la API. La fecha de modificación del fichero es la «fecha de descarga» que se muestra.
- `.cache/<ruta_con_guiones_bajos>`: listados para el selector de localidad, con caducidad `CAL_CACHE_DAYS` (7 días). Si no hay red, se usa aunque esté caducado.

---

## Estado global y convenciones

Bash no devuelve estructuras, así que muchas funciones **rellenan variables globales** en lugar de escribir en stdout. Todas están declaradas en la sección de configuración:

| Variables | Las rellena | Significado |
|---|---|---|
| `REDMINE_URL`, `API_KEY`, `USER_NAME`, `USER_ID`, `ACTIVITIES` | `ensure_api` | Sesión con Redmine. `USER_NAME` vacío = sin conectar. |
| `TASK_LABEL`, `VAC_LABEL` | `refresh_labels` | Títulos de las tareas para los menús. |
| `WORK_MONTH` | arranque, menú, `month_shift` | Mes de trabajo `AAAA-MM`. Es compartido: si navegas a otro mes en una vista, el menú se queda en él. |
| `MONTH`, `YEAR`, `MON`, `LAST_DAY` | `ask_month` | Mes en curso de una operación. |
| `FROM_DATE`, `TO_DATE`, `PERIOD`, `PERIOD_LABEL`, `RANGE_DATES` | `choose_period` / `ask_range` | Periodo a imputar. |
| `HOLIDAY[DD]`, `HOLIDAY_SRC[DD]`, `HOLIDAYS_NO_LOCAL` | `load_holidays` | Festivos de **un** mes, con clave día `DD`. |
| `RANGE_HOL[AAAA-MM-DD]` | `load_holidays_range` | Festivos de un rango, con clave fecha completa. |
| `M_*` | `analyze_month` | Resultado del análisis de un mes (`M_EXPECTED`, `M_IMPUTED`, `M_MISSING[]`…). |
| `STATUS_CACHE[mes]` | `update_status` | Línea de estado del menú. **Vacíala** (`STATUS_CACHE=()`) tras cambiar datos o configuración. |
| `KEY` | `read_key` | Última tecla: un carácter, o `enter`/`left`/`right`/`up`/`down`/`esc`/`eof`. |

Convenciones del código:

- **Mensajes**: `info` (ℹ), `ok` (✔), `warn` (⚠), `die` (✖ y salida), `title` (cabecera). Dentro de una función cuya stdout se captura con `$(...)`, usa `>&2` en los mensajes.
- **Preguntas**: `ask "texto" [defecto]` devuelve la respuesta por stdout y muestra la pregunta por stderr (`read -p`). `confirm` = sí por defecto, `confirm_no` = no por defecto. `read_key` es para menús de una tecla.
- **Decimales**: Bash no tiene coma flotante. Usa siempre `calc "expr"` y `is_gt a b` (awk). `calc` solo admite números, `+`, `-` y `*` (la expresión se pasa con `awk -v`, nunca como código).
- **Fechas**: la aritmética con fechas `AAAA-MM-DD` se hace con `ddate` (`date` en UTC), para que un cambio de hora a medianoche no rompa `+1 day`.
- **Alineación**: `printf '%-20s'` cuenta *bytes* y descuadra con tildes. Usa `pad "texto" ancho`, que cuenta letras.
- **Pantalla**: `clear_screen`, nunca `clear` (ver trampas).
- **Comentarios de función**: `nombre() { # uso -> resultado`. Mantén ese estilo.
- **Idioma**: todo el texto visible y los comentarios, en español.

---

## Trampas conocidas (leer antes de tocar)

1. **`set -e` y `&&`.** `[[ cond ]] && accion` como **última** línea de una función hace que la función devuelva 1 cuando `cond` es falsa. Con `set -e`, eso puede cerrar el script (por ejemplo, al llamarlo desde el `case` de arranque). Usa `if …; then …; fi` o termina con `return 0`.
2. **`set -e` se desactiva dentro de `cmd || true`.** El menú llama a `cmd_imputar 0 || true`. Por eso dentro de los `cmd_*` los errores importantes se comprueban a mano (`|| { warn …; return 1; }`). No confíes en que `set -e` corte la ejecución.
3. **`$(...)` es un subshell.** Las variables que se asignen dentro se pierden. Por eso `analyze_month`, `load_holidays` o `update_status` se llaman **directamente**, sin `$(...)` (para silenciarlas: `analyze_month m >/dev/null`). Además, `set -e` no se hereda en `$(...)`: comprueba los códigos de salida.
4. **Locale.** El usuario usa `es_ES`, que escribe los decimales con coma. El script hace `unset LC_ALL; export LC_NUMERIC=C` para que awk y printf usen punto. No lo quites o `8 - 2.5` dará `5,5`.
5. **`clear` puede fallar** (por ejemplo, sin `TERM`) y con `set -e` cerraba el script. Por eso existe `clear_screen` (secuencias ANSI y solo si stdout es una terminal).
6. **Corchetes en URLs**: `curl` los interpreta como patrones; hace falta `-g` (ya está en `api_get`).
7. **Filtros de Redmine**: ver la nota de la sección de APIs. Nunca vuelvas a `user_id=me&from=…&to=…`.
8. **Entrada por stdin en funciones que preguntan**: no pases listas por tubería a una función que luego hace `ask`, porque se comería las respuestas. `pick_option` recibe la lista **como argumento** por eso.
9. **Sin terminal** (stdin no es una terminal, como en pruebas con tubería): `read_key` devuelve `eof` al acabarse la entrada y los menús lo tratan como «salir/volver». `browse_months` y `browse_years` no entran en bucle si stdin no es una terminal.
10. **El ámbito `scope` de la API no es fiable**: ver la sección de calendariosnacionales.

---

## Cómo extenderlo

### Añadir una clave de configuración

1. Añádela a `CONFIG_KEYS` y dale valor por defecto justo debajo. Si el usuario debe decidirla al instalar, pregúntala también en `setup_wizard` y en su resumen.
2. Documéntala en la cabecera de comentarios de `save_config` y en `show_help` (sección CONFIGURACIÓN).
3. Crea un `edit_<algo>()` que pregunte, asigne y llame a `save_config`.
4. Añade una línea `menu_item` y un caso en el `case` de `cmd_config`.

### Añadir una opción al menú principal

En `main_menu`: una línea `menu_item tecla "Texto" ["valor"]` y un caso en el `case "$KEY"`. Si cambia datos de Redmine o festivos, vacía `STATUS_CACHE`. Documenta la tecla en `show_help` (MENÚ PRINCIPAL).

### Añadir una opción de línea de comandos

En el `case "${1:-}"` del final (sección **arranque**) y en `show_help` (USO). El segundo argumento ya se interpreta antes como mes (`AAAA-MM`) o año (`AAAA`).

### Añadir un tipo de periodo de imputación

En `choose_period`: un `menu_item` en el selector, un caso en el `case "$KEY"` y otro en el `case "$choice"` que fije `FROM_DATE`, `TO_DATE` y `PERIOD_LABEL`. El resto de `cmd_imputar` ya funciona con cualquier rango de hasta 31 días (más largo, los días de vacaciones dados como «día del mes» serían ambiguos).

### Cambiar de fuente de festivos

Todo pasa por `cal_holidays_json` (JSON de un año) y `cal_holiday_lines` (JSON → `fecha|nombre|ámbito`). Si se cambia de API, adaptando esas dos funciones (y `cal_holidays_path`/`cal_download`) el resto no se toca.

---

## Cómo probar sin riesgo

No hay tests automáticos. Así se ha probado durante el desarrollo:

```bash
bash -n imputar-redmine.sh                      # sintaxis

# Solo lectura contra Redmine
./imputar-redmine.sh -r 2026-10 </dev/null      # resumen de un mes
./imputar-redmine.sh -f 2026 </dev/null         # festivos del año

# Simulación de imputación: NO hace POST. Las respuestas van por la tubería:
printf 's\n\n\n\n\n' | ./imputar-redmine.sh -n  # 's' = esta semana; Intro = valores por defecto

# Configuración en una copia, para no tocar la real
cp imputar-redmine.conf /tmp/prueba.conf
printf '61\n5\nsanta fe\n\nq' | REDMINE_CONFIG=/tmp/prueba.conf ./imputar-redmine.sh -c

# Sin red (un proxy inexistente hace fallar cualquier conexión)
https_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 ./imputar-redmine.sh -u

# Menú en una terminal simulada, con teclas de flecha (\e[D = ←, \e[C = →)
printf 'v\e[D\e[C\rq' | TERM=xterm script -qec ./imputar-redmine.sh /dev/null
```

Para comprobar el aviso de cambios de festivos, altera a mano un fichero de `calendario/` con `jq` y ejecuta `-u`: tiene que mostrar las diferencias y dejar la versión buena de la API.

> Las simulaciones (`-n`, tecla `n`) y `-r`/`-f` no escriben nada en Redmine. **Solo** escribe la confirmación «¿Imputar?» de `cmd_imputar`.

---

## Seguridad

- `imputar-redmine.conf` contiene la **API key**: se crea con `umask 077` y `chmod 600`. No lo compartas, no lo subas a ningún repositorio y no lo pegues en tickets.
- El `.conf` se lee con `sed`, sin `source`, así que nada de lo que contenga se ejecuta.
- La key se pide sin eco (`read -s`) y solo se envía a `REDMINE_URL` en la cabecera `X-Redmine-API-Key`. No se escribe nunca en pantalla ni en logs.
- La key **no va en los argumentos de `curl`** (que cualquier usuario del equipo ve con `ps`): `api_curl` se la pasa con `-K` desde una sustitución de proceso. El cuerpo JSON de `POST`/`PUT` va por la entrada estándar (`--data-binary @-`).
- El script debería tener permisos `755` (o `700`). Si está con permisos de escritura para todos (`777`), cualquier usuario del equipo podría modificarlo y robar la key.
- Si añades llamadas a servicios externos, **no envíes nunca la API key** fuera de Redmine.

---

## Limitaciones conocidas

- **Una sola jornada** (`HOURS`) para todos los días: no hay jornada intensiva ni viernes distinto.
- **Una tarea por día en imputación masiva**: el resto de horas del día va a la tarea principal o a la de vacaciones. Para repartir un día entre varias tareas, imputa por día con horas parciales o edita desde `cmd_gestionar` (`-b`).
- **Medios días de vacaciones**: no hay opción específica en el modo de mes completo; impútalo con la opción de día y horas parciales.
- Los festivos locales del año siguiente dependen de cuándo los publique la API. Hasta entonces, el script avisa y se pueden añadir como propios (con `-y` no imputa hasta que estén publicados: ejecútalo sin `-y`).
- La copia local de festivos no se actualiza sola: si la del año en curso tiene más de 30 días, el script avisa para que la actualices con `-u`.
- Solo funciona con GNU `date` (Linux). En macOS habría que adaptarlo a `gdate`.
