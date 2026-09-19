#!/usr/bin/env python3
"""Ponteiro virtual: reproduz o "Super + arrastar" do mouse a partir da mão.

O niri não expõe o arrasto interativo por IPC — não existe um `niri msg action`
que diga "pegue esta janela e siga o cursor". Mas o compositor já sabe fazer
isso com o mouse: segurar Super e arrastar move a janela. Então o caminho é
falar a língua dele — um dispositivo de entrada virtual, via `/dev/uinput`,
que pressiona Super + botão esquerdo e move o ponteiro.

A janela pega é a que está SOB O CURSOR, exatamente como no arrasto de mouse
de verdade. Não tentamos reposicionar o cursor antes: o compositor aplica
aceleração de ponteiro, então "andar N unidades" não é "andar N pixels", e
qualquer cálculo de posição absoluta erra — mais ainda com um monitor girado.

Protocolo (uma linha por comando, em stdin):
    GRAB              pressiona Super + botão esquerdo (pega a janela)
    PRESS             pressiona só o botão esquerdo (clique comum)
    MOVE <dx> <dy>    move o ponteiro (unidades do dispositivo, relativas)
    SCROLL <n>        gira a roda: n positivo rola para CIMA, como a roda
                      de um mouse de verdade
    SCROLL_H <n>      gira a roda horizontal: n positivo rola para a DIREITA
    RELEASE           solta o que estiver pressionado
    QUIT              encerra
Sem comando nenhum por alguns segundos, o que estiver pressionado é solto
sozinho: botão preso captura o desktop, e nenhuma falha do outro lado pode
custar isso.
Saída:
    READY             dispositivo criado e assentado
    ERR <msg>

Requer permissão de escrita em /dev/uinput. Numa sessão de desktop comum ela
vem por ACL do seat (`getfacl /dev/uinput`), sem precisar de root nem de grupo
extra; sem ela, o serviço avisa e sai.
"""
import sys
import time

# Tempo para o compositor notar e abrir o dispositivo novo. Eventos enviados
# antes disso são simplesmente perdidos — foi o que aconteceu no primeiro
# teste, em que o cursor não se mexia.
SETTLE_SECS = 1.5


def out(msg):
    print(msg, flush=True)


class Pointer:
    """Traduz comandos em eventos de entrada. `sink` é o dispositivo (ou um
    duplo, nos testes): precisa de `write(tipo, código, valor)` e `syn()`."""

    def __init__(self, sink, codes):
        self.sink = sink
        self.c = codes
        # O que esta pressionado: None, "drag" (Super + botao, move a janela)
        # ou "click" (so o botao, clique comum). Sao coisas diferentes: soltar
        # uma nao pode deixar a outra presa.
        self.holding = None

    def move(self, dx, dy):
        if dx:
            self.sink.write(self.c.EV_REL, self.c.REL_X, int(dx))
        if dy:
            self.sink.write(self.c.EV_REL, self.c.REL_Y, int(dy))
        self.sink.syn()

    def scroll(self, passos):
        """Gira a roda vertical. Positivo rola para cima, como no mouse."""
        self._roda(passos, self.c.REL_WHEEL_HI_RES, self.c.REL_WHEEL)

    def scroll_h(self, passos):
        """Gira a roda horizontal. Positivo rola para a direita."""
        self._roda(passos, self.c.REL_HWHEEL_HI_RES, self.c.REL_HWHEEL)

    def _roda(self, passos, codigo_fino, codigo_grosso):
        """Emite os dois eventos da roda, fino e grosso.

        `*_HI_RES` (em 1/120 de degrau) é o que dá rolagem fina em quem o
        entende, e o degrau inteiro é o que aplicativos antigos esperam.
        Mandar só o fino faz a página não se mexer neles; mandar só o grosso
        rola aos trancos.
        """
        passos = int(passos)
        if not passos:
            return
        self.sink.write(self.c.EV_REL, codigo_fino, passos)
        # Trunca em direção ao zero, não para baixo: `//` mandaria -1 degrau
        # para qualquer migalha negativa, e a página andava sozinha ao rolar
        # devagar para a esquerda ou para cima.
        degraus = int(passos / 120)
        if degraus:
            self.sink.write(self.c.EV_REL, codigo_grosso, degraus)
        self.sink.syn()

    def grab(self):
        if self.holding == "drag":
            return
        # Já havia um clique segurando (o polegar estava fechado): solta antes
        # de pegar a janela. Ignorar o pedido, como era antes, deixava o botão
        # pressionado para sempre — o desktop inteiro parava de responder.
        if self.holding:
            self.release()
        # Super primeiro, botão depois: é a ordem que um humano faz, e o niri
        # só lê o clique como "mover janela" com o modificador já pressionado.
        self.sink.write(self.c.EV_KEY, self.c.KEY_LEFTMETA, 1)
        self.sink.syn()
        self.sink.write(self.c.EV_KEY, self.c.BTN_LEFT, 1)
        self.sink.syn()
        self.holding = "drag"

    def press(self):
        """Clique comum: botão SEM o Super, para clicar em vez de mover.

        Enquanto ficar pressionado, arrasta/seleciona — é o polegar fechado
        segurando o botão.
        """
        if self.holding == "click":
            return
        if self.holding:
            self.release()
        self.sink.write(self.c.EV_KEY, self.c.BTN_LEFT, 1)
        self.sink.syn()
        self.holding = "click"

    def release(self):
        if not self.holding:
            return
        era = self.holding
        self.holding = None
        self.sink.write(self.c.EV_KEY, self.c.BTN_LEFT, 0)
        self.sink.syn()
        if era == "drag":
            self.sink.write(self.c.EV_KEY, self.c.KEY_LEFTMETA, 0)
            self.sink.syn()


# Tempo sem NENHUM comando que basta para soltar o que estiver pressionado.
# Um botão preso captura o desktop inteiro: se o lado de lá travou, morreu ou
# perdeu o evento de soltar, é melhor largar sozinho do que ficar segurando.
IDLE_RELEASE_SECS = 4.0


def run_commands(lines, pointer, on_idle=None):
    """Consome comandos até QUIT (ou o fim da entrada).

    Um item `None` na sequência é um tique sem comando: serve para o guarda de
    ociosidade correr mesmo quando ninguém está falando.

    Solta o que estiver preso ao sair: terminar com o botão e o Super
    pressionados deixaria a janela grudada no ponteiro e o teclado em estado
    de modificador — só a sessão consertaria.
    """
    try:
        for line in lines:
            if line is None:
                if on_idle is not None:
                    on_idle(pointer)
                continue
            parts = line.strip().split()
            if not parts:
                continue
            cmd = parts[0].upper()
            if cmd == "GRAB":
                pointer.grab()
            elif cmd == "PRESS":
                pointer.press()
            elif cmd == "SCROLL":
                try:
                    pointer.scroll(float(parts[1]))
                except (IndexError, ValueError):
                    continue
            elif cmd == "SCROLL_H":
                try:
                    pointer.scroll_h(float(parts[1]))
                except (IndexError, ValueError):
                    continue
            elif cmd == "MOVE":
                try:
                    pointer.move(float(parts[1]), float(parts[2]))
                except (IndexError, ValueError):
                    continue
            elif cmd == "RELEASE":
                pointer.release()
            elif cmd == "QUIT":
                break
    finally:
        pointer.release()


def main():
    try:
        from evdev import UInput, ecodes as e
    except ImportError:
        out("ERR evdev não instalado — rode scripts/setup-facetrack.sh")
        return 1

    caps = {
        e.EV_REL: [e.REL_X, e.REL_Y,
                   e.REL_WHEEL, e.REL_WHEEL_HI_RES,
                   e.REL_HWHEEL, e.REL_HWHEEL_HI_RES],
        e.EV_KEY: [e.BTN_LEFT, e.KEY_LEFTMETA],
    }
    try:
        ui = UInput(caps, name="teamwork-ai-hand-pointer")
    except Exception as exc:  # noqa: BLE001 — sem permissão, sem uinput…
        out("ERR não consegui criar o ponteiro virtual: %s" % str(exc)[:120])
        return 1

    time.sleep(SETTLE_SECS)
    out("READY")

    import select

    def linhas_com_tique():
        """Linhas de stdin, com `None` quando passa tempo sem nenhuma."""
        while True:
            pronto, _, _ = select.select([sys.stdin], [], [], 1.0)
            if not pronto:
                yield None
                continue
            linha = sys.stdin.readline()
            if not linha:
                return
            yield linha

    ultimo = [time.monotonic()]

    def guarda(pointer):
        if pointer.holding and time.monotonic() - ultimo[0] > IDLE_RELEASE_SECS:
            pointer.release()

    class Marcado(Pointer):
        """Pointer que anota quando foi usado, para o guarda saber."""

        def move(self, dx, dy):
            ultimo[0] = time.monotonic()
            super().move(dx, dy)

        def grab(self):
            ultimo[0] = time.monotonic()
            super().grab()

        def press(self):
            ultimo[0] = time.monotonic()
            super().press()

    try:
        run_commands(linhas_com_tique(), Marcado(ui, e), on_idle=guarda)
    finally:
        ui.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
