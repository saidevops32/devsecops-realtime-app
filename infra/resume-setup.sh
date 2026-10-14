#!/usr/bin/env bash
# Resumes azure-setup.sh after the Container Apps environment step.
set -euo pipefail

GH_REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
LOC=centralindia
RG=devsecops-rg
VNET=devsecops-vnet
ENV_NAME=devsecops-env
AGW=devsecops-agw

ACR=$(az acr list -g $RG --query "[0].name" -o tsv)
SUFFIX=${ACR#devsecopsacr}
PG=devsecops-pg-$SUFFIX
IDENTITY=id-aca-$SUFFIX
ACR_ID=$(az acr show -n $ACR --query id -o tsv)
IDENTITY_ID=$(az identity show -g $RG -n $IDENTITY --query id -o tsv)
ACA_SUBNET_ID=$(az network vnet subnet show -g $RG --vnet-name $VNET -n aca-subnet --query id -o tsv)
PG_HOST=$(az postgres flexible-server show -g $RG -n $PG --query fullyQualifiedDomainName -o tsv)
echo "Using ACR=$ACR PG=$PG"

PG_PASSWORD=$(openssl rand -hex 24)
RABBIT_PASSWORD=$(openssl rand -hex 24)
echo ">> Resetting PostgreSQL admin password (the original was never saved)"
az postgres flexible-server update -g $RG -n $PG --admin-password "$PG_PASSWORD" -o none

echo ">> Container Apps environment"
if ! az containerapp env show -g $RG -n $ENV_NAME >/dev/null 2>&1; then
  az containerapp env create -g $RG -n $ENV_NAME -l $LOC --infrastructure-subnet-resource-id $ACA_SUBNET_ID --internal-only true --no-wait -o none
fi
STATE=unknown
for i in $(seq 1 60); do
  STATE=$(az containerapp env show -g $RG -n $ENV_NAME --query properties.provisioningState -o tsv 2>/dev/null || echo missing)
  echo "environment state: $STATE"
  if [ "$STATE" = "Succeeded" ]; then break; fi
  if [ "$STATE" = "Failed" ]; then echo "Environment failed. Delete it and re-run."; exit 1; fi
  sleep 30
done
if [ "$STATE" != "Succeeded" ]; then echo "Timed out waiting for environment"; exit 1; fi
DOMAIN=$(az containerapp env show -g $RG -n $ENV_NAME --query properties.defaultDomain -o tsv)
STATIC_IP=$(az containerapp env show -g $RG -n $ENV_NAME --query properties.staticIp -o tsv)

echo ">> Private DNS so the gateway can resolve *.$DOMAIN"
az network private-dns zone create -g $RG -n $DOMAIN -o none
az network private-dns link vnet create -g $RG -z $DOMAIN -n aca-link -v $VNET --registration-enabled false -o none
az network private-dns record-set a add-record -g $RG -z $DOMAIN -n '*' -a $STATIC_IP -o none
az network private-dns record-set a add-record -g $RG -z $DOMAIN -n '@' -a $STATIC_IP -o none

echo ">> Application Gateway with WAF (takes about 10 minutes)"
az network public-ip create -g $RG -n agw-pip --sku Standard --allocation-method Static -o none
az network application-gateway waf-policy create -g $RG -n agw-waf --type OWASP --version 3.2 -o none
az network application-gateway waf-policy policy-setting update -g $RG --policy-name agw-waf --mode Prevention --state Enabled -o none
az network application-gateway create -g $RG -n $AGW -l $LOC --sku WAF_v2 --capacity 1 --vnet-name $VNET --subnet agw-subnet --public-ip-address agw-pip --frontend-port 80 --http-settings-port 80 --http-settings-protocol Http --servers frontend.$DOMAIN --priority 100 --waf-policy agw-waf -o none
az network application-gateway http-settings update -g $RG --gateway-name $AGW -n appGatewayBackendHttpSettings --host-name-from-backend-pool true -o none
az network application-gateway probe create -g $RG --gateway-name $AGW -n frontend-probe --protocol Http --host-name-from-http-settings true --path /healthz --interval 30 --timeout 30 --threshold 3 -o none
az network application-gateway http-settings update -g $RG --gateway-name $AGW -n appGatewayBackendHttpSettings --probe frontend-probe -o none
GW_IP=$(az network public-ip show -g $RG -n agw-pip --query ipAddress -o tsv)

echo ">> GitHub OIDC identity (passwordless login for the pipeline)"
APP_ID=$(az ad app create --display-name "gh-${GH_REPO//\//-}-$SUFFIX" --query appId -o tsv)
az ad sp create --id $APP_ID -o none
SP_OBJ=$(az ad sp show --id $APP_ID --query id -o tsv)
RG_ID=$(az group show -n $RG --query id -o tsv)
az role assignment create --assignee-object-id $SP_OBJ --assignee-principal-type ServicePrincipal --role Contributor --scope $RG_ID -o none
az role assignment create --assignee-object-id $SP_OBJ --assignee-principal-type ServicePrincipal --role AcrPush --scope $ACR_ID -o none
az ad app federated-credential create --id $APP_ID --parameters "{\"name\":\"github-main\",\"issuer\":\"https://token.actions.githubusercontent.com\",\"subject\":\"repo:${GH_REPO}:ref:refs/heads/main\",\"audiences\":[\"api://AzureADTokenExchange\"]}" -o none

echo ">> Saving GitHub secrets and variables"
gh secret set AZURE_CLIENT_ID       --repo $GH_REPO --body "$APP_ID"
gh secret set AZURE_TENANT_ID       --repo $GH_REPO --body "$(az account show --query tenantId -o tsv)"
gh secret set AZURE_SUBSCRIPTION_ID --repo $GH_REPO --body "$(az account show --query id -o tsv)"
gh secret set PG_PASSWORD           --repo $GH_REPO --body "$PG_PASSWORD"
gh secret set RABBIT_PASSWORD       --repo $GH_REPO --body "$RABBIT_PASSWORD"
gh variable set ACR_NAME    --repo $GH_REPO --body "$ACR"
gh variable set AZURE_RG    --repo $GH_REPO --body "$RG"
gh variable set ACA_ENV     --repo $GH_REPO --body "$ENV_NAME"
gh variable set IDENTITY_ID --repo $GH_REPO --body "$IDENTITY_ID"
gh variable set PG_HOST     --repo $GH_REPO --body "$PG_HOST"
gh variable set APP_URL     --repo $GH_REPO --body "http://$GW_IP"

echo "DONE. App will be at http://$GW_IP after the first pipeline run."
