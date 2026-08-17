"""
Bridge entre o Claude Code e o mascote no ESP32-S3.

Recebe eventos de hook do Claude Code, deriva um estado, e serve esse estado
para a placa via HTTP.

Só stdlib — nada pra instalar.

Endpoints
    POST /hook    <- Claude Code manda os eventos aqui
    GET  /state   <- a placa busca o estado aqui (payload enxuto)
    GET  /health  <- liveness
    GET  /debug   <- estado completo, pra inspeção humana

Uso:
    python3 bridge/server.py [porta]
"""


# Anotacoes preguicosas: deixa o modulo rodar no Python 3.9 do sistema
# (/usr/bin/python3), que nunca muda e nao depende do asdf. Sem isto,
# `str | None` e avaliado na definicao da funcao e explode no 3.9.
from __future__ import annotations

import json
import os
import secrets
import signal
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, str(__import__("pathlib").Path(__file__).parent))
import usage    # noqa: E402
import limits   # noqa: E402
import weather  # noqa: E402
import anuncio  # noqa: E402
import config   # noqa: E402
import janelas  # noqa: E402

PORT = 4666

# Quanto tempo o estado "done" fica visível antes de virar ocioso.
DONE_LINGER_S = 8.0
# De quanto em quanto tempo recalcula o consumo (varredura incremental).
USAGE_REFRESH_S = 60.0
# Sem nenhum evento por esse tempo, consideramos o Claude ocioso.
STALE_AFTER_S = 180.0
# Ocioso por mais que isso: a placa troca o mascote por relogio + tempo.
# Boneco parado nao informa nada; hora e temperatura sim.
REPOUSO_S = 120

# Estados do mascote. A placa recebe só a string.
IDLE = "idle"            # parado, respirando
WORKING = "working"      # processando
TOOL = "tool"            # rodando ferramenta
ASKING = "asking"        # fez uma pergunta, travado esperando sua resposta
WAITING = "waiting"      # esperando permissão pra agir
DONE = "done"            # acabou de concluir
ERROR = "error"          # falhou

# Ferramentas que significam "o Claude parou e a bola está com você".
# AskUserQuestion: pergunta com alternativas. ExitPlanMode: plano pra aprovar.
BLOCKING_TOOLS = {"AskUserQuestion", "ExitPlanMode"}


def _question_label(tool: str, tool_input) -> str:
    """
    Extrai um rótulo curto do que está sendo perguntado.

    AskUserQuestion traz questions[].header, que já vem com ~12 chars no máximo
    porque é desenhado pra virar chip na UI — cai perfeito numa tela de 480px.
    """
    if tool == "ExitPlanMode":
        return "approve plan"
    qs = (tool_input or {}).get("questions") or []
    if not qs:
        return "question"
    first = qs[0] if isinstance(qs[0], dict) else {}
    label = first.get("header") or first.get("question") or "question"
    if len(qs) > 1:
        label = f"{label} +{len(qs) - 1}"
    return label


# Quantas sessoes a placa consegue mostrar de uma vez. Acima disso os
# mascotes ficariam pequenos demais para dizer qualquer coisa.
MAX_SESSOES = 4
# Uma sessao so aparece na tela enquanto esta ATIVA. Parou de iterar por
# esse tempo, some — sessao aberta e esquecida nao e informacao, e poluicao.
SESSAO_ATIVA_S = 30
# Depois disso descartamos da memoria: o terminal provavelmente morreu sem
# disparar SessionEnd (fechou a aba, caiu o ssh).
SESSAO_MORTA_S = 3 * 3600


def _sessao_nova() -> dict:
    return {"status": IDLE, "detail": "", "model": "", "project": "",
            "last_event": 0.0, "done_at": 0.0}


class State:
    def __init__(self):
        self.lock = threading.Lock()
        # session_id -> dict. Antes havia um estado global so; o session_id
        # vinha em todo hook e era ignorado. Agora e a chave.
        self.sessoes = {}
        self.events_seen = 0
        self.usage = {}
        self.usage_at = 0.0
        # Consumo nas janelas de 5h e 7 dias, calculado dos transcripts.
        # Existe porque o cache de limites do Claude Code pode ficar velho
        # (visto: 3 dias) e nao ha caminho local para forca-lo a atualizar.
        self.janelas = {}
        # Limites buscados AO VIVO pelo app da barra, que tem acesso proprio
        # ao chaveiro. Tem precedencia sobre o cache em disco do Claude Code,
        # que so e reescrito quando algo dispara a busca — visto parado 3 dias.
        self.limites_vivos = None
        self.limites_vivos_at = 0.0
        # Quem foi o ultimo cliente NAO-local a buscar /state, e quando.
        # E assim que sabemos se a placa esta viva: ela e a unica coisa que
        # busca de fora. O app da barra le isso pra mostrar o vinculo.
        self.placa_ip = ""
        self.placa_at = 0.0
        self.subiu_em = time.time()

    def apply(self, payload: dict) -> None:
        """Traduz um evento de hook do Claude Code em estado do mascote."""
        ev = payload.get("hook_event_name") or ""
        now = time.time()

        sid = payload.get("session_id") or "?"

        with self.lock:
            self.events_seen += 1
            ss = self.sessoes.setdefault(sid, _sessao_nova())
            ss["last_event"] = now

            if cwd := payload.get("cwd"):
                ss["project"] = cwd.rstrip("/").split("/")[-1]
            if model := (payload.get("model") or {}).get("id"):
                ss["model"] = model

            if ev == "SessionEnd":
                # A sessao acabou de verdade: some da tela em vez de virar
                # um mascote ocioso fantasma.
                self.sessoes.pop(sid, None)
                return

            if ev == "UserPromptSubmit":
                ss["status"], ss["detail"] = WORKING, "thinking"
            elif ev == "PreToolUse":
                tool = payload.get("tool_name") or "tool"
                if tool in BLOCKING_TOOLS:
                    # O Claude não está trabalhando: está travado esperando você.
                    ss["status"] = ASKING
                    ss["detail"] = _question_label(tool, payload.get("tool_input"))
                else:
                    ss["status"], ss["detail"] = TOOL, tool
            elif ev == "PostToolUse":
                ss["status"], ss["detail"] = WORKING, "processing"
            elif ev == "PostToolUseFailure":
                ss["status"] = ERROR
                ss["detail"] = payload.get("tool_name") or "failed"
            elif ev in ("Notification", "PermissionRequest"):
                ss["status"] = WAITING
                ss["detail"] = payload.get("message") or "needs you"
            elif ev in ("Stop", "TaskCompleted"):
                ss["status"], ss["detail"] = DONE, "done"
                ss["done_at"] = now
            elif ev == "StopFailure":
                ss["status"], ss["detail"] = ERROR, "error"
            elif ev == "SessionStart":
                ss["status"], ss["detail"] = IDLE, "ready"
            elif ev == "SessionEnd":
                ss["status"], ss["detail"] = IDLE, ""
            elif ev in ("SubagentStart", "SubagentStop"):
                ss["status"], ss["detail"] = WORKING, "subagent"

    def snapshot(self) -> dict:
        """Payload enxuto pra placa — ESP32 parseando JSON, sem gordura."""
        now = time.time()
        with self.lock:
            # Limpa sessoes cujo terminal morreu sem avisar.
            for sid in [k for k, v in self.sessoes.items()
                        if now - v["last_event"] > SESSAO_MORTA_S]:
                del self.sessoes[sid]

            # So as ATIVAS vao para a tela. As demais continuam na memoria
            # (voltam sozinhas se houver novo evento), apenas nao aparecem.
            vivas = [v for v in self.sessoes.values()
                     if now - v["last_event"] <= SESSAO_ATIVA_S]
            # Mais recentes primeiro: com pouco espaco, quem trabalha agora
            # importa mais que quem parou ha 25 segundos.
            ordenadas = sorted(vivas, key=lambda v: -v["last_event"])[:MAX_SESSOES]

            sessoes = []
            for v in ordenadas:
                status, detail = v["status"], v["detail"]
                # "done" decai para ocioso sozinho
                if status == DONE and now - v["done_at"] > DONE_LINGER_S:
                    status, detail = IDLE, ""
                # sem eventos ha muito tempo: nao esta rodando de verdade
                elif status in (WORKING, TOOL) and now - v["last_event"] > STALE_AFTER_S:
                    status, detail = IDLE, ""
                sessoes.append({
                    "st": status,
                    "dt": detail[:40],
                    "pj": v["project"][:24],
                    "md": v["model"].replace("claude-", "")[:20],
                    "age": int(now - v["last_event"]),
                })

            u = self.usage.get("total", {})

        # Lista vazia e um estado legitimo: nenhuma sessao ativa. A placa
        # entende isso como "mostre o relogio" — sem intervalo de tela vazia
        # entre o mascote sumir e o repouso comecar.
        idade_min = min((s["age"] for s in sessoes if s["age"] >= 0), default=-1)

        snap = {
            "s": sessoes,
            "n": len(sessoes),
            "age": idade_min,
            "reqs": u.get("requests", 0),
            "tok_out": u.get("output", 0),
        }

        # Relogio: mandamos ja formatado para o ESP32 nao fazer conta de
        # calendario. ASCII puro — as fontes do LVGL nao tem acento.
        snap["clk"] = time.strftime("%H:%M")
        snap["day"] = time.strftime("%a %d %b")
        snap["rest"] = REPOUSO_S

        if (wx := TEMPO.ler()):
            snap["wx"] = wx

        lim = self.limites()
        if lim.get("ok"):
            snap["lim"] = [
                {"l": b["label"], "p": b["pct"], "r": b["resets_in"],
                 "s": b["severity"], "a": b["active"]}
                for b in lim["bars"]
            ]
            snap["lim_age"] = lim["age_s"]
            snap["lim_fonte"] = lim.get("fonte", "cache")
            snap["peak"] = lim["peak"]
        else:
            snap["lim"] = []
            snap["lim_age"] = -1
            snap["lim_fonte"] = ""
            snap["peak"] = -1

        return snap

    # Acima disso o dado ao vivo deixa de valer e voltamos ao cache. 10 min é
    # o dobro do TTL que o próprio Claude Code usa (5 min); se o app parou de
    # buscar, é melhor mostrar o cache com idade do que um número congelado.
    VIVO_VALE_S = 600

    def limites(self) -> dict:
        """
        Limites da assinatura, da melhor fonte disponível.

        Ordem: o que o app buscou ao vivo, senão o cache em disco do Claude
        Code. O app só consegue buscar porque tem acesso próprio ao chaveiro,
        via a API do macOS e com o seu consentimento — o bridge nunca vê a
        credencial, e por isso continua podendo rodar sozinho num terminal.
        """
        with self.lock:
            vivo, quando = self.limites_vivos, self.limites_vivos_at
        if vivo and time.time() - quando < self.VIVO_VALE_S:
            r = limits.normalizar(vivo, int(time.time() - quando))
            if r.get("ok"):
                r["fonte"] = "vivo"
                return r
        r = limits.read()
        if r.get("ok"):
            r["fonte"] = "cache"
        return r

    def refresh_usage(self) -> None:
        """Recalcula consumo do dia em background."""
        while True:
            try:
                r = usage.collect(since_days=1)
                if "error" not in r:
                    with self.lock:
                        self.usage = r
                        self.usage_at = time.time()
                j = janelas.calcular()
                if j.get("ok"):
                    with self.lock:
                        self.janelas = j
            except Exception as exc:  # nunca derruba o servidor por causa de stats
                print(f"[usage] falhou: {exc}", file=sys.stderr)
            time.sleep(USAGE_REFRESH_S)


STATE = State()
TEMPO = weather.Tempo()


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, body: dict) -> None:
        raw = json.dumps(body, separators=(",", ":")).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _local(self) -> bool:
        ip = self.client_address[0]
        return ip.startswith("127.") or ip == "::1"

    def _autorizado(self) -> bool:
        """
        Quem vem de fora precisa apresentar o token.

        O bridge escuta em 0.0.0.0 por necessidade: a placa fala com ele pela
        rede. Sem esta checagem, qualquer pessoa na mesma rede — coworking,
        café, escritório — lia nomes de projeto e volume de consumo só
        apontando o navegador. O app da barra roda na própria máquina e por
        isso é dispensado.
        """
        if self._local():
            return True
        cfg = config.ler()
        if not cfg.get("exigir_token"):
            return True   # modo aberto explícito (placa com firmware antigo)
        esperado = cfg.get("token") or ""
        dado = self.headers.get("X-Fagulha-Token") or ""
        if not dado:
            # ?t= existe pra você conseguir testar no navegador.
            dado = (parse_qs(urlparse(self.path).query).get("t") or [""])[0]
        # compare_digest: comparação de tempo constante, pra não vazar o
        # token caractere a caractere por diferença de tempo de resposta.
        return bool(esperado) and secrets.compare_digest(dado, esperado)

    def do_GET(self):
        rota = urlparse(self.path).path

        if not self._autorizado():
            self._send(401, {"error": "token"})
            return

        if rota == "/state":
            if not self._local():
                with STATE.lock:
                    STATE.placa_ip = self.client_address[0]
                    STATE.placa_at = time.time()
            self._send(200, STATE.snapshot())
        elif rota == "/app":
            # Payload do app da barra. Separado do /state de proposito: a placa
            # nao deve carregar bytes que so interessam ao Mac.
            snap = STATE.snapshot()
            now = time.time()
            with STATE.lock:
                placa_ip, placa_at = STATE.placa_ip, STATE.placa_at
                subiu, eventos = STATE.subiu_em, STATE.events_seen
                total = STATE.usage.get("total", {})
                modelos = STATE.usage.get("by_model", {})
                jan = dict(STATE.janelas)
            self._send(200, {
                "uptime_s": int(now - subiu),
                "eventos": eventos,
                "placa_ip": placa_ip,
                # -1 = a placa nunca apareceu desde que o bridge subiu
                "placa_age_s": int(now - placa_at) if placa_at else -1,
                "sessoes": snap["s"],
                "limites": snap["lim"],
                "limites_age_s": snap["lim_age"],
                "limites_fonte": snap.get("lim_fonte", ""),
                "pico": snap["peak"],
                "uso": total,
                "modelos": modelos,
                "tempo": snap.get("wx"),
                # O app avisa na cara quando a rede esta aberta. Modo
                # inseguro silencioso vira modo inseguro permanente.
                "rede_aberta": not config.ler().get("exigir_token", True),
                "janelas": jan,
            })
        elif rota == "/health":
            self._send(200, {"ok": True})
        elif rota == "/debug":
            with STATE.lock:
                self._send(200, {
                    "sessoes": STATE.sessoes,
                    "events_seen": STATE.events_seen,
                    "usage_total": STATE.usage.get("total"),
                    "by_model": STATE.usage.get("by_model"),
                })
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if not self._autorizado():
            self._send(401, {"error": "token"})
            return
        rota = urlparse(self.path).path

        if rota == "/limites":
            # Só de dentro da máquina: quem entrega isto é o app da barra.
            # Aceitar de fora deixaria qualquer um na rede plantar números
            # falsos na sua tela.
            if not self._local():
                self._send(403, {"error": "local only"})
                return
            try:
                n = int(self.headers.get("Content-Length") or 0)
                payload = json.loads(self.rfile.read(n) or b"{}")
            except (ValueError, json.JSONDecodeError):
                self._send(400, {"error": "json"})
                return
            with STATE.lock:
                STATE.limites_vivos = payload
                STATE.limites_vivos_at = time.time()
            self._send(200, {"ok": True})
            return

        if rota != "/hook":
            self._send(404, {"error": "not found"})
            return
        try:
            n = int(self.headers.get("Content-Length") or 0)
            payload = json.loads(self.rfile.read(n) or b"{}")
        except (ValueError, json.JSONDecodeError):
            payload = {}
        STATE.apply(payload)
        # Resposta vazia: o hook não deve influenciar o Claude de forma alguma.
        self._send(200, {})

    def log_message(self, *args):
        pass  # sem ruído no terminal


def _encerrar(signum=None, frame=None):
    """
    Saída limpa: derruba os dns-sd antes de morrer.

    Sem isto eles viram órfãos do PID 1 e continuam anunciando um bridge que
    não existe mais — a placa acharia o nome, conectaria e tomaria recusa.
    O atexit do anuncio.py NÃO cobre este caso: o tratamento padrão de SIGTERM
    encerra o processo sem passar por ele.
    """
    anuncio.parar()
    sys.stdout.flush()
    sys.stderr.flush()
    # os._exit e nao sys.exit: este mesmo codigo e chamado da thread que vigia
    # o app, e ali sys.exit() so levantaria SystemExit NAQUELA thread — medido,
    # os dns-sd morriam e o servidor continuava de pe respondendo na porta.
    # os._exit encerra o processo venha de onde vier.
    os._exit(0)


def _vigiar_pai():
    """
    Se o app da barra morrer, morremos junto.

    O app chama terminate() ao sair, o que cobre a saída limpa. Não cobre
    force-quit nem crash: medido, o bridge sobreviveu ao app e foi readotado
    pelo PID 1, seguindo servindo pra sempre.

    O macOS não tem PR_SET_PDEATHSIG, então checamos na mão. Só liga quando
    FAGULHA_PAI está definido — rodando pelo terminal isso não deve valer,
    porque ali o processo legitimamente já nasce com o pai encerrado.
    """
    pai = os.environ.get("FAGULHA_PAI", "")
    if not pai.isdigit():
        return
    pid = int(pai)

    def loop():
        while True:
            time.sleep(3)
            try:
                os.kill(pid, 0)   # sinal 0 não envia nada: só testa existência
            except OSError:
                print(f"[bridge] o app (pid {pid}) sumiu, encerrando",
                      file=sys.stderr)
                _encerrar()

    threading.Thread(target=loop, daemon=True).start()


def main():
    cfg = config.ler()
    port = int(sys.argv[1]) if len(sys.argv) > 1 else cfg["porta"]
    signal.signal(signal.SIGTERM, _encerrar)
    signal.signal(signal.SIGINT, _encerrar)
    _vigiar_pai()
    threading.Thread(target=STATE.refresh_usage, daemon=True).start()
    TEMPO.iniciar()
    # Anuncia o bridge por nome fixo, para a placa nao depender do
    # hostname do Mac (que o macOS renomeia sozinho ao detectar conflito).
    anuncio.iniciar(port)
    srv = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print(f"bridge ouvindo em 0.0.0.0:{port}")
    print(f"  placa busca : GET  /state")
    print(f"  hooks       : POST /hook")
    print(f"  inspeção    : GET  /debug")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nencerrando")


if __name__ == "__main__":
    main()
