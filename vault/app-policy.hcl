# Policy tp18-app : lecture seule des secrets de l'application.
# Avec le moteur KV v2, les données sont lues sous secret/data/... (et non secret/...).
path "secret/data/tp18/*" {
  capabilities = ["read"]
}

# (Facultatif) lire les métadonnées / versions sans pouvoir modifier :
# path "secret/metadata/tp18/*" {
#   capabilities = ["read", "list"]
# }
