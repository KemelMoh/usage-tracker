#!/bin/bash
set -euo pipefail

# Genera las notas de la release a partir de los commits.
#
#   ./scripts/release-notes.sh 0.2.2
#
# Usa el tag anterior mas cercano como inicio del rango. Las notas salen en
# Markdown, agrupadas por tipo, y se escriben en stdout para poder redirigirlas
# a un fichero o a la release de GitHub.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    echo "Uso: $0 <version-sin-v>" >&2
    exit 1
fi

TAG="v$VERSION"

# El tag anterior mas cercano, ordenados por version y no por fecha.
# `grep -v` devuelve 1 cuando no deja nada, y con `pipefail` eso abortaria el
# script, asi que se protege con `|| true`.
PREVIOUS="$(git tag --list 'v*' --sort=-v:refname \
    | { grep -v "^${TAG}$" || true; } \
    | head -1)"

if [[ -z "$PREVIOUS" ]]; then
    RANGE=""
    HEADER="Todos los cambios"
else
    RANGE="$PREVIOUS..HEAD"
    HEADER="Cambios desde $PREVIOUS"
fi

# Solo los mensajes de una linea, sin los commits de release ni los chores
# internos que no aportan nada al usuario.
#
# Se descartan los commits cuyo mensaje empieza por un prefijo convencional
# de chore, refactor, test, build o ci, ademas de los commits de release.
COMMITS="$(git log $RANGE --no-merges --pretty=format:'%s' --reverse \
    | { grep -vE '^(Release [0-9]|Bump version|Merge )' || true; } \
    | { grep -vE '^(chore|refactor|test|tests|build|ci|style|docs\(ci\))[:(]' || true; } \
    || true)"

if [[ -z "$COMMITS" ]]; then
    echo "$HEADER"
    echo
    echo "Sin cambios."
    exit 0
fi

# Clasifica cada commit por el prefijo convencional del mensaje y, si no lo
# tiene, por palabras clave. Asi el changelog queda agrupado aunque los
# commits no usen la convencion.
FEATURES=""
FIXES=""
PERF=""
DOCS=""
OTHER=""

while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    lower="$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')"

    case "$line" in
        "feat: "*)
            FEATURES="${FEATURES}- ${line#feat: }\n"
            continue ;;
        "fix: "*)
            FIXES="${FIXES}- ${line#fix: }\n"
            continue ;;
        "perf: "*)
            PERF="${PERF}- ${line#perf: }\n"
            continue ;;
        "docs: "*)
            DOCS="${DOCS}- ${line#docs: }\n"
            continue ;;
    esac

    case "$lower" in
        *"corrige"*|*"corrección"*|*"arregla"*|*"fix "*|*"evita"*|*"quita "*|*"elimina "*|*"no se"*)
            FIXES="${FIXES}- $line\n" ;;
        *"añade"*|*"añaden"*|*"nueva"*|*"nuevo "*|*"add "*|*"implementa"*|*"cierra"*|*"reorganiza"*)
            FEATURES="${FEATURES}- $line\n" ;;
        *"rendimiento"*|*"optimiza"*|*"mejora el rendimiento"*|*"acelera"*|*"refactor"*|*"performance"*)
            PERF="${PERF}- $line\n" ;;
        *"readme"*|*"documenta"*|*"documentación"*|*"docs"*|*"licencia"*|*"license"*)
            DOCS="${DOCS}- $line\n" ;;
        *)
            OTHER="${OTHER}- $line\n" ;;
    esac
done <<< "$COMMITS"

echo "$HEADER"
echo

if [[ -n "$FEATURES" ]]; then
    echo "### Novedades"
    echo
    printf "%b" "$FEATURES"
    echo
fi

if [[ -n "$FIXES" ]]; then
    echo "### Correcciones"
    echo
    printf "%b" "$FIXES"
    echo
fi

if [[ -n "$PERF" ]]; then
    echo "### Rendimiento"
    echo
    printf "%b" "$PERF"
    echo
fi

if [[ -n "$OTHER" ]]; then
    echo "### Otros cambios"
    echo
    printf "%b" "$OTHER"
    echo
fi

if [[ -n "$DOCS" ]]; then
    echo "### Documentación"
    echo
    printf "%b" "$DOCS"
    echo
fi

if [[ -n "$PREVIOUS" ]]; then
    echo "**Comparación completa**: https://github.com/KemelMoh/usage-tracker/compare/$PREVIOUS...$TAG"
fi
