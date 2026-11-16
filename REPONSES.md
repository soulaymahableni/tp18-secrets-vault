# TP18 : réponses aux questions

## Pourquoi un Secret Kubernetes ne suffit pas

* Un Secret est seulement **encodé en base64**, pas chiffré : toute personne qui peut faire `get secret` dans le namespace (ou lire etcd / la base SQLite de K3s, ou une sauvegarde) lit les valeurs.
* Il ne peut pas être **versionné dans Git** : le dépôt contiendrait le secret en clair, pour toujours (historique).
* Pas de **source de vérité** centrale, pas d'**audit** de qui lit quoi, et pas de **rotation** : il faut modifier chaque cluster à la main.

## Partie 1 : Vault

* **Mode dev** : stockage en mémoire, Vault déjà **déverrouillé** (unsealed), jeton root `root`, HTTP sans TLS. Tout est perdu au redémarrage du Pod. Uniquement pour un lab.
* En production : Vault démarre **scellé** (ses données sont chiffrées par une clé maître). Il faut le déverrouiller avec plusieurs **clés Shamir** (par exemple 3 sur 5, détenues par des personnes différentes) ou par **auto-unseal** (KMS cloud, HSM). Stockage persistant et répliqué (**Raft** intégré), TLS, et le jeton root est révoqué après l'initialisation.
* **KV v2** conserve les **versions** : `vault kv metadata get` liste chaque version (date de création, suppression, destruction) et `current_version`.

## Partie 2 : policy et authentification Kubernetes

* `app-policy.hcl` : `read` sur `secret/data/tp18/*`. Avec KV v2, la lecture passe par le préfixe `data/` (les versions par `metadata/`). Aucun droit d'écriture ni de liste : **moindre privilège**.
* **Méthode d'authentification Kubernetes** : le Pod (ici ESO, au nom de `app-sa`) envoie à Vault le **jeton JWT de son ServiceAccount**. Vault le fait valider par l'API Kubernetes (**TokenReview**), avec les droits `system:auth-delegator` installés par le chart. Puis il vérifie le **nom du SA et son namespace** avant de délivrer un jeton Vault portant la policy `tp18-app`, valable 1 h.
* **Qui peut obtenir un jeton avec ce rôle ?** Uniquement un Pod qui s'exécute avec le ServiceAccount **`app-sa` dans le namespace `tp18`**.
* **Pod d'un autre namespace** (ou autre SA) : le jeton est valide pour Kubernetes, mais ne correspond pas à `bound_service_account_names` / `bound_service_account_namespaces`, et Vault refuse le login (`permission denied` / `service account name not authorized`). Aucun mot de passe n'est stocké dans le Pod : l'identité Kubernetes **est** l'authentifiant.

## Partie 3 : External Secrets Operator

* **SecretStore** = *comment* se connecter au fournisseur (Vault, KV v2, rôle `tp18-app`, SA `app-sa`). **ExternalSecret** = *quoi* synchroniser (`tp18/api`, propriété `api-key`) et *vers quel* Secret (`api-credentials`), à quelle fréquence (`refreshInterval`).
* Le Pod `secret-reader` reste en `CreateContainerConfigError` tant que le Secret n'existe pas. Dès qu'ESO l'a créé (`SecretSynced`), il démarre.
* L'application ne connaît pas Vault : elle lit un Secret Kubernetes classique. Vault reste la **source de vérité**.
* Version d'API : `external-secrets.io/v1` (ESO 2.x) ; `v1beta1` reste servie pour la compatibilité.

## Partie 4 : rotation

* Après `vault kv put … v2-rotated-value`, ESO met à jour le Secret au prochain `refreshInterval` (15 s).
* Le **fichier monté** (`/etc/secret/api-key`) affiche la nouvelle valeur au bout d'environ une minute : le kubelet resynchronise périodiquement les volumes Secret, par un lien symbolique remplacé de façon atomique.
* La **variable d'environnement** garde `v1-initial-value` : elle est copiée **une seule fois, au démarrage du conteneur**. Il faut recréer le Pod.
* Automatisation : `kubectl rollout restart` lancé par la CI après la rotation, ou **Reloader** (`reloader.stakater.com/auto: "true"`), qui surveille les Secrets et ConfigMaps référencés et déclenche un rolling update dès qu'ils changent. (Les applications qui relisent le fichier n'ont même pas besoin de redémarrer.)
* **Rollback** : `vault kv rollback -version=1` ne supprime rien. Il crée une **nouvelle version** (4) dont le contenu est celui de la version 1. `metadata get` montre `current_version 4` et l'historique complet (1, 2, 3, 4), comme un `git revert`.

## Partie 5 : Secrets Manager (Floci)

* Le même ExternalSecret fonctionne avec une autre source : seul le SecretStore change (`provider.aws`, `service: SecretsManager`, `region`, identifiants dans `floci-creds`).
* `AWS_SECRETSMANAGER_ENDPOINT` (variable du contrôleur ESO) redirige les appels vers Floci (`http://192.168.190.141:4566`), comme `--endpoint-url` pour la CLI AWS. Le cluster joint Floci par l'IP de la VM, car `localhost` dans un Pod désigne le Pod lui-même.
* En vrai AWS, on n'utiliserait pas de clés statiques mais **IRSA / Pod Identity** (rôle IAM associé au ServiceAccount).

## Partie 6 : Sealed Secrets

* `kubeseal` chiffre le Secret avec la **clé publique** du contrôleur. Seul le contrôleur, qui détient la **clé privée**, peut le déchiffrer et créer le Secret dans le cluster. Le fichier `smtp-sealed.yaml` peut donc être **commité** dans Git.
* **Portée `strict`** (par défaut) : le nom **et le namespace** font partie des données chiffrées (ils sont liés au chiffrement). Copié dans `default`, le SealedSecret ne correspond plus à ce qui a été chiffré : `no key could decrypt secret`, et le Secret n'est pas créé. Cela empêche un utilisateur de « déplacer » un secret vers un namespace où il pourrait le lire. (Les portées `namespace-wide` et `cluster-wide` assouplissent cette règle.)
* **Clé privée perdue** (cluster reconstruit, namespace supprimé) : tous les SealedSecrets du dépôt deviennent **indéchiffrables**, et il faut recréer chaque secret à partir de sa valeur d'origine.
* **Sauvegarde** : exporter les Secrets `sealedsecrets.bitnami.com/sealed-secrets-key` de `kube-system` (`kubectl get secret -l … -o yaml`) et les conserver **hors de Git**, dans un coffre (Vault, gestionnaire de mots de passe, stockage chiffré). Le contrôleur renouvelle sa clé tous les 30 jours en gardant les anciennes : il faut sauvegarder régulièrement.

## Partie 7 : synthèse

| Critère | Secret Kubernetes | Sealed Secrets | Vault + ESO |
|---|---|---|---|
| Versionnable dans Git | **Non** (base64 = clair) | **Oui** (chiffré, lié au namespace) | **Oui** pour les manifests (SecretStore, ExternalSecret) ; la valeur n'est jamais dans Git |
| Source de vérité | le cluster (etcd / SQLite) | le dépôt Git (+ clé privée du contrôleur) | **Vault** (ou le gestionnaire cloud), central pour tous les clusters |
| Rotation | manuelle, cluster par cluster | re-chiffrer, commiter, déployer | dans Vault : propagée automatiquement (`refreshInterval`), avec Reloader pour les Pods |
| Audit des accès | audit Kubernetes seulement (souvent désactivé) | aucun sur la valeur (seulement l'historique Git) | **complet** : audit device Vault (qui, quoi, quand), policies fines |
| Complexité d'exploitation | **faible** | **faible à moyenne** (sauvegarde de la clé) | **élevée** (Vault en HA, unseal, sauvegardes, ESO) |
| Adapté à GitOps | non | **oui**, conçu pour | **oui** (Git décrit *quoi* synchroniser, pas la valeur) |

**En résumé** : Sealed Secrets pour une petite équipe en GitOps sans infrastructure de secrets ; Vault (ou un gestionnaire cloud) + ESO dès qu'il faut une source de vérité centrale, l'audit, la rotation et des secrets dynamiques. Dans tous les cas, activer le chiffrement des Secrets au repos dans le cluster.
