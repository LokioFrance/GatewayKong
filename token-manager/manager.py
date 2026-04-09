#!/usr/bin/env python3
"""
Token Manager — Lokio Kong Gateway

Gère les tokens JWT des comptes de service pour chaque microservice.
- Obtient un token au démarrage (avec retry)
- Écrit les tokens dans /tokens/<service>.token (volume partagé avec Kong)
- Rafraîchit automatiquement avant l'expiration (toutes les REFRESH_INTERVAL sec)
"""
import os
import time
import logging
import requests

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger(__name__)

TOKEN_DIR = "/tokens"
REFRESH_INTERVAL = int(os.environ.get("REFRESH_INTERVAL", "240"))

SERVICES = {
    "area": {
        "base_url": os.environ.get("AREA_URL", "http://host.docker.internal:8001"),
        "username": os.environ.get("AREA_SERVICE_USERNAME", ""),
        "password": os.environ.get("AREA_SERVICE_PASSWORD", ""),
        "token_file": f"{TOKEN_DIR}/area.token",
    },
    "boxify": {
        "base_url": os.environ.get("BOXIFY_URL", "http://host.docker.internal:8002"),
        "username": os.environ.get("BOXIFY_SERVICE_USERNAME", ""),
        "password": os.environ.get("BOXIFY_SERVICE_PASSWORD", ""),
        "token_file": f"{TOKEN_DIR}/boxify.token",
    },
    "marko": {
        "base_url": os.environ.get("MARKO_URL", "http://host.docker.internal:8003"),
        "username": os.environ.get("MARKO_SERVICE_USERNAME", ""),
        "password": os.environ.get("MARKO_SERVICE_PASSWORD", ""),
        "token_file": f"{TOKEN_DIR}/marko.token",
    },
}


# En-tête Host fixé à "localhost" pour passer le ALLOWED_HOSTS Django
# (les microservices acceptent "localhost" mais pas l'IP interne Docker)
_HEADERS = {"Host": "localhost"}


def get_tokens(service: dict) -> tuple[str, str]:
    """Authentifie avec username/password, retourne (access, refresh)."""
    url = f"{service['base_url']}/api/token/"
    resp = requests.post(
        url,
        json={"username": service["username"], "password": service["password"]},
        headers=_HEADERS,
        timeout=10,
    )
    resp.raise_for_status()
    data = resp.json()
    return data["access"], data["refresh"]


def refresh_access_token(service: dict, refresh: str) -> str:
    """Utilise le refresh token pour obtenir un nouvel access token."""
    url = f"{service['base_url']}/api/token/refresh/"
    resp = requests.post(url, json={"refresh": refresh}, headers=_HEADERS, timeout=10)
    resp.raise_for_status()
    return resp.json()["access"]


def write_token(path: str, token: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(token.strip())


def acquire_initial_token(name: str, service: dict, refresh_tokens: dict) -> None:
    """Tentatives d'acquisition initiale (retry x5 avec délai)."""
    for attempt in range(1, 6):
        try:
            access, refresh = get_tokens(service)
            refresh_tokens[name] = refresh
            write_token(service["token_file"], access)
            log.info("[%s] Token initial obtenu.", name)
            return
        except Exception as exc:
            log.error("[%s] Tentative %d/5 échouée : %s", name, attempt, exc)
            if attempt < 5:
                time.sleep(10)
    log.error(
        "[%s] Impossible d'obtenir un token. Vérifiez que le compte '%s' existe sur ce microservice.",
        name,
        service["username"],
    )
    log.error(
        "[%s] Pour créer le compte : docker exec <container_%s> python manage.py shell -c "
        "\"from django.contrib.auth.models import User; "
        "User.objects.create_user('%s', password='<mot_de_passe>')\"",
        name, name, service["username"],
    )


def main() -> None:
    os.makedirs(TOKEN_DIR, exist_ok=True)
    refresh_tokens: dict[str, str] = {}

    log.info("=== Token Manager démarré (refresh toutes les %ds) ===", REFRESH_INTERVAL)

    # Acquisition initiale
    for name, service in SERVICES.items():
        if not service["username"] or not service["password"]:
            log.warning("[%s] Credentials manquants (AREA/BOXIFY/MARKO_SERVICE_USERNAME/PASSWORD) — ignoré.", name)
            continue
        acquire_initial_token(name, service, refresh_tokens)

    if not refresh_tokens:
        log.error("Aucun token obtenu. Vérifiez vos credentials dans .env et que les microservices sont démarrés.")

    log.info("Token manager opérationnel.")

    # Boucle de rafraîchissement
    while True:
        time.sleep(REFRESH_INTERVAL)
        log.info("Rafraîchissement des tokens...")
        for name, service in SERVICES.items():
            if not service["username"] or not service["password"]:
                continue
            try:
                if name in refresh_tokens:
                    access = refresh_access_token(service, refresh_tokens[name])
                    write_token(service["token_file"], access)
                    log.info("[%s] Token rafraîchi.", name)
                else:
                    # Pas de refresh token → ré-authentification complète
                    access, refresh = get_tokens(service)
                    refresh_tokens[name] = refresh
                    write_token(service["token_file"], access)
                    log.info("[%s] Token ré-obtenu.", name)
            except Exception as exc:
                log.error("[%s] Échec du refresh : %s — nouvelle tentative au prochain cycle.", name, exc)
                # Supprime le refresh token invalide pour forcer une ré-auth complète
                refresh_tokens.pop(name, None)


if __name__ == "__main__":
    main()
