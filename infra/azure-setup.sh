#!/usr/bin/env bash
# Run in Azure Cloud Shell from the repo folder, after `gh auth login`.
set -euo pipefail

GH_REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
SUFFIX=${SUFFIX:-$(openssl rand -hex 3)}
LOC=centralindia
RG=devsecops-rg
VNET=devsecops-vnet
ACR=devsecopsacr$SUFFIX
PG=devsecops-pg-$SUFFIX
ENV_NAME=devsecops-env
AGW=devsecops-agw
IDENTITY=id-aca-$SUFFIX
PG_PASSWORD=$(openssl rand -hex 24)
RABBIT_PASSWORD=$(openssl rand -hex 24)

echo ">> Providers and extensions"
az extension add --name containerapp --upgrade -y
for p in Microsoft.App Microsoft.OperationalInsights Microsoft.Network Microsoft.DBforPostgreSQL Microsoft.ContainerRegistry; do
  az provider register --namespace $p --wait
done

echo ">> Resource group and network"
az group create -n $RG -l $LOC -o none
az network vnet create -g $RG -n $VNET -l $LOC --address-prefixes 10.0.0.0/16 -o none
az network vnet subnet create -g $RG --vnet-name $VNET -n aca-subnet --address-prefixes 10.0.0.0/23 \
  --delegations Microsoft.App/environments -o none
az network vnet subnet create -g $RG --vnet-name $VNET -n agw-subnet --address-prefixes 10.0.2.0/24 -o none
az network vnet subnet create -g $RG --vnet-name $VNET -n pg-subnet  --address-prefixes 10.0.3.0/24 \

  --delegations Microsoft.DBforPostgreSQL/flexibleServers -o none
ACA_SUBNET_ID=$(az network vnet subnet show -g $RG --vnet-name $VNET -n aca-subnet --query id -o tsv)
PG_SUBNET_ID=$(az network vnet subnet show -g $RG --vnet-name $VNET -n pg-subnet  --query id -o tsv)

echo ">> Container Registry, managed identity, base image import"
az acr create -g $RG -n $ACR --sku Basic --admin-enabled false -o none
ACR_ID=$(az acr show -n $ACR --query id -o tsv)
az acr import -n $ACR --source docker.io/library/rabbitmq:3.13-alpine --image rabbitmq:3.13-alpine
az identity create -g $RG -n $IDENTITY -o none
IDENTITY_ID=$(az identity show -g $RG -n $IDENTITY --query id -o tsv)
IDENTITY_PRINCIPAL=$(az identity show -g $RG -n $IDENTITY --query principalId -o tsv)
az role assignment create --assignee-object-id $IDENTITY_PRINCIPAL --assignee-principal-type ServicePrincipal \
  --role AcrPull --scope $ACR_ID -o none

echo ">> PostgreSQL (private, VNet only)"
PG_DNS=devsecops-db.postgres.database.azure.com
az network private-dns zone create -g $RG -n $PG_DNS -o none
az network private-dns link vnet create -g $RG -z $PG_DNS -n pg-link -v $VNET --registration-enabled false -o none
PG_DNS_ID=$(az network private-dns zone show -g $RG -n $PG_DNS --query id -o tsv)
az postgres flexible-server create -g $RG -n $PG -l $LOC \
  --admin-user pgadmin --admin-password "$PG_PASSWORD" \
  --sku-name Standard_B1ms --tier Burstable --version 16 \
  --subnet $PG_SUBNET_ID --private-dns-zone $PG_DNS_ID --yes -o none
az postgres flexible-server db create -g $RG -s $PG -n appdb -o none
PG_HOST=$(az postgres flexible-server show -g $RG -n $PG --query fullyQualifiedDomainName -o tsv)

echo ">> Container Apps environment (internal only)"
az containerapp env create -g $RG -n $ENV_NAME -l $LOC \
  --infrastructure-subnet-resource-id $ACA_SUBNET_ID --internal-only true -o none
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
az network application-gateway waf-policy policy-setting update -g $RG --policy-name agw-waf \
  --mode Prevention --state Enabled -o none
az network application-gateway create -g $RG -n $AGW -l $LOC \
  --sku WAF_v2 --capacity 1 --vnet-name $VNET --subnet agw-subnet --public-ip-address agw-pip \
  --frontend-port 80 --http-settings-port 80 --http-settings-protocol Http \
  --servers frontend.$DOMAIN --priority 100 --waf-policy agw-waf -o none
az network application-gateway http-settings update -g $RG --gateway-name $AGW \
  -n appGatewayBackendHttpSettings --host-name-from-backend-pool true -o none
az network application-gateway probe create -g $RG --gateway-name $AGW -n frontend-probe \
  --protocol Http --host-name-from-http-settings true --path /healthz \
  --interval 30 --timeout 30 --threshold 3 -o none
az network application-gateway http-settings update -g $RG --gateway-name $AGW \
  -n appGatewayBackendHttpSettings --probe frontend-probe -o none
GW_IP=$(az network public-ip show -g $RG -n agw-pip --query ipAddress -o tsv)

echo ">> GitHub OIDC identity (passwordless login for the pipeline)"
APP_ID=$(az ad app create --display-name "gh-${GH_REPO//\//-}-$SUFFIX" --query appId -o tsv)
az ad sp create --id $APP_ID -o none
SP_OBJ=$(az ad sp show --id $APP_ID --query id -o tsv)
RG_ID=$(az group show -n $RG --query id -o tsv)
az role assignment create --assignee-object-id $SP_OBJ --assignee-principal-type ServicePrincipal --role Contributor --scope $RG_ID -o none
az role assignment create --assignee-object-id $SP_OBJ --assignee-principal-type ServicePrincipal --role AcrPush    --scope $ACR_ID -o none
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
