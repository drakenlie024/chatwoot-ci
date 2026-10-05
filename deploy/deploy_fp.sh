#!/usr/bin/env bash
# Deploy do Chatwoot FP.  Uso: bash deploy_fp.sh <run_id> <tag>
# Endurecido: so diz CONCLUIDO se o build passou, o pull funcionou, a imagem
# trocou de verdade, o container subiu NA IMAGEM NOVA e o health deu 200.
set -uo pipefail
if [ $# -lt 2 ]; then echo "uso: bash deploy_fp.sh <run_id> <tag>"; exit 2; fi
RUN="$1"; TAG="$2"
IMG="ghcr.io/drakenlie024/chatwoot:v4.18.0-$TAG"
COMPOSE=/docker/chatwoot/docker-compose.yml
HEALTH_URL="https://chat.franferreira.cloud/health"
TOKEN=$(python3 -c "import base64,json;print(json.load(open('/root/.docker/config.json'))['auths']['ghcr.io']['auth'])" | base64 -d | cut -d: -f2-)
API="https://api.github.com/repos/drakenlie024/chatwoot-ci/actions/runs/$RUN"

falhar() { echo "DEPLOY $TAG FALHOU: $*"; exit 1; }
st(){ curl -s -H "Authorization: token $TOKEN" "$API" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('status',''),d.get('conclusion') or '')"; }

echo "== 1/5 aguardando build $TAG (run $RUN) =="
S=""; C=""
for i in $(seq 1 300); do
  read -r S C <<< "$(st)"
  echo "[$(date +%H:%M:%S)] status=$S conclusion=$C"
  [ "$S" = "completed" ] && break
  sleep 30
done
[ "$S" = "completed" ] || falhar "timeout esperando o build terminar"
[ "$C" = "success" ] || falhar "build concluiu com '$C'"

echo "== 2/5 trocando a imagem no compose para $TAG =="
cd /docker/chatwoot
TAG_ANTERIOR=$(grep -oE 'ghcr.io/drakenlie024/chatwoot:v4.18.0-[A-Za-z0-9_.-]+' "$COMPOSE" | head -1 | sed 's#.*:##')
echo "tag anterior: $TAG_ANTERIOR"
BAK="$COMPOSE.bak-$TAG-$(date +%Y%m%d%H%M%S)"
cp -n "$COMPOSE" "$BAK"
sed -i -E "s|ghcr.io/drakenlie024/chatwoot:v4.18.0-fp[-A-Za-z0-9_.]*|$IMG|g" "$COMPOSE"
grep -n 'image: ghcr' "$COMPOSE"
grep -q "$IMG" "$COMPOSE" || falhar "a imagem nao foi trocada no compose"

echo "== 3/5 docker compose pull =="
if ! docker compose pull; then
  cp "$BAK" "$COMPOSE"
  falhar "pull falhou (compose restaurado para $TAG_ANTERIOR)"
fi
docker image inspect "$IMG" >/dev/null 2>&1 || falhar "imagem $IMG nao existe localmente apos o pull"

echo "== 4/5 docker compose up -d =="
docker compose up -d || falhar "docker compose up falhou"
docker compose run --rm rails bundle exec rails db:chatwoot_prepare 2>&1 | tail -3
docker compose ps

echo "== 5/5 health + imagem no ar =="
H=""
for i in $(seq 1 40); do
  H=$(curl -s -m 8 -o /dev/null -w '%{http_code}' "$HEALTH_URL")
  echo "[$i] health=$H"
  [ "$H" = "200" ] && break
  sleep 8
done
ATUAL=$(docker inspect --format '{{.Config.Image}}' chatwoot-rails-1 2>/dev/null)
echo "imagem no ar: $ATUAL"
[ "$ATUAL" = "$IMG" ] || falhar "container nao subiu na imagem nova (esta: $ATUAL)"
[ "$H" = "200" ] || falhar "health nao subiu (ultimo=$H). Rollback: cp $BAK $COMPOSE && docker compose up -d"

echo "DEPLOY $TAG CONCLUIDO (health=200, imagem=$IMG)"
