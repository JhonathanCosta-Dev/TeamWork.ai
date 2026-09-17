#!/usr/bin/env python3
"""Testes da listagem de câmeras.

A parte que fala com o driver depende do hardware; o que dá para fixar em teste
é o tratamento do que ele devolve — que é justamente onde estavam as
armadilhas: nomes repetidos entre nós da MESMA webcam e o nome duplicado que
alguns drivers mandam.

Rode com:  python3 apps/widget/services/test_cameras.py
"""
import unittest

from cameras import limpar_nome, rotular


class LimparNome(unittest.TestCase):
    def test_repeticao_dos_dois_lados_vira_uma(self):
        self.assertEqual(limpar_nome("HD User Facing: HD User Facing"),
                         "HD User Facing")

    def test_nome_simples_fica_igual(self):
        self.assertEqual(limpar_nome("HD Pro Webcam C920"), "HD Pro Webcam C920")

    def test_dois_pontos_com_conteudo_diferente_e_preservado(self):
        # "Integrada: frontal" descreve duas coisas — cortar perderia metade.
        self.assertEqual(limpar_nome("Integrada: frontal"), "Integrada: frontal")

    def test_espacos_e_vazio(self):
        self.assertEqual(limpar_nome("  C920  "), "C920")
        self.assertEqual(limpar_nome(""), "")


class Rotular(unittest.TestCase):
    def test_nomes_distintos_nao_ganham_numero(self):
        r = rotular([{"index": 0, "name": "Integrada", "path": "/dev/video0"},
                     {"index": 2, "name": "C920", "path": "/dev/video2"}])
        self.assertEqual([c["label"] for c in r], ["Integrada", "C920"])

    def test_nomes_iguais_ganham_o_indice(self):
        # Duas webcams do mesmo modelo: sem o número, a lista teria duas
        # opções idênticas e escolher seria adivinhação.
        r = rotular([{"index": 0, "name": "C920", "path": "/dev/video0"},
                     {"index": 2, "name": "C920", "path": "/dev/video2"}])
        self.assertEqual([c["label"] for c in r], ["C920 (#0)", "C920 (#2)"])

    def test_lista_vazia(self):
        self.assertEqual(rotular([]), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
