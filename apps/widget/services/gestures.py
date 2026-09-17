#!/usr/bin/env python3
"""Reconhecimento de gestos de mão para o controle de janelas.

Fica separado do `face_tracker.py` de propósito: aqui não há câmera, nem
MediaPipe, nem processo — só geometria e uma máquina de estados sobre uma
sequência de posições. É o que permite testar o reconhecedor de verdade
(`test_gestures.py`), com trajetórias sintéticas, em vez de acenar para a
webcam e torcer.

Entrada: a cada quadro processado, `HandGestures.update(now, hand)` recebe a
posição do pulso já normalizada [0..1] e a pose da mão (aberta/punho), ou
`None` quando não há mão no quadro.

Com mais de uma mão no quadro, quem comanda é a que está MAIS PERTO da
câmera (ver `escolher_mao`): é a que foi levantada de propósito, enquanto a
outra costuma estar no teclado.

Saída: eventos — `arm`, `disarm`, `swipe_left/right/up/down` (com a pose), o
trio do arrasto (`grab`, `drag`, `release`) e os do ponteiro: `point_start`,
`move`, `point_end` (a mão de ponteiro andando) mais `click_down`/`click_up`
(o polegar fechando e abrindo, que é o botão do mouse). Quem decide o que cada um faz é a
interface; aqui só se descreve o que a mão fez.

O arrasto é o único gesto CONTÍNUO: enquanto a mão está fechada, cada quadro
rende um `drag` com o deslocamento. É o que permite a janela acompanhar a mão
em vez de saltar de posição.

O estado ARMADO é o que separa "gesticular" de "comandar": sem ele, coçar o
nariz na frente da câmera jogaria a janela para outro monitor.
"""

import math

# --- limiares (fração da largura/altura do quadro, e segundos) -------------
#
# CALIBRADOS PARA ~6 QUADROS/s, que é a taxa REAL medida na máquina de
# referência (Intel UHD, FaceLandmarker + HandLandmarker + reconhecimento de
# identidade no mesmo laço). O `PROCESS_HZ` do tracker diz 15, mas é um teto:
# o custo por quadro derruba para ~6. Qualquer limiar contado em número de
# amostras precisa caber nessa taxa — a primeira versão pedia 4 amostras em
# 0,45 s, o que dá 2 ou 3 a 6 Hz, e nenhum deslize era reconhecido.

# Janela de trajetória considerada para um deslize (~4 amostras a 6 Hz).
SWIPE_WINDOW = 0.7
# Amostras mínimas para julgar uma direção.
SWIPE_MIN_SAMPLES = 3
# Deslocamento mínimo no eixo dominante. Baixo demais transforma qualquer
# mexida em comando; alto demais obriga a varrer o braço pelo quadro inteiro.
SWIPE_MIN_DIST = 0.12
# Quanto o eixo dominante precisa ganhar do outro (evita diagonal ambígua).
SWIPE_AXIS_RATIO = 1.6
# Velocidade mínima (fração do quadro por segundo) — separa o deslize do
# movimento distraído da mão passeando pelo quadro.
SWIPE_MIN_SPEED = 0.28
# Fração dos passos que precisa ir na mesma direção (movimento decidido).
SWIPE_CONSISTENCY = 0.7
# Descanso entre deslizes, para um gesto não virar três.
SWIPE_COOLDOWN = 0.7

# Mão parada: variação máxima na janela para contar como "segurando".
# Ninguém segura a mão imóvel: a 6 Hz bastam duas amostras com um tremor
# natural para o contador reiniciar e o armar nunca completar.
HOLD_JITTER = 0.08
# Tempo de mão aberta parada para ARMAR.
#
# Era 1 s, e a espera se SENTE — você levanta a mão e fica lá, parado, sem
# saber se está funcionando. 0,4 s ainda distingue "mostrar a palma para
# comandar" de "gesticular enquanto fala", que é o motivo da trava existir,
# mas responde quase de imediato. O espelho da mão (Config) mostra o instante
# em que ele arma.
ARM_HOLD = 0.4
# Quanto do caminho à frente se projeta, em segundos.
#
# Entre a mão se mover e o cursor andar existem ~70 ms que não dá para
# remover: a câmera entrega um quadro a cada 33 ms e o modelo leva ~39 ms
# para lê-lo. O que dá é ADIANTAR — usando a velocidade que o filtro já
# estima, projeta-se onde a mão estará daqui a um pouco.
#
# Conservador de propósito: metade da latência. Prever demais faz o cursor
# passar do ponto quando a mão freia, e corrigir depois é pior do que chegar
# um pouco atrasado.
PREDICAO_SEGUNDOS = 0.035
# Teto do salto previsto (fração do quadro). Sem ele, um quadro com
# velocidade mal estimada jogaria o cursor para longe.
PREDICAO_MAXIMA = 0.05

# Deslocamento mínimo, por quadro, para render um evento de arrasto. Abaixo
# disso é tremor da mão parada, e mandar isso adiante faria a janela vibrar.
DRAG_MIN_STEP = 0.0025
# Sem gesto nenhum por este tempo: desarma (e some o indicador na tela).
IDLE_DISARM = 3.0
# Sem mão no quadro por este tempo: esquece a trajetória acumulada.
HAND_LOST = 0.4
# Velocidade máxima plausível de uma mão, em larguras de quadro por segundo.
# Acima disso o detector perdeu e reencontrou a mão em outro ponto, e esse
# "teleporte" somado à posição antiga produz um deslize que ninguém fez.
#
# É VELOCIDADE, não distância por quadro: com um limite fixo, o valor que
# separa teleporte de movimento depende da taxa de quadros — a 6 Hz um deslize
# real avança ~0,18 por quadro, que era justamente o limite fixo anterior, e a
# trajetória era descartada a cada quadro (nada era reconhecido).
MAX_HAND_SPEED = 2.2
# Buraco no tempo que quebra a continuidade da trajetória. A ~15 Hz, três
# quadros perdidos já bastam para a mão estar em outro lugar: juntar o antes e
# o depois num só movimento inventa um deslize (e, pior, um para o lado
# errado, porque o salto costuma ser maior que o gesto real).
# Folga generosa de propósito: a 6 Hz o intervalo normal já é 0,17 s, e um
# limite apertado descartaria a trajetória a cada quadro — nada seria
# reconhecido. Quem barra descontinuidade de verdade é o MAX_STEP acima.
MAX_GAP = 0.4

POSE_OPEN = "open"
POSE_FIST = "fist"
# Mão de ponteiro: indicador e médio esticados, anelar e mindinho dobrados.
# O POLEGAR é o botão — aberto, o cursor só anda; fechado, é como segurar o
# clique do mouse.
POSE_POINT = "point"      # polegar aberto  → move o cursor
POSE_CLICK = "click"      # polegar fechado → cursor + botão pressionado
POSE_OTHER = "other"


# Acima deste valor o polegar conta como aberto. Ver `thumb_ratio`.
THUMB_OPEN_RATIO = 1.05


def thumb_ratio(landmarks):
    """Quão para fora está o polegar (>1 = aberto, <1 = cruzando a palma).

    Compara a ponta do polegar (4) com a própria base dele (2), ambas medidas
    até a base do mindinho (17): ao fechar, o polegar atravessa a palma nessa
    direção e a ponta passa a ficar MAIS PERTO do mindinho que a base.

    Sem unidade nem escala: é uma razão entre duas distâncias da mesma mão,
    então não muda quando você se aproxima ou se afasta da câmera.
    """
    pts = [_xy(p) for p in landmarks]
    if len(pts) < 21:
        return 0.0
    base = _dist(pts[2], pts[17])
    if base < 1e-6:
        return 0.0
    return _dist(pts[4], pts[17]) / base


def tamanho_palma(landmarks):
    """Quão grande a mão aparece no quadro — o proxy de "quão perto".

    Mede só a PALMA (largura entre as bases do indicador e do mindinho, e o
    comprimento do pulso à base do médio). A palma é rígida: não encolhe ao
    fechar a mão. Medir a mão inteira, ou o retângulo que a contém, faria um
    punho perto parecer menor que uma mão aberta longe — e a escolha passaria
    a depender da pose em vez da distância.
    """
    pts = [_xy(p) for p in landmarks]
    if len(pts) < 21:
        return 0.0
    # Só x e y de propósito: aqui se quer o tamanho APARENTE, que é o que
    # revela a distância à câmera. Em metros (world landmarks), toda mão mede
    # praticamente o mesmo e a comparação perderia o sentido.
    largura = ((pts[5][0] - pts[17][0]) ** 2 + (pts[5][1] - pts[17][1]) ** 2) ** 0.5
    comprimento = ((pts[0][0] - pts[9][0]) ** 2 + (pts[0][1] - pts[9][1]) ** 2) ** 0.5
    return (largura + comprimento) / 2.0


def escolher_mao(maos):
    """Índice da mão mais próxima da câmera, ou None se não houver nenhuma.

    Com as duas mãos no quadro, comanda quem está à frente — é o gesto
    deliberado, enquanto a outra costuma estar no teclado ou apoiada.
    """
    melhor, melhor_tam = None, -1.0
    for i, mao in enumerate(maos):
        t = tamanho_palma(mao)
        if t > melhor_tam:
            melhor, melhor_tam = i, t
    return melhor


def classify_pose(landmarks):
    """Pose da mão a partir dos 21 pontos do MediaPipe Hands.

    `landmarks` é uma sequência de pontos com `.x`/`.y` ou de pares `(x, y)`.
    Devolve POSE_OPEN, POSE_FIST ou POSE_OTHER.

    O critério é a distância de cada ponta ao pulso comparada à distância da
    junta da base (MCP) ao pulso, normalizada pelo tamanho da própria mão —
    assim o resultado não muda quando você se aproxima ou se afasta da câmera,
    que é o que estragaria um limiar em pixels.
    """
    pts = [_xy(p) for p in landmarks]
    if len(pts) < 21:
        return POSE_OTHER

    wrist = pts[0]
    # Escala da mão: pulso → base do dedo médio. Nunca zero na prática, mas um
    # quadro ruim pode colapsar os pontos.
    scale = _dist(wrist, pts[9])
    if scale < 1e-6:
        return POSE_OTHER

    # Polegar: a régua dos outros dedos não serve (ele dobra de lado, não para
    # dentro). E medir a distância até a BASE DO INDICADOR também não: na mão
    # de ponteiro o polegar fica perto do indicador mesmo aberto, e tudo virava
    # "polegar fechado" — o clique ficava preso.
    #
    # O que separa de verdade: quando o polegar fecha, ele cruza a palma na
    # direção do mindinho. Então a régua é a ponta do polegar (4) contra a
    # própria base dele (2), ambas medidas até a base do mindinho (17). Ponta
    # mais longe que a base = polegar aberto, para fora da palma.
    thumb_out = thumb_ratio(landmarks) > THUMB_OPEN_RATIO

    extended = 0
    folded = 0
    # (ponta, base) de indicador, médio, anelar e mindinho. O polegar fica de
    # fora: ele dobra de lado, então a mesma régua não serve para ele.
    for tip, mcp in ((8, 5), (12, 9), (16, 13), (20, 17)):
        tip_d = _dist(wrist, pts[tip]) / scale
        mcp_d = _dist(wrist, pts[mcp]) / scale
        if tip_d > mcp_d * 1.55:
            extended += 1
        elif tip_d < mcp_d * 1.15:
            folded += 1

    if extended >= 3:
        return POSE_OPEN
    if folded >= 3:
        return POSE_FIST
    # Indicador e médio de pé, os outros dois dobrados: mão de ponteiro. Vem
    # DEPOIS de aberta/punho — abrir e fechar a mão passam por aqui no meio do
    # caminho, e quem manda nesses casos é a pose final, não a de passagem.
    if extended == 2 and folded >= 1:
        return POSE_POINT if thumb_out else POSE_CLICK
    return POSE_OTHER


class OneEuro:
    """Filtro 1€ (Casiez et al.): tira o tremor sem atrasar o movimento.

    A média móvel comum obriga a escolher entre um cursor trêmulo e um cursor
    atrasado. Este filtro decide sozinho: quando a mão está quase parada,
    suaviza forte (o tremor some); quando ela acelera, quase não filtra (o
    cursor acompanha). É o padrão de fato em rastreamento de mão, e a razão de
    caber aqui é ser meia dúzia de linhas — sem dependência nenhuma.

    `min_cutoff` controla o quanto suaviza parado; `beta`, o quanto solta a
    rédea quando acelera.
    """

    # Calibrados medindo os dois efeitos ao mesmo tempo (ver os testes). Com
    # `beta = 14`, a 25 quadros/s: sobra 18% do tremor e o atraso fica em 11 ms
    # — contra 20 ms do ajuste anterior, por apenas 2 pontos a mais de tremor.
    # Latência é o que se sente; tremor dessa ordem, não.
    #
    # O `beta` precisa ser desta ordem porque a posição vem normalizada em
    # 0..1: o valor "de manual" (0,007) foi pensado para pixels e aqui
    # deixaria o cursor borrachudo.
    def __init__(self, min_cutoff=1.0, beta=14.0, d_cutoff=1.0):
        self.min_cutoff = min_cutoff
        self.beta = beta
        self.d_cutoff = d_cutoff
        self._x = None
        self._dx = 0.0
        self._t = None

    @staticmethod
    def _alpha(cutoff, dt):
        tau = 1.0 / (2 * math.pi * cutoff)
        return 1.0 / (1.0 + tau / dt)

    def reset(self):
        self._x = None
        self._dx = 0.0
        self._t = None

    def velocidade(self):
        """Velocidade suavizada (unidades por segundo) do último quadro."""
        return self._dx

    def __call__(self, value, now):
        if self._x is None or self._t is None:
            self._x, self._t = value, now
            return value
        dt = now - self._t
        if dt <= 0:
            return self._x
        self._t = now

        # Velocidade, ela própria suavizada — é o que diz ao filtro se a mão
        # está tremendo ou se movendo de verdade.
        a_d = self._alpha(self.d_cutoff, dt)
        dx = (value - self._x) / dt
        self._dx = a_d * dx + (1 - a_d) * self._dx

        cutoff = self.min_cutoff + self.beta * abs(self._dx)
        a = self._alpha(cutoff, dt)
        self._x = a * value + (1 - a) * self._x
        return self._x


class HandGestures:
    """Máquina de estados dos gestos de mão.

    `mirror=True` espelha o eixo X: a webcam vê você de frente, então mover a
    mão para a SUA direita faz o x do quadro DIMINUIR. Sem espelhar, todo
    comando sairia invertido.
    """

    def __init__(self, mirror=True):
        self.mirror = mirror
        self.armed = False
        self._track = []          # [(t, x, y, pose)]
        self._last_seen = 0.0
        self._last_swipe = 0.0
        self._last_hold = 0.0
        self._last_activity = 0.0
        self._hold_pose = None
        self._hold_since = 0.0
        # Suavização da posição (ver OneEuro). Só o ponteiro e o arrasto usam:
        # deslize e poses trabalham com a posição crua, que é o que descreve o
        # gesto de fato.
        self._suave_x = OneEuro()
        self._suave_y = OneEuro()
        # Arrasto em curso: a mão fechou e ainda não abriu.
        self.dragging = False
        # Ponteiro livre: mão de ponteiro move só o cursor.
        self.pointing = False
        # Botão do polegar pressionado (dentro do modo ponteiro).
        self.clicking = False
        self._drag_last = None     # (x, y) do quadro anterior

    # -- API ---------------------------------------------------------------

    def update(self, now, hand):
        """Um quadro. Devolve a lista de eventos disparados (quase sempre vazia)."""
        events = []

        if hand is None:
            if self.pointing and now - self._last_seen > HAND_LOST:
                if self.clicking:
                    self.clicking = False
                    events.append({"name": "click_up"})
                self.pointing = False
                self._drag_last = None
                events.append({"name": "point_end"})
            if self.dragging and now - self._last_seen > HAND_LOST:
                self.dragging = False
                self._drag_last = None
                events.append({"name": "release"})
            if self._track and now - self._last_seen > HAND_LOST:
                self._track = []
                self._reset_hold()
                self._suave_x.reset()
                self._suave_y.reset()
            if self.armed and now - self._last_activity > IDLE_DISARM:
                self.armed = False
                events.append({"name": "disarm"})
            return events

        x = 1.0 - hand["x"] if self.mirror else hand["x"]
        y = hand["y"]
        pose = hand.get("pose", POSE_OTHER)

        # Trajetória só vale se for contínua: um buraco no tempo ou um salto no
        # espaço significam que este ponto não continua o anterior — recomeça.
        if self._track:
            pt, px, py, _ = self._track[-1]
            step_limit = MAX_HAND_SPEED * max(now - pt, 1e-3)
            if now - pt > MAX_GAP or _dist((px, py), (x, y)) > step_limit:
                self._track = []
                self._reset_hold()
                self._suave_x.reset()
                self._suave_y.reset()

        self._last_seen = now
        self._track.append((now, x, y, pose))
        self._track = [s for s in self._track if now - s[0] <= SWIPE_WINDOW]

        # Posição suavizada para o movimento contínuo. O deslize e as poses
        # seguem com a crua: ali o que importa é o gesto inteiro, não a
        # estabilidade quadro a quadro.
        sx = self._suave_x(x, now)
        sy = self._suave_y(y, now)
        # Adianta o cursor pela velocidade estimada, para compensar o tempo
        # que o quadro levou para chegar até aqui.
        sx += _limitar(self._suave_x.velocidade() * PREDICAO_SEGUNDOS,
                       PREDICAO_MAXIMA)
        sy += _limitar(self._suave_y.velocidade() * PREDICAO_SEGUNDOS,
                       PREDICAO_MAXIMA)

        held = self._hold_duration(now, pose)

        # ARMAR: mão aberta, parada, por ARM_HOLD.
        if not self.armed:
            if pose == POSE_OPEN and held >= ARM_HOLD:
                self.armed = True
                self._last_activity = now
                self._reset_hold()
                self._track = []
                events.append({"name": "arm"})
            return events

        # Daqui para baixo, armado.

        # ---- arrasto: fechar a mão pega, abrir solta --------------------
        # Deliberadamente sem tempo de espera: fechar a mão é um gesto
        # inequívoco, e exigir que ficasse parada arruinaria o movimento
        # contínuo que vem logo depois.
        if pose == POSE_FIST and not self.dragging:
            # Sair do ponteiro com o polegar fechado e virar punho é o caminho
            # natural de "clicar e então agarrar" — e era por onde o clique
            # ficava preso: o botão seguia pressionado sem ninguém para
            # soltá-lo. Encerra o modo ponteiro ANTES de pegar a janela.
            if self.clicking:
                self.clicking = False
                events.append({"name": "click_up"})
            if self.pointing:
                self.pointing = False
                events.append({"name": "point_end"})
            self.dragging = True
            self._drag_last = (sx, sy)
            self._last_activity = now
            self._track = []
            self._reset_hold()
            events.append({"name": "grab"})
            return events

        if self.dragging:
            if pose == POSE_OPEN:
                self.dragging = False
                self._drag_last = None
                self._last_activity = now
                self._track = []
                self._reset_hold()
                events.append({"name": "release"})
                return events
            # Segue arrastando (o punho continua, ou a pose ficou ambígua no
            # meio do movimento — soltar por causa de um quadro ruim seria
            # pior do que manter).
            if self._drag_last is not None:
                dx = sx - self._drag_last[0]
                dy = sy - self._drag_last[1]
                if abs(dx) >= DRAG_MIN_STEP or abs(dy) >= DRAG_MIN_STEP:
                    self._drag_last = (sx, sy)
                    self._last_activity = now
                    events.append({"name": "drag",
                                   "dx": round(dx, 4), "dy": round(dy, 4)})
            return events

        # ---- ponteiro: a mão vira mouse; o polegar, o botão --------------
        if pose in (POSE_POINT, POSE_CLICK):
            if not self.pointing:
                self.pointing = True
                self._drag_last = (sx, sy)
                self._last_activity = now
                self._track = []
                self._reset_hold()
                events.append({"name": "point_start"})

            # Movimento primeiro: o cursor não pode congelar enquanto o
            # polegar fecha, senão clicar tira a mira do lugar.
            if self._drag_last is not None:
                dx = sx - self._drag_last[0]
                dy = sy - self._drag_last[1]
                if abs(dx) >= DRAG_MIN_STEP or abs(dy) >= DRAG_MIN_STEP:
                    self._drag_last = (sx, sy)
                    self._last_activity = now
                    events.append({"name": "move",
                                   "dx": round(dx, 4), "dy": round(dy, 4)})

            # O polegar é o botão: fechado pressiona, aberto solta. Segurar
            # fechado e mover é arrastar/selecionar, como num trackpad.
            quer_clicar = pose == POSE_CLICK
            if quer_clicar and not self.clicking:
                self.clicking = True
                self._last_activity = now
                events.append({"name": "click_down"})
            elif not quer_clicar and self.clicking:
                self.clicking = False
                self._last_activity = now
                events.append({"name": "click_up"})
            return events

        if self.pointing:
            if self.clicking:
                self.clicking = False
                events.append({"name": "click_up"})
            self.pointing = False
            self._drag_last = None
            self._last_activity = now
            self._track = []
            events.append({"name": "point_end"})
            return events

        swipe = self._detect_swipe(now)
        if swipe is not None:
            self._last_swipe = now
            self._last_activity = now
            self._track = []
            self._reset_hold()
            events.append(swipe)
            return events

        if now - self._last_activity > IDLE_DISARM:
            self.armed = False
            events.append({"name": "disarm"})
        return events

    def reset(self):
        self.armed = False
        self._suave_x.reset()
        self._suave_y.reset()
        self.dragging = False
        self.pointing = False
        self.clicking = False
        self._drag_last = None
        self._track = []
        self._reset_hold()

    # -- interno -----------------------------------------------------------

    def _reset_hold(self):
        self._hold_pose = None
        self._hold_since = 0.0

    def _hold_duration(self, now, pose):
        """Há quanto tempo a mão está parada NESTA pose (0 se está se mexendo)."""
        if pose != self._hold_pose:
            self._hold_pose = pose
            self._hold_since = now
            return 0.0
        if len(self._track) >= 2:
            xs = [s[1] for s in self._track]
            ys = [s[2] for s in self._track]
            if (max(xs) - min(xs)) > HOLD_JITTER or (max(ys) - min(ys)) > HOLD_JITTER:
                self._hold_since = now
                return 0.0
        return now - self._hold_since

    def _detect_swipe(self, now):
        if now - self._last_swipe < SWIPE_COOLDOWN:
            return None
        if len(self._track) < SWIPE_MIN_SAMPLES:
            return None

        t0, x0, y0, _ = self._track[0]
        _, x1, y1, _ = self._track[-1]
        dt = now - t0
        if dt <= 0:
            return None

        dx = x1 - x0
        dy = y1 - y0
        horizontal = abs(dx) >= abs(dy) * SWIPE_AXIS_RATIO
        vertical = abs(dy) >= abs(dx) * SWIPE_AXIS_RATIO
        if not horizontal and not vertical:
            return None

        delta = dx if horizontal else dy
        if abs(delta) < SWIPE_MIN_DIST or abs(delta) / dt < SWIPE_MIN_SPEED:
            return None

        # Movimento decidido: a maior parte dos passos vai para o mesmo lado.
        idx = 1 if horizontal else 2
        steps = [self._track[i][idx] - self._track[i - 1][idx]
                 for i in range(1, len(self._track))]
        same = sum(1 for s in steps if (s > 0) == (delta > 0))
        if steps and same / len(steps) < SWIPE_CONSISTENCY:
            return None

        # A pose que vale é a predominante durante o deslize: começar de punho
        # e abrir a mão no fim não deve virar um comando diferente.
        poses = [s[3] for s in self._track]
        pose = max(set(poses), key=poses.count)

        if horizontal:
            name = "swipe_right" if delta > 0 else "swipe_left"
        else:
            # y cresce para baixo no quadro.
            name = "swipe_down" if delta > 0 else "swipe_up"
        return {"name": name, "pose": pose}


def _limitar(valor, teto):
    return max(-teto, min(teto, valor))


def _xy(p):
    """(x, y, z) do ponto — z é 0 quando não existe.

    Aceita tanto os pontos do MediaPipe quanto pares/triplas simples, que é o
    que os testes usam.
    """
    if hasattr(p, "x"):
        return (p.x, p.y, getattr(p, "z", 0.0) or 0.0)
    if len(p) >= 3:
        return (p[0], p[1], p[2])
    return (p[0], p[1], 0.0)


def _dist(a, b):
    """Distância entre dois pontos, em 3D quando há profundidade.

    Com os pontos 2D da imagem, a perspectiva mente: uma mão inclinada para a
    câmera tem as distâncias encurtadas pela projeção, e um polegar aberto
    passa a medir como fechado. Com os pontos em metros que o próprio modelo
    devolve (`hand_world_landmarks`), a distância é física e não depende do
    ângulo da mão.
    """
    dz = (a[2] if len(a) > 2 else 0.0) - (b[2] if len(b) > 2 else 0.0)
    return ((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2 + dz ** 2) ** 0.5
