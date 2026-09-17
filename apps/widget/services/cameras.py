#!/usr/bin/env python3
"""Lista as câmeras que servem para capturar vídeo.

Cada webcam costuma expor mais de um `/dev/videoN`: um captura imagem, o outro
entrega metadados. Abrir o errado dá uma câmera que nunca produz quadro, e o
nome em `/sys` é idêntico nos dois — então a escolha não pode ser pelo nome.

O critério certo é perguntar ao driver, por `VIDIOC_QUERYCAP`, se aquele nó tem
`V4L2_CAP_VIDEO_CAPTURE`. É um ioctl simples, feito aqui com `struct` e
`fcntl` — sem instalar nada, o que importa porque isto roda no venv do
rastreamento e também fora dele.
"""
import fcntl
import glob
import json
import os
import struct
import sys

# struct v4l2_capability: driver[16], card[32], bus_info[32], version,
# capabilities, device_caps, reserved[3] — 104 bytes.
_CAP_FMT = "16s32s32sIII12x"
_CAP_SIZE = struct.calcsize(_CAP_FMT)

# _IOR('V', 0, struct v4l2_capability)
_VIDIOC_QUERYCAP = (2 << 30) | (_CAP_SIZE << 16) | (ord("V") << 8) | 0

V4L2_CAP_VIDEO_CAPTURE = 0x00000001
V4L2_CAP_DEVICE_CAPS = 0x80000000


def limpar_nome(bruto):
    """Tira a repetição que alguns drivers devolvem.

    A webcam integrada aqui se apresenta como "HD User Facing: HD User Facing"
    — o mesmo nome dos dois lados dos dois pontos. Mostrar isso na tela de
    configuração é feio e não informa nada.
    """
    nome = bruto.strip()
    if ":" in nome:
        esquerda, direita = (p.strip() for p in nome.split(":", 1))
        if esquerda and esquerda.lower() == direita.lower():
            return esquerda
    return nome


def _query(path):
    """(nome, é_captura) do dispositivo, ou None se não der para perguntar."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    except OSError:
        return None
    try:
        buf = fcntl.ioctl(fd, _VIDIOC_QUERYCAP, b"\0" * _CAP_SIZE)
    except OSError:
        return None
    finally:
        os.close(fd)

    _, card, _, _, caps, device_caps = struct.unpack(_CAP_FMT, buf)
    # `device_caps` descreve ESTE nó; `capabilities` descreve o aparelho
    # inteiro, e é por isso que ele não serve para escolher o nó certo.
    efetivo = device_caps if caps & V4L2_CAP_DEVICE_CAPS else caps
    nome = limpar_nome(card.split(b"\0")[0].decode("utf-8", "replace"))
    return nome, bool(efetivo & V4L2_CAP_VIDEO_CAPTURE)


def listar():
    """Câmeras de captura, em ordem de índice.

    Devolve [{"index": 0, "name": "...", "path": "/dev/video0"}]. O índice é o
    número do `/dev/videoN`, que é exatamente o que o OpenCV espera receber.
    """
    achadas = []
    for path in sorted(glob.glob("/dev/video*"),
                       key=lambda p: int("".join(c for c in p if c.isdigit()) or 0)):
        sufixo = "".join(c for c in os.path.basename(path) if c.isdigit())
        if not sufixo:
            continue
        info = _query(path)
        if info is None:
            continue
        nome, captura = info
        if not captura:
            continue
        achadas.append({"index": int(sufixo), "name": nome or path, "path": path})
    return achadas


def rotular(cameras):
    """Desambigua nomes repetidos ("HD Webcam" e "HD Webcam" viram #0 e #2)."""
    contagem = {}
    for c in cameras:
        contagem[c["name"]] = contagem.get(c["name"], 0) + 1
    for c in cameras:
        c["label"] = (f'{c["name"]} (#{c["index"]})'
                      if contagem[c["name"]] > 1 else c["name"])
    return cameras


if __name__ == "__main__":
    print(json.dumps(rotular(listar()), ensure_ascii=False))
    sys.exit(0)
