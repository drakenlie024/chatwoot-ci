#!/usr/bin/env bash
#
# Atualiza o Chatwoot na VPS para a imagem gerada pelo pipeline.
# Rodar NA VPS, dentro de /docker/chatwoot
#
#   bash /opt/pre-chatwoot/atualizar-chatwoot.sh
#
# Ou copie este arquivo para a VPS e rode de lá.
#
set -euo pipefail

COMPOSE_DIR="${COMPOSE_DIR:-/docker/chatwoot}"
HEALTH_URL="${HEALTH_URL:-https://chat.franferreira.cloud/health}"

cd "$COMPOSE_DIR"

echo "==> Diretório: $COMPOSE_DIR"
echo "==> Imagem atual em uso:"
docker compose config 2>/dev/null | grep -E '^\s+image:' | sort -u | sed 's/^/    /'

echo ""
echo "==> 1. Pull das imagens"
docker compose pull

echo ""
echo "==> 2. Recriando containers"
docker compose up -d

echo ""
echo "==> 3. Aplicando migrations (o entrypoint NAO faz isso sozinho)"
docker compose run --rm rails bundle exec rails db:chatwoot_prepare 2>&1 | tail -5

echo ""
echo "==> 4. Status"
docker compose ps

echo ""
echo "==> 5. Aguardando o app responder"
for i in $(seq 1 24); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$HEALTH_URL" || echo "000")
  if [ "$code" = "200" ]; then
    echo "    OK - $HEALTH_URL respondeu 200 (tentativa $i)"
    break
  fi
  echo "    tentativa $i: http=$code"
  sleep 5
done

echo ""
echo "==> 6. Logs recentes do rails"
docker logs --tail 15 chatwoot-rails-1 2>&1 | sed 's/^/    /'

echo ""
echo "Pronto. Se algo falhou, o rollback é trocar a tag da imagem no"
echo "docker-compose.yml e rodar este script de novo."
