#!/usr/bin/env python3
"""Rastreamento facial por webcam para o avatar do Team Work AI.

Abre a câmera, roda o MediaPipe FaceLandmarker (posição do rosto, pose da
cabeça e blendshapes ARKit) e, se disponível, reconhecimento de identidade
(insightface). Emite os NÚMEROS derivados por stdout — os frames da câmera
NUNCA são gravados nem enviados a lugar nenhum (privacidade: 100% local).

Protocolo:
  stdin   "ENROLL"                cadastra o rosto atual como dono (salva embedding local)
          "HANDS ON|OFF"          liga/desliga a detecção de mãos (gestos e aceno).
                                  Desligada, o segundo modelo nem roda — é a
                                  maior economia de CPU do processo.
          "FACE FULL|LOW"         ritmo do rastreamento facial: FULL anima o
                                  avatar; LOW só confere presença/identidade
                                  (1 quadro em cada 4), para quando o avatar
                                  não está na tela
          "PREVIEW ON|OFF"        liga/desliga o espelho da mão (quadro + pontos)
          "QUIT"                  encerra
  stdout  "READY"                 câmera + modelos prontos
          "FACE <json>"           rosto detectado (throttled ~12 Hz):
                                    {x,y,       posição do rosto no quadro [-1..1]
                                     yaw,pitch, pose da cabeça do usuário [-1..1]
                                     owner,     1=dono, 0=outro, -1=sem identidade
                                     sim,       similaridade com o dono
                                     blend:{...} blendshapes mapeados p/ canais do avatar}
          "NOFACE"                nenhum rosto (throttled)
          "STATS <json>"          a cada 5 s: {fps} quadros REALMENTE
                                  processados por segundo (não a emissão) —
                                  é a taxa que os limiares de gesto assumem —
                                  e {hand: {open,fist,other}} quantos quadros
                                  viram cada pose de mão no intervalo
          "HAND <json>"           só com PREVIEW ON e mão no quadro:
                                    {pts:[[x,y],…21], pose, frame, seq} —
                                    `frame` é o caminho de um JPEG pequeno em
                                    tmpfs, reescrito a cada quadro
          "GESTURE <json>"        gesto de mão: {name, pose}
                                    name: arm|disarm|swipe_left|swipe_right|
                                          swipe_up|swipe_down|fist_hold
          "ENROLLED <sim>"        cadastro concluído
          "ERR <msg>"

Config por ambiente:
  TEAMWORK_FACE_CAMERA   índice da câmera (padrão 0)
  TEAMWORK_FACE_MODEL    caminho do face_landmarker.task
  TEAMWORK_FACE_DIR      pasta de dados (owner.npy)
  TEAMWORK_GESTURE_MIRROR  1 (padrão) espelha o eixo X dos gestos
"""
import json
import os
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gestures import (HandGestures, classify_pose, escolher_mao,  # noqa: E402
                      thumb_ratio)

# Teto de threads das bibliotecas de visão. Precisa vir ANTES do import de
# cv2/mediapipe/onnxruntime: as três leem isto na inicialização e, sem teto,
# cada uma abre uma thread por núcleo — com dois modelos no mesmo laço, a
# máquina passa mais tempo sincronizando do que calculando.
_THREADS = os.environ.get("TEAMWORK_FACE_THREADS", "2")
for _var in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS",
             "NUMEXPR_NUM_THREADS", "VECLIB_MAXIMUM_THREADS"):
    os.environ.setdefault(_var, _THREADS)


def _limit_cores():
    """Prende o processo a poucos núcleos.

    As variáveis acima só valem para quem foi compilado com OpenMP — o
    onnxruntime das versões atuais usa thread pool próprio e as ignora
    solenemente: medido, ele gastava 600 ms de CPU em 104 ms de relógio, ou
    seja, seis núcleos de uma vez. A afinidade é o único teto que TODAS as
    bibliotecas respeitam, porque quem aplica é o kernel.

    O rastreamento é um serviço de fundo: ele não pode competir de igual para
    igual com o que você está fazendo na máquina.
    """
    try:
        disponiveis = len(os.sched_getaffinity(0))
    except AttributeError:
        return
    pedido = os.environ.get("TEAMWORK_FACE_CORES")
    alvo = int(pedido) if pedido else max(2, disponiveis // 4)
    alvo = max(1, min(alvo, disponiveis))
    try:
        os.sched_setaffinity(0, set(sorted(os.sched_getaffinity(0))[:alvo]))
    except OSError:
        pass


_limit_cores()

BASE = os.environ.get(
    "TEAMWORK_FACE_DIR",
    os.path.join(os.environ.get("XDG_DATA_HOME", os.path.expanduser("~/.local/share")),
                 "teamwork-ai", "facetrack"),
)
MODEL = os.environ.get("TEAMWORK_FACE_MODEL", os.path.join(BASE, "face_landmarker.task"))
CAMERA = int(os.environ.get("TEAMWORK_FACE_CAMERA", "0"))
OWNER_PATH = os.path.join(BASE, "owner.npy")
# Espelho da mão: um JPEG pequeno em tmpfs (nunca em disco), reescrito a cada
# quadro enquanto o preview está ligado. Some com o fim da sessão, como todo o
# resto em /run — a imagem não é guardada em lugar nenhum.
_RUNTIME = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
PREVIEW_PATH = os.path.join(_RUNTIME, "teamwork-ai", "handcam.jpg")
PREVIEW_WIDTH = 320       # o bastante pra enxergar a mão; barato de encodar
EMIT_HZ = 12.0            # taxa máxima de emissão FACE
# Quadros processados por segundo. É um TETO, e o teto importa: baratear o
# quadro sem baixá-lo faz o laço apenas rodar mais vezes e gastar a economia
# de volta — medido, os dois modos davam exatamente o mesmo consumo.
#
# 12 Hz anima o avatar de forma fluida e sustenta os gestos; 5 Hz basta para
# saber que você está aí, que é você, e para o aceno.
PROCESS_HZ = 12.0
PROCESS_HZ_LOW = 5.0
# Com a mão COMANDANDO (cursor ou arrasto), o laço vai ao teto: a fluidez do
# ponteiro é a taxa de amostragem da mão. Cabe porque, nesse momento, o rosto
# passa a rodar em um quarto dos quadros — quem move o cursor não está olhando
# o avatar.
#
# 30 é o teto FÍSICO da câmera (medido: nenhuma webcam desta máquina passa de
# 30 fps em nenhum formato). Na prática o processamento chega a ~25: o
# detector de mãos custa ~38 ms por quadro e — medido — NÃO paraleliza, dá o
# mesmo tempo com 2 ou com 12 núcleos. Pôr 30 aqui só garante que o limitador
# nunca seja o gargalo; quem manda é o modelo.
PROCESS_HZ_FAST = 30.0
# Segundos entre checagens de identidade. Cada uma custa ~600 ms de CPU
# (medido), então a frequência é o que decide o peso dela: a 3 s era o segundo
# maior gasto do processo, e ninguém troca de pessoa na frente da câmera nesse
# ritmo. A primeira checagem continua imediata — só as repetições espaçam.
RECOG_EVERY = 12.0
# Teto para o adiamento acima: com a mão no quadro a identidade espera, mas
# não para sempre — senão alguém entraria em cena de mão levantada e herdaria
# o "dono" de quem estava antes (ver a trava em WindowGestures.qml).
RECOG_MAX_DEFER = 10.0
# A webcam te vê de frente: sem espelhar, mover a mão pra sua direita mandaria
# o comando pra esquerda.
GESTURE_MIRROR = os.environ.get("TEAMWORK_GESTURE_MIRROR", "1") != "0"


def out(msg):
    print(msg, flush=True)


def err(msg):
    sys.stderr.write("facetrack: " + msg + "\n")
    sys.stderr.flush()


# Blendshapes do MediaPipe (52 ARKit) → 14 canais de morph do avatar.
def to_channels(bs):
    def g(k):
        return round(float(bs.get(k, 0.0)), 3)

    def avg(a, b):
        return round((float(bs.get(a, 0.0)) + float(bs.get(b, 0.0))) / 2.0, 3)

    return {
        "blink": avg("eyeBlinkLeft", "eyeBlinkRight"),
        "browUp": g("browInnerUp"),
        "browOuterUpL": g("browOuterUpLeft"),
        "browOuterUpR": g("browOuterUpRight"),
        "browDown": avg("browDownLeft", "browDownRight"),
        "eyeWide": avg("eyeWideLeft", "eyeWideRight"),
        "eyeSquint": avg("eyeSquintLeft", "eyeSquintRight"),
        "smile": avg("mouthSmileLeft", "mouthSmileRight"),
        "cheek": avg("cheekSquintLeft", "cheekSquintRight"),
        "frown": avg("mouthFrownLeft", "mouthFrownRight"),
        "jawOpen": g("jawOpen"),
        "lipPress": avg("mouthPressLeft", "mouthPressRight"),
        "mouthLeft": g("mouthLeft"),
        "mouthRight": g("mouthRight"),
    }


def head_pose(matrix):
    """Extrai yaw/pitch [-1..1] da matriz de transformação facial 4x4."""
    import math
    r = matrix
    # yaw ~ rotação em torno de Y; pitch ~ em torno de X.
    yaw = math.atan2(r[0][2], r[2][2])
    pitch = math.atan2(-r[1][2], math.sqrt(r[0][2] ** 2 + r[2][2] ** 2))
    # normaliza ~[-1,1] (±~45° cheio)
    return max(-1.0, min(1.0, yaw / 0.8)), max(-1.0, min(1.0, pitch / 0.8))


def save_preview_frame(cv2, frame, path, width=PREVIEW_WIDTH):
    """Grava o quadro do espelho da mão, pequeno e espelhado. True se gravou.

    Espelhado porque você se vê como num espelho: sem isso, mover a mão para a
    direita aparece indo para a esquerda e atrapalha mais do que ajuda.

    A troca é atômica (arquivo temporário + rename): a interface lê esse
    caminho a cada quadro e, sem isso, pegaria JPEG pela metade.
    """
    h, w = frame.shape[:2]
    if w == 0 or h == 0:
        return False
    scale = width / float(w)
    small = cv2.resize(frame, (width, max(1, int(h * scale))))
    small = cv2.flip(small, 1)
    # imencode em vez de imwrite: o OpenCV decide o formato pela EXTENSÃO do
    # arquivo, e o temporário termina em ".tmp" — ele não reconhecia e falhava
    # com "could not find a writer", silenciosamente, a cada quadro.
    ok, buf = cv2.imencode(".jpg", small, [int(cv2.IMWRITE_JPEG_QUALITY), 65])
    if not ok:
        return False
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "wb") as fh:
        fh.write(buf.tobytes())
    os.replace(tmp, path)
    return True


# Leitura de comandos do stdin numa thread (não bloqueia a captura).
_cmd = {"enroll": False, "quit": False, "preview": False, "hands": True,
        "face_full": True}


def _stdin_loop():
    for line in sys.stdin:
        c = line.strip().upper()
        if c == "ENROLL":
            _cmd["enroll"] = True
        elif c == "FACE FULL":
            _cmd["face_full"] = True
        elif c == "FACE LOW":
            _cmd["face_full"] = False
        elif c == "HANDS ON":
            _cmd["hands"] = True
        elif c == "HANDS OFF":
            _cmd["hands"] = False
        elif c == "PREVIEW ON":
            _cmd["preview"] = True
        elif c == "PREVIEW OFF":
            _cmd["preview"] = False
        elif c == "QUIT":
            _cmd["quit"] = True
            break


def main():
    os.makedirs(BASE, exist_ok=True)
    import cv2
    import numpy as np
    import mediapipe as mp
    from mediapipe.tasks import python as mp_python
    from mediapipe.tasks.python import vision

    if not os.path.exists(MODEL):
        out("ERR modelo face_landmarker.task ausente — rode setup-facetrack.sh")
        return

    cv2.setNumThreads(int(os.environ.get("TEAMWORK_FACE_THREADS", "2")))
    cap = cv2.VideoCapture(CAMERA)
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
    # Não adianta a câmera entregar 30 quadros se só ~8 são processados: o
    # resto é decodificação jogada fora. Nem toda webcam respeita, daí o
    # descarte por `grab()` continuar valendo no laço.
    # 30 é o que estas webcams entregam no máximo; o descarte por `grab()`
    # abaixo é quem decide quantos realmente viram trabalho.
    cap.set(cv2.CAP_PROP_FPS, 30)
    # Buffer curto: com fila, o quadro processado é o de um segundo atrás e o
    # avatar responde atrasado.
    cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
    if not cap.isOpened():
        out("ERR não consegui abrir a câmera %d" % CAMERA)
        return

    options = vision.FaceLandmarkerOptions(
        base_options=mp_python.BaseOptions(model_asset_path=MODEL),
        output_face_blendshapes=True,
        output_facial_transformation_matrixes=True,
        running_mode=vision.RunningMode.VIDEO,
        num_faces=1,
    )
    landmarker = vision.FaceLandmarker.create_from_options(options)

    # Detecção de mãos (pra reconhecer ACENO), via tasks HandLandmarker.
    # Opcional — sem o modelo, o resto segue funcionando.
    hand_landmarker = None
    hand_model = os.path.join(BASE, "hand_landmarker.task")
    if os.path.exists(hand_model):
        try:
            hopts = vision.HandLandmarkerOptions(
                base_options=mp_python.BaseOptions(model_asset_path=hand_model),
                # Duas mãos para poder escolher a mais próxima (ver
                # gestures.escolher_mao). Medido: custa ~2 ms a mais por
                # quadro — o detector de palma, que é a parte cara, roda uma
                # vez só; o extra é o modelo de pontos da segunda mão.
                num_hands=2,
                running_mode=vision.RunningMode.VIDEO,
            )
            hand_landmarker = vision.HandLandmarker.create_from_options(hopts)
            err("detecção de aceno ativa")
        except Exception as e:  # noqa: BLE001
            err("sem detecção de aceno (%s)" % e)
    else:
        err("sem detecção de aceno (modelo hand_landmarker.task ausente)")

    # Reconhecimento de identidade (opcional).
    recog = None
    owner_emb = None
    try:
        from insightface.app import FaceAnalysis
        recog = FaceAnalysis(name="buffalo_l", providers=["CPUExecutionProvider"])
        recog.prepare(ctx_id=-1, det_size=(224, 224))
        if os.path.exists(OWNER_PATH):
            owner_emb = np.load(OWNER_PATH)
        err("reconhecimento de identidade ativo")
    except Exception as e:  # noqa: BLE001
        err("sem reconhecimento de identidade (%s)" % e)

    threading.Thread(target=_stdin_loop, daemon=True).start()
    err("câmera %d aberta" % CAMERA)
    out("READY")

    t0 = time.time()
    last_emit = 0.0
    last_recog = 0.0
    last_owner = -1
    last_sim = 0.0
    no_face_emitted = 0.0
    gestures = HandGestures(mirror=GESTURE_MIRROR)
    res = None                # último resultado facial (reusado em FACE LOW)
    stats_t0 = time.time()
    stats_frames = 0
    stats_poses = {"open": 0, "fist": 0, "point": 0, "click": 0, "other": 0}
    # Última medida do polegar (ver gestures.thumb_ratio) — é o número que se
    # olha quando o clique dispara sozinho ou não dispara nunca.
    stats_thumb = 0.0
    preview_seq = 0
    wave_hist = []            # (t, x) do pulso da mão levantada
    last_wave = 0.0
    last_hand = 0.0
    last_hand_seen = 0.0      # qualquer mão no quadro, em qualquer altura
    last_face_seen = 0.0      # último quadro com rosto (a tela pode estar vazia)
    frame_i = 0
    last_process = 0.0
    WAVE_COOLDOWN = 6.0       # s entre acenos (não repetir a saudação)
    # Depuração do gesto: um registro por quadro com mão no ar. Fica DESLIGADA
    # por padrão — ligada, o arquivo cresce sem limite (o primeiro que rodou
    # assim passou de 5 MB). Ligue com TEAMWORK_FACE_DEBUG=1 quando precisar
    # calibrar limiares, e apague o arquivo depois.
    WAVE_DEBUG = os.path.join(BASE, "wave-debug.log")
    DEBUG_GESTURES = os.environ.get("TEAMWORK_FACE_DEBUG", "0") == "1"

    def dbg(text):
        if not DEBUG_GESTURES:
            return
        try:
            with open(WAVE_DEBUG, "a") as fh:
                fh.write(text)
        except Exception:
            pass

    while not _cmd["quit"]:
        # `grab()` só tira o quadro da fila; `retrieve()` é quem decodifica.
        # Separar os dois é o que evita decodificar ~20 quadros por segundo
        # para jogá-los fora logo em seguida.
        if not cap.grab():
            time.sleep(0.05)
            continue

        now = time.time()
        # Em modo econômico (avatar fora da tela e sem gestos), o laço inteiro
        # desacelera — é o que transforma o trabalho poupado em CPU poupada.
        comandando = gestures.pointing or gestures.dragging
        if comandando:
            alvo_hz = PROCESS_HZ_FAST
        elif _cmd["face_full"] or _cmd["hands"]:
            alvo_hz = PROCESS_HZ
        else:
            alvo_hz = PROCESS_HZ_LOW
        if now - last_process < 1.0 / alvo_hz:
            continue        # descartado sem decodificar
        ok, frame = cap.retrieve()
        if not ok:
            continue
        last_process = now
        frame_i += 1
        hand_sample = None      # vale só para ESTE quadro
        hand_lms = None
        stats_frames += 1
        if now - stats_t0 >= 5.0:
            out("STATS " + json.dumps(
                {"fps": round(stats_frames / (now - stats_t0), 1),
                 "hand": stats_poses,
                 "thumb": round(stats_thumb, 2)},
                separators=(",", ":")))
            stats_t0 = now
            stats_frames = 0
            stats_poses = {"open": 0, "fist": 0, "point": 0,
                           "click": 0, "other": 0}
        rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        mp_image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
        ts = int((now - t0) * 1000)

        # O rosto move o avatar — e o avatar só existe na tela cheia e no
        # copiloto. Nos outros modos, animá-lo a 8 quadros por segundo é
        # calcular expressão para ninguém ver: em LOW, um quarto dos quadros
        # basta para saber que você está aí e que é você.
        # O rosto é barato, mas com a tela vazia há minutos não há motivo para
        # procurá-lo 12 vezes por segundo.
        if _cmd["face_full"] and not comandando:
            passo_rosto = 1
        elif now - last_face_seen > 10.0:
            passo_rosto = 8
        else:
            passo_rosto = 4
        face_now = frame_i % passo_rosto == 0
        if face_now:
            try:
                res = landmarker.detect_for_video(mp_image, ts)
            except Exception:
                continue
        elif res is None:
            continue

        # ---- mãos: gestos de janela e aceno -------------------------------
        # Com a mão à vista, roda em TODO quadro processado: tanto o aceno
        # quanto o deslize precisam de amostragem, e subamostrar perde o
        # movimento. Sem mão à vista, reveza (ver abaixo).
        if frame_i % 45 == 0:                       # heartbeat (loop vivo)
            dbg("alive f=%d hist=%d\n" % (frame_i, len(wave_hist)))
        # Procurar mão é o gasto dominante do processo (~39 ms por quadro,
        # medido — contra ~11 ms do rosto). E, na maior parte do tempo, não há
        # mão nenhuma no quadro: procurar a cada quadro é pagar o preço caro
        # para não achar nada.
        #
        # Então o intervalo cresce com o tempo sem ver mão. O preço é a
        # demora em NOTAR a mão que sobe — e ela é pequena perto do meio
        # segundo que o gesto de armar já exige:
        #   à vista/comandando : todo quadro  (o gesto precisa de amostragem)
        #   sem mão há 3 s     : 1 em 3       (~0,12 s para notar)
        #   sem mão há 15 s    : 1 em 6       (~0,25 s)
        #   sem ninguém na tela: 1 em 10      (~0,4 s; sem rosto, sem mão)
        sem_mao = now - last_hand_seen
        sem_rosto = now - last_face_seen
        if comandando or sem_mao < 3.0:
            passo_maos = 1
        elif sem_rosto > 10.0:
            passo_maos = 10
        elif sem_mao > 15.0:
            passo_maos = 6
        else:
            passo_maos = 3
        hands_now = _cmd["hands"] and frame_i % passo_maos == 0
        if hand_landmarker is not None and hands_now:
            try:
                hres = hand_landmarker.detect_for_video(mp_image, ts)
            except Exception as he:
                hres = None
                dbg("HANDERR %s\n" % str(he)[:80])
            # Gestos de janela: a mesma detecção de mão que serve ao aceno
            # alimenta o reconhecedor (ver gestures.py). Custo zero a mais —
            # o HandLandmarker já rodou neste quadro.
            if hres is not None and hres.hand_landmarks:
                # Com as duas no quadro, comanda a que está à frente. A
                # escolha usa os pontos da IMAGEM: é o tamanho aparente que
                # revela quem está mais perto.
                escolhida = escolher_mao(hres.hand_landmarks)
                hand_lms = hres.hand_landmarks[escolhida]

                # Já a POSE sai dos pontos em metros que o mesmo modelo
                # devolve de brinde (`hand_world_landmarks`): ali a distância
                # entre juntas é física, não projetada. Uma mão inclinada para
                # a câmera tem as distâncias encurtadas na imagem — era o que
                # fazia um polegar aberto medir como fechado.
                pose_lms = hand_lms
                if hres.hand_world_landmarks and \
                        escolhida < len(hres.hand_world_landmarks):
                    pose_lms = hres.hand_world_landmarks[escolhida]

                hand_sample = {
                    "x": hand_lms[0].x,
                    "y": hand_lms[0].y,
                    "pose": classify_pose(pose_lms),
                }
            if hand_sample is not None:
                last_hand_seen = now
                stats_poses[hand_sample["pose"]] = \
                    stats_poses.get(hand_sample["pose"], 0) + 1
                stats_thumb = thumb_ratio(pose_lms)

            # Espelho da mão (opt-in): o quadro vai pra tmpfs e os 21 pontos
            # pelo stdout — quem desenha o esqueleto é a interface, que tem o
            # tema e o antialiasing. Aqui só se paga o JPEG, e só enquanto há
            # mão no quadro.
            if _cmd["preview"] and hand_sample is not None:
                try:
                    if save_preview_frame(cv2, frame, PREVIEW_PATH):
                        preview_seq += 1
                        out("HAND " + json.dumps({
                            # x espelhado junto com a imagem, pra os pontos
                            # caírem em cima da mão certa.
                            "pts": [[round(1.0 - p.x, 4), round(p.y, 4)]
                                    for p in hand_lms],
                            "pose": hand_sample["pose"],
                            "frame": PREVIEW_PATH,
                            "seq": preview_seq,
                        }, separators=(",", ":")))
                except Exception as e:  # noqa: BLE001
                    dbg("PREVIEWERR %s\n" % str(e)[:80])
            for ev in gestures.update(now, hand_sample):
                out("GESTURE " + json.dumps(ev, separators=(",", ":")))

            got_hand = False
            if hres is not None and hres.hand_landmarks:
                wrist = hand_lms[0]                 # landmark 0 = pulso
                dbg("HAND x=%.3f y=%.3f pose=%s\n"
                    % (wrist.x, wrist.y,
                       hand_sample["pose"] if hand_sample else "?"))
                if wrist.y < 0.9:                   # mão em quase todo o quadro
                    wave_hist.append((now, wrist.x))
                    last_hand = now
                    got_hand = True
            if now - last_hand > 0.5:               # sem mão há um tempo: zera
                wave_hist = []
            wave_hist = [(t, x) for (t, x) in wave_hist if now - t < 2.0]
            if got_hand and len(wave_hist) >= 5:
                xs = [x for (_, x) in wave_hist]
                amp = max(xs) - min(xs)
                revs = 0
                for k in range(2, len(xs)):
                    d1 = xs[k - 1] - xs[k - 2]
                    d2 = xs[k] - xs[k - 1]
                    if d1 * d2 < 0 and abs(d2) > 0.008:
                        revs += 1
                dbg("n=%d amp=%.3f revs=%d\n" % (len(xs), amp, revs))
                if amp > 0.06 and revs >= 2 and now - last_wave > WAVE_COOLDOWN:
                    last_wave = now
                    wave_hist = []
                    out("WAVE")

        # Cadastro do dono (usa insightface no frame atual).
        if _cmd["enroll"]:
            _cmd["enroll"] = False
            if recog is not None:
                faces = recog.get(frame)
                if faces:
                    owner_emb = faces[0].normed_embedding
                    np.save(OWNER_PATH, owner_emb)
                    out("ENROLLED 1.0")
                    err("dono cadastrado")
                else:
                    out("ERR nenhum rosto pra cadastrar — aproxime-se da câmera")
            else:
                out("ERR reconhecimento indisponível (insightface não instalado)")

        if res.face_landmarks:
            last_face_seen = now
        else:
            if now - no_face_emitted > 0.5:
                no_face_emitted = now
                out("NOFACE")
            continue

        if now - last_emit < 1.0 / EMIT_HZ:
            continue
        if not face_now:
            continue        # nada novo do rosto neste quadro
        last_emit = now

        lms = res.face_landmarks[0]
        xs = [p.x for p in lms]
        ys = [p.y for p in lms]
        cx = (min(xs) + max(xs)) / 2.0
        cy = (min(ys) + max(ys)) / 2.0
        # posição no quadro [-1..1]; +x = rosto à direita da imagem.
        fx = round(cx * 2.0 - 1.0, 3)
        fy = round(cy * 2.0 - 1.0, 3)

        yaw = pitch = 0.0
        if res.facial_transformation_matrixes:
            yaw, pitch = head_pose(res.facial_transformation_matrixes[0])
            yaw = round(yaw, 3)
            pitch = round(pitch, 3)

        blend = {}
        if res.face_blendshapes:
            bs = {c.category_name: c.score for c in res.face_blendshapes[0]}
            blend = to_channels(bs)

        # Identidade (throttled — caro).
        #
        # Com a mão no quadro, adia: o insightface leva centenas de ms e trava
        # o laço inteiro, inclusive a leitura da mão. Cair de 8 para 3 quadros
        # no meio de um gesto é justamente o que se sente como "ele demora pra
        # ler minha mão". Passado RECOG_MAX_DEFER, roda de qualquer jeito.
        gesturing = hand_sample is not None and now - last_recog < RECOG_MAX_DEFER
        if (recog is not None and owner_emb is not None and not gesturing
                and now - last_recog > RECOG_EVERY):
            last_recog = now
            try:
                faces = recog.get(frame)
                if faces:
                    sim = float(np.dot(faces[0].normed_embedding, owner_emb))
                    last_sim = round(sim, 3)
                    last_owner = 1 if sim > 0.35 else 0
                else:
                    last_owner = -1
            except Exception:
                pass
        owner = last_owner if (recog is not None and owner_emb is not None) else -1

        out("FACE " + json.dumps({
            "x": fx, "y": fy, "yaw": yaw, "pitch": pitch,
            "owner": owner, "sim": last_sim, "blend": blend,
        }, separators=(",", ":")))

    cap.release()


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # noqa: BLE001
        err("fatal: %s" % exc)
        import traceback
        traceback.print_exc(file=sys.stderr)
        out("ERR " + str(exc)[:160])
        sys.exit(1)
