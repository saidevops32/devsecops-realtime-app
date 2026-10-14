#!/usr/bin/env bash
# Called by GitHub Actions. Creates each Container App the first time, updates it afterwards.
set -euo pipefail
az config set extension.use_dynamic_install=yes_without_prompt >/dev/null

REG="$ACR_NAME.azurecr.io"
ID_ARGS="--user-assigned $IDENTITY_ID --registry-server $REG --registry-identity $IDENTITY_ID"
exists() { az containerapp show -g "$RG" -n "$1" >/dev/null 2>&1; }

# RabbitMQ: internal TCP only
if ! exists rabbitmq; then
  az containerapp create -g "$RG" -n rabbitmq --environment "$ENV_NAME" \
    --image "$REG/rabbitmq:3.13-alpine" $ID_ARGS \
    --ingress internal --transport tcp --target-port 5672 --exposed-port 5672 \
    --min-replicas 1 --max-replicas 1 \
    --secrets rabbitpass="$RABBIT_PASSWORD" \
    --env-vars RABBITMQ_DEFAULT_USER=app RABBITMQ_DEFAULT_PASS=secretref:rabbitpass
fi

# Backend: internal only. Keep 1 replica so Socket.IO needs no sticky sessions.
if ! exists backend; then
  az containerapp create -g "$RG" -n backend --environment "$ENV_NAME" \
    --image "$REG/backend:$TAG" $ID_ARGS \
    --ingress internal --target-port 3000 \
    --min-replicas 1 --max-replicas 1 \
    --secrets pgpass="$PG_PASSWORD" rabbitpass="$RABBIT_PASSWORD" \
    --env-vars PGHOST="$PG_HOST" PGUSER=pgadmin PGDATABASE=appdb PGSSL=true PGPASSWORD=secretref:pgpass \
               RABBITMQ_HOST=rabbitmq RABBITMQ_USER=app RABBITMQ_PASS=secretref:rabbitpass
  az containerapp ingress update -g "$RG" -n backend --allow-insecure true
else
  az containerapp update -g "$RG" -n backend --image "$REG/backend:$TAG"

fi

# Worker (Erlang): no ingress
if ! exists worker; then
  az containerapp create -g "$RG" -n worker --environment "$ENV_NAME" \
    --image "$REG/worker:$TAG" $ID_ARGS \
    --min-replicas 1 --max-replicas 3 \
    --secrets rabbitpass="$RABBIT_PASSWORD" \
    --env-vars RABBITMQ_HOST=rabbitmq RABBITMQ_USER=app RABBITMQ_PASS=secretref:rabbitpass
else
  az containerapp update -g "$RG" -n worker --image "$REG/worker:$TAG"
fi

# Frontend: reachable from the VNet only; the Application Gateway is the public door
if ! exists frontend; then
  az containerapp create -g "$RG" -n frontend --environment "$ENV_NAME" \
    --image "$REG/frontend:$TAG" $ID_ARGS \
    --ingress external --target-port 8080 \
    --min-replicas 1 --max-replicas 2 \
    --env-vars BACKEND_URL=http://backend
  az containerapp ingress update -g "$RG" -n frontend --allow-insecure true
else
  az containerapp update -g "$RG" -n frontend --image "$REG/frontend:$TAG"
fi
echo "Deployed tag $TAG"
