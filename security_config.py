import base64
import hashlib
import hmac
import ipaddress
import json
import os
import subprocess
import tempfile

import win32crypt


BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.getenv(
    "AGENTE_CRM_SECURITY_CONFIG",
    os.path.join(BASE_DIR, ".security_config.dpapi"),
)
ITERACOES_TOKEN = 310_000
CRYPTPROTECT_LOCAL_MACHINE = 0x4


def _restringir_acl(caminho):
    subprocess.run(
        [
            "icacls", caminho, "/inheritance:r", "/grant:r",
            "SYSTEM:(F)", "Administrators:(F)",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
        timeout=15,
    )


def configuracao_padrao():
    return {
        "allowed_ips": [],
        "require_token": False,
        "token_salt": "",
        "token_hash": "",
        "token_iterations": ITERACOES_TOKEN,
    }


def carregar_configuracao():
    if not os.path.isfile(CONFIG_PATH):
        return configuracao_padrao()
    with open(CONFIG_PATH, "rb") as arquivo:
        protegido = arquivo.read()
    if not protegido:
        raise ValueError("Configuracao de seguranca protegida vazia.")
    _, aberto = win32crypt.CryptUnprotectData(protegido, None, None, None, 0)
    dados = json.loads(aberto.decode("utf-8"))
    config = configuracao_padrao()
    config.update(dados if isinstance(dados, dict) else {})
    config["allowed_ips"] = [str(ipaddress.ip_address(item)) for item in config["allowed_ips"]]
    return config


def salvar_configuracao(allowed_ips=None, token="", require_token=False):
    ips = []
    for item in allowed_ips or []:
        endereco = ipaddress.ip_address(str(item).strip())
        if not (endereco.is_private or endereco.is_loopback):
            raise ValueError(f"IP autorizado precisa ser privado ou loopback: {endereco}")
        ips.append(str(endereco))

    config = configuracao_padrao()
    config["allowed_ips"] = sorted(set(ips))
    config["require_token"] = bool(require_token)
    if config["require_token"]:
        if len(token) < 20:
            raise ValueError("O token precisa ter pelo menos 20 caracteres.")
        salt = os.urandom(32)
        digest = hashlib.pbkdf2_hmac(
            "sha256", token.encode("utf-8"), salt, ITERACOES_TOKEN
        )
        config["token_salt"] = base64.b64encode(salt).decode("ascii")
        config["token_hash"] = base64.b64encode(digest).decode("ascii")

    aberto = json.dumps(config, separators=(",", ":")).encode("utf-8")
    protegido = win32crypt.CryptProtectData(
        aberto,
        "Agente CRM - configuracao de seguranca",
        None,
        None,
        None,
        CRYPTPROTECT_LOCAL_MACHINE,
    )
    os.makedirs(os.path.dirname(CONFIG_PATH) or BASE_DIR, exist_ok=True)
    descritor, temporario = tempfile.mkstemp(
        prefix=".security_config.", suffix=".tmp", dir=os.path.dirname(CONFIG_PATH) or BASE_DIR
    )
    try:
        with os.fdopen(descritor, "wb") as arquivo:
            arquivo.write(protegido)
            arquivo.flush()
            os.fsync(arquivo.fileno())
        os.replace(temporario, CONFIG_PATH)
        _restringir_acl(CONFIG_PATH)
    finally:
        if os.path.exists(temporario):
            os.remove(temporario)


def validar_token(config, token):
    if not config.get("require_token"):
        return True
    try:
        salt = base64.b64decode(config["token_salt"], validate=True)
        esperado = base64.b64decode(config["token_hash"], validate=True)
        iteracoes = int(config.get("token_iterations", ITERACOES_TOKEN))
        recebido = hashlib.pbkdf2_hmac(
            "sha256", str(token or "").encode("utf-8"), salt, iteracoes
        )
        return hmac.compare_digest(recebido, esperado)
    except (KeyError, TypeError, ValueError):
        return False
