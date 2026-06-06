#!/bin/bash
set -e

ACR="ecommerceacrdenis"
TAG="${1:-latest}"

echo "Building and pushing images to $ACR with tag: $TAG"

az acr build --registry $ACR --image api-gateway:$TAG          services/api-gateway
az acr build --registry $ACR --image order-service:$TAG        services/order-service
az acr build --registry $ACR --image notification-service:$TAG services/notification-service

echo "Images pushed:"
echo "  $ACR.azurecr.io/api-gateway:$TAG"
echo "  $ACR.azurecr.io/order-service:$TAG"
echo "  $ACR.azurecr.io/notification-service:$TAG"

echo ""
echo "Deploying to AKS..."

helm upgrade --install api-gateway          helm/api-gateway          -n api-gateway          --set image.tag=$TAG
helm upgrade --install order-service        helm/order-service        -n order-service        --set image.tag=$TAG
helm upgrade --install notification-service helm/notification-service -n notification-service --set image.tag=$TAG

echo ""
echo "Waiting for rollouts to complete..."
kubectl rollout status deployment/api-gateway          -n api-gateway
kubectl rollout status deployment/order-service        -n order-service
kubectl rollout status deployment/notification-service -n notification-service

echo ""
echo "Deploy complete. All services running tag: $TAG"
