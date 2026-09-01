import os
import sys
import servicemanager
import win32event
import win32service
import win32serviceutil

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
if BASE_DIR not in sys.path:
    sys.path.insert(0, BASE_DIR)
from agente_crm import criar_servidor


class AgenteCrmService(win32serviceutil.ServiceFramework):
    _svc_name_ = "AgenteCRM"
    _svc_display_name_ = "Agente de Monitoramento CRM"
    _svc_description_ = "Monitora o CRM com configuracao DPAPI, controle de acesso e rate limit."

    def __init__(self, args):
        super().__init__(args)
        self.stop_event = win32event.CreateEvent(None, 0, 0, None)
        self.servidor = None

    def SvcStop(self):
        self.ReportServiceStatus(win32service.SERVICE_STOP_PENDING)
        if self.servidor:
            self.servidor.shutdown()
        win32event.SetEvent(self.stop_event)

    def SvcDoRun(self):
        servicemanager.LogInfoMsg("AgenteCRM iniciado")
        try:
            self.servidor = criar_servidor()
            self.servidor.serve_forever(0.5)
        except Exception as erro:
            servicemanager.LogErrorMsg(f"Falha no AgenteCRM: {erro}")
            raise
        finally:
            if self.servidor:
                self.servidor.server_close()
            servicemanager.LogInfoMsg("AgenteCRM finalizado")


if __name__ == "__main__":
    win32serviceutil.HandleCommandLine(AgenteCrmService)
