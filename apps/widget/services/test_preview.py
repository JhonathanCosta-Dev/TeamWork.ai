#!/usr/bin/env python3
"""Teste da gravação do quadro do espelho da mão (sem câmera).

A webcam é exclusiva: com o widget aberto ela está ocupada e nenhum teste que
dependa dela roda. Como `save_preview_frame` recebe o quadro pronto, dá para
alimentá-la com uma imagem sintética e verificar o que importa — que grava, que
espelha e que a troca é atômica.

Rode com:  python3 apps/widget/services/test_preview.py
(precisa do venv do rastreamento: ~/.local/share/teamwork-ai/facetrack/venv)
"""
import os
import tempfile
import unittest

import cv2
import numpy as np

from face_tracker import save_preview_frame


def frame_com_marca():
    """640x480 preto com um bloco branco só no CANTO ESQUERDO."""
    img = np.zeros((480, 640, 3), dtype=np.uint8)
    img[0:80, 0:80] = 255
    return img


class SavePreviewFrame(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, "sub", "handcam.jpg")

    def test_grava_e_cria_a_pasta(self):
        self.assertTrue(save_preview_frame(cv2, frame_com_marca(), self.path))
        self.assertTrue(os.path.exists(self.path))
        self.assertGreater(os.path.getsize(self.path), 0)

    def test_reduz_para_a_largura_pedida(self):
        save_preview_frame(cv2, frame_com_marca(), self.path, width=160)
        img = cv2.imread(self.path)
        self.assertEqual(img.shape[1], 160)
        self.assertEqual(img.shape[0], 120)     # mantém a proporção 4:3

    def test_espelha_horizontalmente(self):
        # A marca estava na esquerda; espelhada, tem de sair na direita.
        save_preview_frame(cv2, frame_com_marca(), self.path)
        img = cv2.imread(self.path)
        h, w = img.shape[:2]
        esquerda = img[0:h // 6, 0:w // 8].mean()
        direita = img[0:h // 6, -(w // 8):].mean()
        self.assertGreater(direita, esquerda + 100,
                           "o quadro precisa sair espelhado")

    def test_nao_deixa_arquivo_temporario_para_tras(self):
        save_preview_frame(cv2, frame_com_marca(), self.path)
        self.assertFalse(os.path.exists(self.path + ".tmp"))

    def test_sobrescreve_sem_quebrar(self):
        for _ in range(3):
            self.assertTrue(save_preview_frame(cv2, frame_com_marca(), self.path))
        self.assertIsNotNone(cv2.imread(self.path))

    def test_quadro_vazio_nao_grava(self):
        vazio = np.zeros((0, 0, 3), dtype=np.uint8)
        self.assertFalse(save_preview_frame(cv2, vazio, self.path))
        self.assertFalse(os.path.exists(self.path))


if __name__ == "__main__":
    unittest.main(verbosity=2)
