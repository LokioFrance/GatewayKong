# Kong Gateway — API Gateway Lokio

Le **Kong Gateway** est le point d'entrée unique de l'architecture Lokio. Il fait le lien entre l'UI et les microservices (Area, Boxify, Marko) sans que l'UI ait besoin de connaître leurs adresses.

Il gère :
- **L'authentification des utilisateurs** : validation des tokens JWT émis par le service Area
- **L'authentification vers les microservices** : injection automatique d'un token de service sur chaque requête forwardée
- **Le renouvellement des tokens** : un token-manager renouvelle les tokens de service avant leur expiration
- **La protection globale** : toute route non-publique est bloquée sans JWT utilisateur valide

---

## Architecture

```
UI (browser)
  │  POST /auth/token   →  login (public)
  │  Authorization: Bearer <JWT utilisateur>
  ▼
Kong Gateway :8000
  ├── /auth/token         →  area:/api/token/        (public)
  ├── /auth/token/refresh →  area:/api/token/refresh/ (public)
  ├── /api/areas/*        →  area:8001               (JWT requis)
  ├── /api/sub-areas/*    →  area:8001               (JWT requis)
  ├── /api/items/*        →  boxify:8002             (JWT requis)
  ├── /api/item-infos/*   →  boxify:8002             (JWT requis)
  ├── /api/objects/*      →  boxify:8002             (JWT requis)
  ├── /api/identifiers/*  →  marko:8003              (JWT requis)
  └── /api/typeids/*      →  marko:8003              (JWT requis)
```

**Token Manager** (container Python) :
- S'authentifie au démarrage sur chaque microservice avec le compte `gateway`
- Écrit les tokens dans un volume partagé (`/tokens/<service>.token`)
- Rafraîchit automatiquement les tokens avant leur expiration

**Plugin Lua global (pre-function)** :
- Bypass les routes `/auth/*`
- Valide le JWT utilisateur (signé par Area avec `DJANGO_SECRET_KEY`)
- Remplace le header `Authorization` par le token du compte de service
- Transmet `X-User-Id` au microservice pour traçabilité

---

## Stack

| Composant | Version |
|---|---|
| Kong | 3.9 |
| Python (token-manager) | 3.12 |
| requests | 2.32.3 |

---

## Déploiement

**Prérequis :**
- Docker et Docker Compose installés
- Les microservices Area, Boxify et Marko sont démarrés
- Un compte `gateway` existe sur chaque microservice (voir ci-dessous)

```bash
./deploy.sh
```

Le script `deploy.sh` fait tout automatiquement :

1. Vérifie que Docker est disponible
2. Crée le `.env` depuis `.env.example` si absent et ouvre l'éditeur
3. Valide que `AREA_JWT_SECRET` est bien défini
4. Détecte l'IP interne du bridge Docker (pour joindre les microservices depuis les containers)
5. Vérifie l'accessibilité et l'authentification sur chaque microservice
6. Génère `kong.yml` depuis le template
7. Build et démarre le token-manager, attend qu'il obtienne les tokens
8. Démarre Kong, attend qu'il soit sain
9. Affiche les URLs et exemples d'utilisation

Pour arrêter :

```bash
docker compose down
```

---

## Prérequis — Compte de service `gateway`

Le token-manager s'authentifie sur chaque microservice avec un compte `gateway`.

**Ce compte est créé automatiquement par le `deploy.sh` de chaque microservice** si `GATEWAY_SERVICE_PASSWORD` est défini dans son `.env`.

Pour le créer manuellement si besoin :

```bash
# Sur chaque microservice
docker exec area python manage.py shell -c \
  "from django.contrib.auth.models import User; User.objects.create_user('gateway', password='<mot_de_passe>')"

docker exec boxify python manage.py shell -c \
  "from django.contrib.auth.models import User; User.objects.create_user('gateway', password='<mot_de_passe>')"

docker exec marko python manage.py shell -c \
  "from django.contrib.auth.models import User; User.objects.create_user('gateway', password='<mot_de_passe>')"
```

---

## Variables d'environnement

Copier `.env.example` en `.env` et remplir les valeurs. Ne jamais committer `.env`.

| Variable | Description |
|---|---|
| `KONG_PROXY_PORT` | Port externe du proxy Kong (défaut : `8000`) |
| `KONG_ADMIN_PORT` | Port externe de l'admin Kong (défaut : `8900`) |
| `AREA_JWT_SECRET` | Doit correspondre au `DJANGO_SECRET_KEY` du service Area |
| `AREA_UPSTREAM` | URL de Area depuis l'hôte (ex : `http://localhost:8001`) |
| `BOXIFY_UPSTREAM` | URL de Boxify depuis l'hôte (ex : `http://localhost:8002`) |
| `MARKO_UPSTREAM` | URL de Marko depuis l'hôte (ex : `http://localhost:8003`) |
| `AREA_SERVICE_USERNAME` | Nom du compte de service sur Area (défaut : `gateway`) |
| `AREA_SERVICE_PASSWORD` | Mot de passe du compte de service sur Area |
| `BOXIFY_SERVICE_USERNAME` | Nom du compte de service sur Boxify (défaut : `gateway`) |
| `BOXIFY_SERVICE_PASSWORD` | Mot de passe du compte de service sur Boxify |
| `MARKO_SERVICE_USERNAME` | Nom du compte de service sur Marko (défaut : `gateway`) |
| `MARKO_SERVICE_PASSWORD` | Mot de passe du compte de service sur Marko |
| `TOKEN_REFRESH_INTERVAL` | Intervalle de rafraîchissement en secondes (défaut : `3300`) |

> **Important** : `AREA_JWT_SECRET` doit être identique au `DJANGO_SECRET_KEY` présent dans `area/.env`. C'est la clé utilisée par Kong pour valider les tokens JWT émis par Area lors du login.

---

## Endpoints

### Authentification (publics, pas de JWT requis)

| Méthode | URL | Description |
|---|---|---|
| `POST` | `/auth/token` | Login — retourne `{access, refresh}` |
| `POST` | `/auth/token/refresh` | Rafraîchit l'access token avec le refresh token |

### Area (JWT requis)

| Méthode | URL |
|---|---|
| `GET/POST` | `/api/areas/` |
| `GET/PUT/PATCH/DELETE` | `/api/areas/{id}/` |
| `GET/POST` | `/api/sub-areas/` |
| `GET/PUT/PATCH/DELETE` | `/api/sub-areas/{id}/` |

### Boxify (JWT requis)

| Méthode | URL |
|---|---|
| `GET/POST` | `/api/items/` |
| `GET/PUT/PATCH/DELETE` | `/api/items/{id}/` |
| `GET/POST` | `/api/item-infos/` |
| `GET/POST` | `/api/objects/` |

### Marko (JWT requis)

| Méthode | URL |
|---|---|
| `GET/POST` | `/api/identifiers/` |
| `GET/POST` | `/api/typeids/` |

---

## Utilisation

```bash
# 1. Se connecter (remplacer les credentials)
TOKEN=$(curl -s -X POST http://localhost:8000/auth/token \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"<mot_de_passe>"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access'])")

# 2. Appeler un microservice
curl -H "Authorization: Bearer $TOKEN" http://localhost:8000/api/areas/

# 3. Rafraîchir le token
NEW_TOKEN=$(curl -s -X POST http://localhost:8000/auth/token/refresh \
  -H "Content-Type: application/json" \
  -d '{"refresh":"<refresh_token>"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access'])")
```

---

## Commandes utiles

```bash
# Logs Kong
docker compose logs -f kong

# Logs token-manager
docker compose logs -f token-manager

# Vérifier les routes chargées
curl http://localhost:8900/routes

# Vérifier les plugins actifs
curl http://localhost:8900/plugins

# Vérifier les tokens de service
docker compose exec token-manager ls -la /tokens/

# Statut Kong
curl http://localhost:8900/status
```

---

## Auteur

Projet **Lokio** — développé par **Clément Chermeux**.
