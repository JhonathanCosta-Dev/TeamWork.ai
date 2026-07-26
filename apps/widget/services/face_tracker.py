#!/usr/bin/env python3
"""Rastreamento facial por webcam para o avatar do Team Work AI.

Abre a câmera, roda o MediaPipe FaceLandmarker (posição do rosto, pose da
cabeça e blendshapes ARKit) e, se disponível, reconhecimento de identidade
(insightface). Emite os NÚMEROS derivados por stdout — os frames da câmera
NUNCA são gravados nem enviados a lugar nenhum (privacidade: 100% local).

Protocolo:
  stdin   "ENROLL"                cadastra o rosto atual como dono (salva embedding local)
          "QUIT"                  encerra
  stdout  "READY"                 câmera + modelos prontos
          "FACE <json>"           rosto detectado (throttled ~12 Hz):
                                    {x,y,       posição do rosto no quadro [-1..1]
                                     yaw,pitch, pose da cabeça do usuário [-1..1]
                                     owner,     1=dono, 0=outro, -1=sem identidade
                                     sim,       similaridade com o dono
                                     blend:{...} blendshapes mapeados p/ canais do avatar}
          "NOFACE"                nenhum rosto (throttled)
          "ENROLLED <sim>"        cadastro concluído
          "ERR <msg>"

Config por ambiente:
  TEAMWORK_FACE_CAMERA   índice da câmera (padrão 0)
  TEAMWORK_FACE_MODEL    caminho do face_landmarker.task
  TEAMWORK_FACE_DIR      pasta de dados (owner.npy)
"""
import json
import os
import sys
import threading
import time

BASE = os.environ.get(
    "TEAMWORK_FACE_DIR",
    os.path.join(os.environ.get("XDG_DATA_HOME", os.path.expanduser("~/.local/share")),
                 "teamwork-ai", "facetrack"),
)
MODEL = os.environ.get("TEAMWORK_FACE_MODEL", os.path.join(BASE, "face_landmarker.task"))
CAMERA = int(os.environ.get("TEAMWORK_FACE_CAMERA", "0"))
OWNER_PATH = os.path.join(BASE, "owner.npy")
EMIT_HZ = 12.0            # taxa máxima de emissão FACE
PROCESS_HZ = 15.0         # processa ~15 fps (a câmera entrega ~30) — poupa CPU
RECOG_EVERY = 3.0         # segundos entre checagens de identidade (é caro)


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


# Leitura de comandos do stdin numa thread (não bloqueia a captura).
_cmd = {"enroll": False, "quit": False}


def _stdin_loop():
    for line in sys.stdin:
        c = line.strip().upper()
        if c == "ENROLL":
            _cmd["enroll"] = True
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

    cap = cv2.VideoCapture(CAMERA)
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
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
                num_hands=1,
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
        recog.prepare(ctx_id=-1, det_size=(320, 320))
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
    wave_hist = []            # (t, x) do pulso da mão levantada
    last_wave = 0.0
    last_hand = 0.0
    frame_i = 0
    last_process = 0.0
    WAVE_COOLDOWN = 6.0       # s entre acenos (não repetir a saudação)
    WAVE_DEBUG = os.path.join(BASE, "wave-debug.log")

    while not _cmd["quit"]:
        ok, frame = cap.read()
        if not ok:
            time.sleep(0.05)
            continue

        now = time.time()
        # Limita o processamento (a câmera entrega ~30 fps; consumimos o frame
        # pra manter o buffer fresco, mas só processamos a ~PROCESS_HZ).
        if now - last_process < 1.0 / PROCESS_HZ:
            continue
        last_process = now
        rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        mp_image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
        ts = int((now - t0) * 1000)
        try:
            res = landmarker.detect_for_video(mp_image, ts)
        except Exception:
            continue

        # ---- detecção de ACENO (mão levantada oscilando na horizontal) ----
        # Roda em frames alternados pra poupar CPU; aceno é um gesto lento.
        # Roda a detecção de mão TODO frame processado (aceno precisa de
        # amostragem — subamostrar perde a oscilação).
        frame_i += 1
        if frame_i % 45 == 0:                       # heartbeat (loop vivo)
            try:
                with open(WAVE_DEBUG, "a") as f:
                    f.write("alive f=%d hist=%d\n" % (frame_i, len(wave_hist)))
            except Exception:
                pass
        if hand_landmarker is not None:
            try:
                hres = hand_landmarker.detect_for_video(mp_image, ts)
            except Exception as he:
                hres = None
                try:
                    with open(WAVE_DEBUG, "a") as f:
                        f.write("HANDERR %s\n" % str(he)[:80])
                except Exception:
                    pass
            got_hand = False
            if hres is not None and hres.hand_landmarks:
                wrist = hres.hand_landmarks[0][0]   # landmark 0 = pulso
                try:
                    with open(WAVE_DEBUG, "a") as f:
                        f.write("HAND x=%.3f y=%.3f\n" % (wrist.x, wrist.y))
                except Exception:
                    pass
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
                # Depuração: registra as métricas do gesto num arquivo local.
                try:
                    with open(WAVE_DEBUG, "a") as f:
                        f.write("n=%d amp=%.3f revs=%d\n" % (len(xs), amp, revs))
                except Exception:
                    pass
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

        if not res.face_landmarks:
            if now - no_face_emitted > 0.5:
                no_face_emitted = now
                out("NOFACE")
            continue

        if now - last_emit < 1.0 / EMIT_HZ:
            continue
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
        if recog is not None and owner_emb is not None and now - last_recog > RECOG_EVERY:
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
