import json
import ipaddress
import logging
import os
import socket
import sys
import time
from collections import defaultdict, deque
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from logging.handlers import RotatingFileHandler
from threading import Lock

import psutil
from security_config import carregar_configuracao, salvar_configuracao, validar_token

PORTA = int(os.getenv("AGENTE_CRM_PORTA", "5003"))
PROCESSO = "crm_messok.exe"
VERSAO = "2.0.0-seguro"
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_SEGURANCA = carregar_configuracao()
RATE_LIMIT_JANELA = 60
RATE_LIMIT_MAXIMO = 120
RATE_LIMIT = defaultdict(deque)
RATE_LIMIT_LOCK = Lock()
IPS_SEM_MONITORAMENTO_PROCESSO = {
    "192.168.96.162",
    "192.168.96.150",
    "192.168.96.67",
    "192.168.96.66",
}

logger = logging.getLogger("agente_crm")
if not logger.handlers:
    logger.setLevel(logging.INFO)
    handler_log = RotatingFileHandler(
        os.path.join(BASE_DIR, "agente_crm.log"),
        maxBytes=1024 * 1024,
        backupCount=2,
        encoding="utf-8",
    )
    handler_log.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(message)s"))
    logger.addHandler(handler_log)


def requisicao_permitida(ip_cliente):
    try:
        endereco = ipaddress.ip_address(ip_cliente)
    except ValueError:
        return False, "origem_invalida"
    if not (endereco.is_private or endereco.is_loopback):
        return False, "origem_nao_privada"
    permitidos = set(CONFIG_SEGURANCA.get("allowed_ips") or [])
    if permitidos and str(endereco) not in permitidos and not endereco.is_loopback:
        return False, "origem_nao_autorizada"

    agora = time.monotonic()
    with RATE_LIMIT_LOCK:
        eventos = RATE_LIMIT[str(endereco)]
        while eventos and agora - eventos[0] > RATE_LIMIT_JANELA:
            eventos.popleft()
        if len(eventos) >= RATE_LIMIT_MAXIMO:
            return False, "limite_excedido"
        eventos.append(agora)
    return True, ""


def data_hora(timestamp=None):
    valor = datetime.fromtimestamp(timestamp) if timestamp else datetime.now()
    return valor.strftime("%d/%m/%Y %H:%M:%S")


def instancias_processo():
    total = 0
    for processo in psutil.process_iter(["name"]):
        try:
            if str(processo.info.get("name") or "").lower() == PROCESSO.lower():
                total += 1
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue
    return total


def ips_ipv4_locais():
    ips = set()
    for enderecos in psutil.net_if_addrs().values():
        for endereco in enderecos:
            if endereco.family == socket.AF_INET and endereco.address:
                ips.add(str(endereco.address).strip())
    return ips


def consultar_status():
    boot = psutil.boot_time()
    disco = psutil.disk_usage("C:\\")
    ips_locais = ips_ipv4_locais()
    processo_monitorado = not bool(ips_locais & IPS_SEM_MONITORAMENTO_PROCESSO)
    instancias = instancias_processo() if processo_monitorado else 0
    return {
        "agente": "crm",
        "versao": VERSAO,
        "hostname": socket.gethostname(),
        "verificado_em": data_hora(),
        "ultimo_reinicio": data_hora(boot),
        "uptime_segundos": max(0, int(datetime.now().timestamp() - boot)),
        "cpu_percentual": round(psutil.cpu_percent(interval=0.35), 1),
        "memoria_percentual": round(psutil.virtual_memory().percent, 1),
        "disco_c_percentual": round(disco.percent, 1),
        "disco_c_livre_gb": round(disco.free / (1024 ** 3), 2),
        "ips_locais": sorted(ips_locais),
        "processo": {
            "executavel": PROCESSO,
            "monitorado": processo_monitorado,
            "status": ("online" if instancias else "offline") if processo_monitorado else "nao_monitorado",
            "instancias": instancias,
        },
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "AgenteCRM"
    sys_version = ""

    def responder(self, dados, status=200):
        corpo = json.dumps(dados, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Pragma", "no-cache")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", "default-src 'none'")
        self.send_header("Content-Length", str(len(corpo)))
        self.end_headers()
        self.wfile.write(corpo)

    def autorizar(self):
        permitido, motivo = requisicao_permitida(self.client_address[0])
        if not permitido:
            logger.warning("Requisicao bloqueada de %s: %s", self.client_address[0], motivo)
            self.responder({"erro": "acesso_negado"}, 429 if motivo == "limite_excedido" else 403)
            return False
        if not validar_token(CONFIG_SEGURANCA, self.headers.get("X-Agente-Token", "")):
            logger.warning("Token invalido recebido de %s", self.client_address[0])
            self.responder({"erro": "nao_autorizado"}, 401)
            return False
        return True

    def do_GET(self):
        if not self.autorizar():
            return

        caminho = self.path.split("?", 1)[0].rstrip("/") or "/"
        if caminho == "/health":
            self.responder({"status": "ok", "agente": "crm", "versao": VERSAO})
        elif caminho == "/status":
            try:
                self.responder(consultar_status())
            except Exception:
                logger.exception("Falha ao consultar o status")
                self.responder({"erro": "falha_interna"}, 500)
        else:
            self.responder({"erro": "rota_nao_encontrada"}, 404)

    def do_POST(self):
        if not self.autorizar():
            return
        self.responder({"erro": "metodo_nao_permitido"}, 405)

    do_PUT = do_POST
    do_DELETE = do_POST
    do_PATCH = do_POST

    def log_message(self, formato, *args):
        return


def criar_servidor(host="0.0.0.0", porta=PORTA):
    servidor = ThreadingHTTPServer((host, porta), Handler)
    servidor.daemon_threads = True
    servidor.request_queue_size = 32
    return servidor


if __name__ == "__main__":
    if "--configure-security-stdin" in sys.argv:
        payload = json.loads(sys.stdin.read(64 * 1024))
        salvar_configuracao(
            allowed_ips=payload.get("allowed_ips", []),
            token=str(payload.get("token", "")),
            require_token=bool(payload.get("require_token", False)),
        )
        print("Configuracao de seguranca protegida com DPAPI.")
        raise SystemExit(0)
    servidor = criar_servidor()
    try:
        servidor.serve_forever(0.5)
    except KeyboardInterrupt:
        servidor.server_close()
