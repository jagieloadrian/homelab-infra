#!/usr/bin/env bash
# Rejestruje aplikację w klastrze (README: "Aplikacje").
#   scripts/new-app.sh own  <name>                                  # własna, manifesty w .devops/ repo <name>
#   scripts/new-app.sh helm <name> <repo-url> <chart> <version> [port] # gotowa z Helm charta, tutaj w apps/<name>/
set -euo pipefail
cd "$(dirname "$0")/.."

usage() { sed -n '3,4p' "$0" | sed 's/^# *//' >&2; exit 1; }

mode=${1:-} name=${2:-}
[[ $name =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || usage

case $mode in
  own)
    out=clusters/home/apps/$name.yaml
    [[ ! -e $out ]] || { echo "$out już istnieje" >&2; exit 1; }
    sed "s/APP/$name/g" clusters/home/apps/_app.yaml.example > "$out"
    ;;
  helm)
    (($# >= 5)) || usage
    url=$3 chart=$4 version=$5 port=${6:-80}
    out=apps/$name/release.yaml
    [[ ! -e $out ]] || { echo "$out już istnieje" >&2; exit 1; }
    mkdir -p "apps/$name"
    sed -e "s|__NAME__|$name|g" -e "s|__URL__|$url|g" -e "s|__CHART__|$chart|g" \
        -e "s|__VERSION__|$version|g" -e "s|__PORT__|$port|g" apps/_template/release.yaml.tpl > "$out"
    [[ $url == oci://* ]] || sed -i '/^  type: oci$/d' "$out"
    ;;
  *) usage ;;
esac

echo "Utworzono $out. Przejrzyj, potem: git add -A && git commit -m 'feat(apps): add $name' && git push"
