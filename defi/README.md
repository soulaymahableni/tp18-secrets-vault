# Défis (facultatifs)

## 1. Identifiants PostgreSQL dynamiques (moteur database de Vault)

Nécessite le PostgreSQL du TP14 (namespace `tp14`, Secret `postgres-secret`), redéployé si besoin.

```bash
export VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root
PGPW=$(kubectl -n tp14 get secret postgres-secret -o jsonpath='{.data.password}' | base64 -d)

vault secrets enable database
vault write database/config/tp14-postgres \
  plugin_name=postgresql-database-plugin \
  connection_url="postgresql://{{username}}:{{password}}@postgres.tp14.svc.cluster.local:5432/postgres?sslmode=disable" \
  allowed_roles="readonly" username="postgres" password="$PGPW"

vault write database/roles/readonly db_name=tp14-postgres default_ttl=1h max_ttl=24h \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";"

vault read database/creds/readonly          # utilisateur v-token-readonly-… valable 1 h
kubectl -n tp14 exec deploy/postgres -- psql -U postgres -c '\du'   # l'utilisateur temporaire existe
vault lease revoke -prefix database/creds/readonly                  # révocation immédiate
```

Intérêt : chaque application reçoit son propre identifiant, qui expire seul. Une fuite a une durée de vie limitée, et on sait exactement qui l'a obtenu.

## 2. Chiffrement des Secrets au repos dans K3s

```bash
sudo k3s secrets-encrypt status              # Encryption Status: Disabled
echo "secrets-encryption: true" | sudo tee -a /etc/rancher/k3s/config.yaml
sudo systemctl restart k3s
sleep 30
sudo k3s secrets-encrypt status              # Enabled, clé AES-CBC active
# Rechiffrer les Secrets existants avec la clé :
sudo k3s secrets-encrypt reencrypt
```

Les Secrets sont alors chiffrés dans la base de K3s (`/var/lib/rancher/k3s/server/db`). Ils restent lisibles en clair via l'API pour qui a le droit `get secret` : le RBAC reste indispensable.
