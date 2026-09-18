"""
setup_btg_auth.py — Autorização BTG (Authorization Code flow)
Rodar UMA VEZ para gerar o refresh token. Depois o sync_btg.py é automático.
"""

import os
import webbrowser
from urllib.parse import urlencode
from dotenv import load_dotenv

load_dotenv()

CLIENT_ID    = os.environ["BTG_CLIENT_ID"]
REDIRECT_URI = "https://xlpcnkjqitdimcpwnkcv.supabase.co/functions/v1/btg-callback"
SCOPE        = "empresas.btgpactual.com/accounts.readonly"
AUTH_URL     = "https://id.btgpactual.com/oauth2/authorize"

params = {
    "response_type": "code",
    "client_id":     CLIENT_ID,
    "redirect_uri":  REDIRECT_URI,
    "scope":         SCOPE,
    "state":         "greenjoy-btg-sync",
}

url = f"{AUTH_URL}?{urlencode(params)}"
print("Abrindo browser para autorização BTG...")
print(f"\nURL: {url}\n")
webbrowser.open(url)
print("Após aprovar no browser, o refresh token será salvo automaticamente no Supabase.")
print("Aguarde a página de confirmação antes de rodar o sync_btg.py.")
