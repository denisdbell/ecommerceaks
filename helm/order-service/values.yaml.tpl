replicaCount: 2

image:
  repository: ecommerceacrdenis.azurecr.io/order-service
  tag: latest
  pullPolicy: Always

namespace: order-service

service:
  type: ClusterIP
  port: 3001

workloadIdentity:
  clientId: "${client_id}"

keyVault:
  name: "${keyvault_name}"
  tenantId: "${tenant_id}"

env:
  NOTIFICATION_SERVICE_URL: "http://notification-service.notification-service.svc.cluster.local:3002"
