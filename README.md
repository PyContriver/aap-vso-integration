# AAP + VSO Integration POC

Full Vault secrets integration for Ansible Automation Platform on OpenShift
using the Vault Secrets Operator (VSO). All secret fields confirmed from the
actual AAP operator source code.

**Operator source:** `/Users/siddasha/playground/aap_operator/ansible-automation-platform-operator-bundle-container`

---

## What this proves

Every secret that AAP uses is pre-created by VSO from HashiCorp Vault.
The operator finds each pre-created secret and uses it — no auto-generation.

| Secret | Operator | CR field | K8s Secret key | Vault path |
|---|---|---|---|---|
| Controller SECRET_KEY | `awx-operator` | `secret_key_secret` | `secret_key` | `aap/<cluster>/secrets/controller` |
| Broadcast websocket | `awx-operator` | `broadcast_websocket_secret` | `secret` | `aap/<cluster>/secrets/controller` |
| Controller admin password | `awx-operator` | `admin_password_secret` | `password` | `aap/<cluster>/credentials/aap` |
| Controller postgres | `awx-operator` | `postgres_configuration_secret` | `host,username,password,database,port,type` | `aap/<cluster>/database/controller` |
| Hub admin password | `galaxy-operator` | `admin_password_secret` | `password` | `aap/<cluster>/credentials/aap` |
| Hub postgres | `galaxy-operator` | `postgres_configuration_secret` | `host,username,password,database,port,type` | `aap/<cluster>/database/hub` |
| Hub db encryption | `galaxy-operator` | `db_fields_encryption_secret` | `database_fields.symmetric.key` | `aap/<cluster>/encryption/hub` |
| Platform admin password | `gateway-operator` | `admin_password_secret` | `password` | `aap/<cluster>/credentials/aap` |
| Platform postgres | `gateway-operator` | `database_secret` | `host,username,password,database,port,type` | `aap/<cluster>/database/platform` |
| EDA admin password | `eda-server-operator` | `admin_password_secret` | `password` | `aap/<cluster>/credentials/aap` |
| EDA postgres | `eda-server-operator` | `database.database_secret` | `host,username,password,database,port,type` | `aap/<cluster>/database/eda` |
| EDA db encryption | `eda-server-operator` | `db_fields_encryption_secret` | `database_fields.symmetric.key` | `aap/<cluster>/encryption/eda` |

**Key insight:** The operator uses `type: unmanaged` in the postgres secret to
decide whether to create its own postgres pod (`type: managed`) or connect to
an external one (`type: unmanaged`). Source: `database_configuration.yml`:
```python
managed_database = (secret.data['type'] == 'managed')
```

**No operator code changes needed.** All these CR fields already exist.

---

## Prerequisites

- OpenShift cluster with VSO operator installed
- HCP Vault (or self-managed) reachable from the cluster
- `postgres` running at the host you'll specify during bootstrap
- `nfs-rwx` storage class (for Hub file storage)

---

## Quick Start

### 1. Configure
```bash
cp config.env.example overlays/non-saas/config.env
# Edit: CLUSTER_NAME, VAULT_ADDR
```

### 2. Bootstrap Vault (one-time)
```bash
export VAULT_ADDR=https://your-vault:8200
export VAULT_NAMESPACE=admin   # HCP Vault
export VAULT_TOKEN=<token>
./bootstrap-vault.sh
```

### 3. Apply VSO secrets
```bash
oc create namespace ansible-automation-platform --dry-run=client -o yaml | oc apply -f -
oc create namespace vault-secrets-operator-system --dry-run=client -o yaml | oc apply -f -

oc kustomize overlays/non-saas | oc apply -f -

# Verify all 12 secrets synced
oc get vaultstaticsecret -n ansible-automation-platform
oc get secret -n ansible-automation-platform | grep -E "admin|postgres|secret-key|websocket|encryption"
```

### 4. Deploy AAP
```bash
oc kustomize aap-cr | oc apply -f -
oc get pods -n ansible-automation-platform -w
```

---

## Structure

```
aap-vso-integration/
├── README.md
├── config.env.example
├── bootstrap-vault.sh          ← Seed all Vault paths
├── base/
│   ├── kustomization.yaml
│   ├── vault-infra/            ← VaultConnection, VaultAuth, SA, RBAC
│   ├── aap-secrets/            ← 12 VaultStaticSecrets (key names from operator source)
│   └── transformers/           ← CLUSTER_NAME + VAULT_MOUNT injection
├── overlays/
│   ├── non-saas/               ← config.env for your cluster
│   └── saas/                   ← (extend with S3/metrics secrets)
└── aap-cr/
    └── automation-platform.yaml ← Full CR with all 12 secret fields
```

---

## Rotation test (proves AC4)

```bash
# Rotate controller SECRET_KEY in Vault
vault write secret/data/aap/$CLUSTER_NAME/secrets/controller - <<'EOF'
{"data": {"secret_key": "NewRotatedKey32CharsExactLength!"}}
EOF

# Within 60s VSO syncs, K8s Secret updates
sleep 65
oc get secret automation-controller-secret-key \
  -n ansible-automation-platform \
  -o jsonpath='{.data.secret_key}' | base64 -d
# Should show new value
```
