# TP18 : Gestion des secrets (Vault, External Secrets Operator, Sealed Secrets, rotation)

Trois façons de gérer un secret dans Kubernetes : un coffre-fort central (**Vault**) synchronisé par **External Secrets Operator**, une seconde source **AWS Secrets Manager** émulée par Floci, et des secrets chiffrés versionnables (**Sealed Secrets**). Plus la rotation, et son effet sur une variable d'environnement et sur un fichier monté.
Les réponses et le tableau comparatif sont dans [REPONSES.md](REPONSES.md).

```
.
├── captures/
├── vault/app-policy.hcl              ← lecture seule sur secret/data/tp18/*
├── manifests/
│   ├── 00-app.yaml                   ← namespace tp18, ServiceAccount app-sa, Deployment secret-reader
│   ├── 10-secretstore.yaml           ← SecretStore Vault (auth Kubernetes, rôle tp18-app)
│   ├── 20-externalsecret.yaml        ← secret/tp18/api → Secret api-credentials
│   └── 30-secretstore-floci.yaml     ← SecretStore AWS (Floci) + ExternalSecret db-credentials
├── smtp-sealed.yaml                  ← à générer en Partie 6 (chiffré : peut être commité)
└── defi/README.md                    ← secrets dynamiques PostgreSQL, chiffrement au repos K3s
```

**Aucun secret en clair dans Git** : les Secrets `floci-creds` et la sauvegarde de la clé Sealed Secrets restent hors du dépôt (`.gitignore`).

> Connexion lente : les images (Vault, ESO, Sealed Secrets, Reloader) peuvent mettre plusieurs minutes à se télécharger. Si un Pod reste en `ImagePullBackOff`, pré-télécharger l'image : `sudo k3s crictl pull <image>`, puis supprimer le Pod.

## 0. Préparation

```bash
free -m
kubectl get pods -A | grep -vE 'Running|Completed'     # rien de bloqué
sudo apt install -y vault         # dépôt APT HashiCorp déjà ajouté au TP6 (Terraform)
vault version
```

## 1. Partie 1 : Vault (mode dev)

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com && helm repo update
helm install vault hashicorp/vault -n vault --create-namespace \
  --set server.dev.enabled=true --set server.dev.devRootToken=root --set injector.enabled=false
kubectl -n vault get pods -w            # vault-0 1/1 Running, puis Ctrl+C

kubectl -n vault port-forward svc/vault 8200:8200 >/dev/null 2>&1 &
export VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root
vault status                            # Sealed false, Storage Type inmem

vault kv put secret/tp18/api api-key=v1-initial-value
clear
vault kv get secret/tp18/api
vault kv metadata get secret/tp18/api
```

**Capture `vault-kv.png`** : `vault kv get` (`api-key  v1-initial-value`) et `vault kv metadata get` (`current_version 1`, liste des versions).

## 2. Partie 2 : policy et authentification Kubernetes

```bash
vault policy write tp18-app vault/app-policy.hcl
vault auth enable kubernetes
vault write auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc:443"
vault write auth/kubernetes/role/tp18-app \
  bound_service_account_names=app-sa bound_service_account_namespaces=tp18 \
  policies=tp18-app ttl=1h
clear
vault policy read tp18-app
vault read auth/kubernetes/role/tp18-app
```

**Capture `vault-k8s-auth.png`** : la policy (`path "secret/data/tp18/*" … read`) et le rôle (`bound_service_account_names [app-sa]`, `bound_service_account_namespaces [tp18]`, `policies [tp18-app]`).

## 3. Partie 3 : External Secrets Operator

```bash
helm repo add external-secrets https://charts.external-secrets.io && helm repo update
helm install external-secrets external-secrets/external-secrets -n external-secrets --create-namespace
kubectl -n external-secrets rollout status deploy/external-secrets-webhook --timeout=600s
kubectl api-resources | grep external-secrets         # version v1

kubectl apply -f manifests/00-app.yaml
kubectl -n tp18 get pods                              # CreateContainerConfigError : le Secret n'existe pas encore

kubectl apply -f manifests/10-secretstore.yaml -f manifests/20-externalsecret.yaml
sleep 20
clear
kubectl -n tp18 get secretstore,externalsecret
kubectl -n tp18 get secret api-credentials -o jsonpath='{.data.api-key}' | base64 -d; echo
kubectl -n tp18 logs deploy/secret-reader --tail=3
```

**Capture `eso-synced.png`** : SecretStore `Valid` / `READY True`, ExternalSecret `SecretSynced` / `READY True`, valeur `v1-initial-value`, et logs du lecteur.

## 4. Partie 4 : rotation

```bash
vault kv put secret/tp18/api api-key=v2-rotated-value
kubectl -n tp18 logs deploy/secret-reader -f          # attendre 1 à 2 minutes, puis Ctrl+C
```

**Capture `rotation.png`** : lignes où `fichier=v2-rotated-value` alors que `env=v1-initial-value`.

Rotation automatique avec Reloader :

```bash
helm repo add stakater https://stakater.github.io/stakater-charts && helm repo update
helm install reloader stakater/reloader -n reloader --create-namespace
kubectl -n tp18 annotate deploy/secret-reader reloader.stakater.com/auto="true"
vault kv put secret/tp18/api api-key=v3-auto-reload
kubectl -n tp18 get pods -w                           # un nouveau Pod remplace l'ancien
kubectl -n tp18 logs deploy/secret-reader --tail=2    # env=v3-auto-reload fichier=v3-auto-reload
```

Retour arrière :

```bash
vault kv rollback -version=1 secret/tp18/api
vault kv metadata get secret/tp18/api                 # current_version 4 (copie de la version 1)
vault kv get secret/tp18/api
```

## 5. Partie 5 : Secrets Manager (Floci)

```bash
docker start floci 2>/dev/null || docker run -d --name floci -p 4566:4566 \
  -v /var/run/docker.sock:/var/run/docker.sock floci/floci
sleep 5
export AWS_PROFILE=floci AWS_PAGER=""
aws secretsmanager create-secret --name tp18/db-password --secret-string 's3cr3t-lab'
aws secretsmanager get-secret-value --secret-id tp18/db-password --query SecretString
# Floci joignable depuis le cluster ? (une ligne "HTTP/1.1 …" suffit, même en erreur 4xx)
kubectl -n tp18 run nettest --rm -it --image=busybox:1.37 --restart=Never -- \
  sh -c 'wget -S -T 3 -O /dev/null http://192.168.190.141:4566/ 2>&1 | head -3'

kubectl -n tp18 create secret generic floci-creds \
  --from-literal=access-key=test --from-literal=secret-access-key=test
helm upgrade external-secrets external-secrets/external-secrets -n external-secrets \
  --reuse-values --set "extraEnv[0].name=AWS_SECRETSMANAGER_ENDPOINT" \
  --set "extraEnv[0].value=http://192.168.190.141:4566"
kubectl -n external-secrets rollout status deploy/external-secrets

kubectl apply -f manifests/30-secretstore-floci.yaml
sleep 20
clear
kubectl -n tp18 get secretstore,externalsecret
kubectl -n tp18 get secret db-credentials -o jsonpath='{.data.password}' | base64 -d; echo
```

**Capture `eso-floci.png`** : ExternalSecret `db-credentials` en `SecretSynced` et la valeur `s3cr3t-lab`.

## 6. Partie 6 : Sealed Secrets

```bash
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets && helm repo update
helm install sealed-secrets sealed-secrets/sealed-secrets -n kube-system
kubectl -n kube-system rollout status deploy/sealed-secrets --timeout=600s

curl -L -o kubeseal.tgz https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.41.2/kubeseal-0.41.2-linux-amd64.tar.gz
tar xzf kubeseal.tgz kubeseal && sudo install -m 755 kubeseal /usr/local/bin/kubeseal && rm kubeseal kubeseal.tgz
kubeseal --version

kubectl -n tp18 create secret generic smtp --from-literal=password='lab-smtp' \
  --dry-run=client -o yaml \
| kubeseal --controller-name sealed-secrets --controller-namespace kube-system -o yaml > smtp-sealed.yaml
clear
cat smtp-sealed.yaml
kubectl apply -f smtp-sealed.yaml
kubectl -n tp18 get sealedsecret,secret smtp
kubectl -n tp18 get secret smtp -o jsonpath='{.data.password}' | base64 -d; echo
```

**Capture `sealed-secret.png`** : `encryptedData.password: AgB…` (illisible) puis le Secret `smtp` créé et déchiffré (`lab-smtp`).

Portée `strict` :

```bash
sed 's/namespace: tp18/namespace: default/' smtp-sealed.yaml > /tmp/smtp-default.yaml
kubectl apply -f /tmp/smtp-default.yaml
sleep 5
kubectl -n default describe sealedsecret smtp | tail -5      # no key could decrypt secret
kubectl -n default get secret smtp                           # NotFound
kubectl -n default delete sealedsecret smtp
```

Sauvegarde de la clé privée du contrôleur (**hors Git**) :

```bash
kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > ~/sealed-secrets-key-BACKUP.yaml
chmod 600 ~/sealed-secrets-key-BACKUP.yaml
```

## 7. Synthèse et défis

Tableau comparatif : [REPONSES.md](REPONSES.md). Défis : [defi/README.md](defi/README.md).

## 8. Nettoyage

```bash
pkill -f "port-forward svc/vault"
kubectl delete ns tp18
helm uninstall vault -n vault; helm uninstall external-secrets -n external-secrets
helm uninstall reloader -n reloader; helm uninstall sealed-secrets -n kube-system
docker stop floci
```
