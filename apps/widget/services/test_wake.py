#!/usr/bin/env python3
"""Testes do gatilho de ativação por voz (sem microfone, sem modelo).

`is_wake_grammar` e `is_wake_free` só recebem o JSON do reconhecedor, então dá
para testá-los com as transcrições de verdade — inclusive as que causaram o
problema real: um vídeo tocando no alto-falante falava do "Jorginho", acordava
a escuta e mandava a frase seguinte como se fosse do usuário.

Rode com:  python3 apps/widget/services/test_wake.py
"""
import json
import unittest

from wake_listener import is_wake_free, is_wake_grammar


def heard(text):
    """Como o Vosk devolve uma transcrição final."""
    return json.dumps({"text": text})


# Falas reais que o microfone captou de um vídeo tocando, e que viraram
# mensagens para o agente.
FALAS_DE_VIDEO = [
    "para quem não conhece o jorginho ele é um dos primeiros a ser criado",
    "acompanhe o curso em www jorginho com br",
    "isso aí vai se tornar uma marca jorginho",
    "jorginho",
]


class VideoNaoAcorda(unittest.TestCase):
    def test_gramatica_ignora_fala_de_video(self):
        for fala in FALAS_DE_VIDEO:
            with self.subTest(fala=fala):
                self.assertFalse(is_wake_grammar(heard(fala)))

    def test_caminho_livre_ignora_fala_de_video(self):
        for fala in FALAS_DE_VIDEO:
            with self.subTest(fala=fala):
                self.assertFalse(is_wake_free(heard(fala)))

    def test_nome_sozinho_nao_basta(self):
        # Era exatamente esta a brecha.
        self.assertFalse(is_wake_grammar(heard("jorginho")))
        self.assertFalse(is_wake_free(heard("jorge")))


class ChamadoAcorda(unittest.TestCase):
    def test_chamamento_direto(self):
        for fala in ("fala jorginho", "ei jorginho", "oi jorge",
                     "fala com jorginho", "fale jorginho"):
            with self.subTest(fala=fala):
                self.assertTrue(is_wake_grammar(heard(fala)))

    def test_grafias_que_o_modelo_pequeno_produz(self):
        # O Vosk erra a grafia do apelido; o casamento é tolerante.
        for fala in ("fala jorgim", "fala jorgin", "ei gorginho"):
            with self.subTest(fala=fala):
                self.assertTrue(is_wake_grammar(heard(fala)))

    def test_caminho_livre_com_chamamento(self):
        self.assertTrue(is_wake_free(heard("fala jorginho tudo bem")))

    def test_sem_o_nome_nao_acorda(self):
        self.assertFalse(is_wake_grammar(heard("fala aí")))
        self.assertFalse(is_wake_free(heard("ei você")))

    def test_transcricao_vazia_ou_quebrada(self):
        self.assertFalse(is_wake_grammar(heard("")))
        self.assertFalse(is_wake_grammar("{isso não é json"))
        self.assertFalse(is_wake_free(heard("[unk] [unk]")))


if __name__ == "__main__":
    unittest.main(verbosity=2)
