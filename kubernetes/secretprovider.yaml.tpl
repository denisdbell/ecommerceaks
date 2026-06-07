apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: order-service-secrets
  namespace: order-service
spec:
  provider: azure
  parameters:
    usePodIdentity: "false"
    clientID: "${client_id}"
    keyvaultName: "${keyvault_name}"
    tenantId: "${tenant_id}"
    objects: |
      array:
        - |
          objectName: postgres-password    # name of secret in Key Vault
          objectType: secret
        - |
          objectName: api-key
          objectType: secret
