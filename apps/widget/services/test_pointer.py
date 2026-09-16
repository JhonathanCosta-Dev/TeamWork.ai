#!/usr/bin/env python3
"""Testes do ponteiro virtual, com um dispositivo de mentira.

Ler os eventos do dispositivo de verdade exigiria o grupo `input` (a ACL da
sessão libera criar em /dev/uinput, mas não ler /dev/input/event*). Como o
`Pointer` fala com um destino qualquer que tenha `write`/`syn`, um duplo basta
para verificar o que de fato importa: a ORDEM dos eventos e o que acontece
quando o processo morre no meio de um arrasto.

O que estes testes NÃO afirmam: que o niri moveu a janela. Isso depende do
compositor e da janela sob o cursor — é a parte que só se confere na mão.

Rode com:  python3 apps/widget/services/test_pointer.py
"""
import unittest

from pointer import Pointer, run_commands


class Codes:
    """Os códigos que o evdev exporta, com nomes iguais."""
    EV_REL, EV_KEY, EV_SYN = 2, 1, 0
    REL_X, REL_Y = 0, 1
    BTN_LEFT, KEY_LEFTMETA = 272, 125


class FakeSink:
    def __init__(self):
        self.events = []

    def write(self, tipo, codigo, valor):
        self.events.append((tipo, codigo, valor))

    def syn(self):
        pass

    def keys(self):
        return [(c, v) for (t, c, v) in self.events if t == Codes.EV_KEY]

    def rels(self):
        return {c: v for (t, c, v) in self.events if t == Codes.EV_REL}


def novo():
    sink = FakeSink()
    return sink, Pointer(sink, Codes)


class Grab(unittest.TestCase):
    def test_super_vem_antes_do_botao(self):
        # O niri só lê o clique como "mover janela" se o modificador já
        # estiver pressionado — inverter a ordem faz o arrasto virar um
        # clique comum na janela.
        sink, p = novo()
        p.grab()
        self.assertEqual(sink.keys(),
                         [(Codes.KEY_LEFTMETA, 1), (Codes.BTN_LEFT, 1)])

    def test_grab_repetido_nao_dobra(self):
        sink, p = novo()
        p.grab()
        antes = len(sink.events)
        p.grab()
        self.assertEqual(len(sink.events), antes)

    def test_release_solta_botao_e_depois_o_modificador(self):
        sink, p = novo()
        p.grab()
        sink.events.clear()
        p.release()
        self.assertEqual(sink.keys(),
                         [(Codes.BTN_LEFT, 0), (Codes.KEY_LEFTMETA, 0)])

    def test_release_sem_grab_nao_faz_nada(self):
        sink, p = novo()
        p.release()
        self.assertEqual(sink.events, [])


class Clique(unittest.TestCase):
    """O polegar fechado é o botão do mouse — e botão não é arrasto."""

    def test_press_nao_manda_super(self):
        # A diferença entre clicar NA janela e mover A janela é exatamente
        # essa tecla: com Super, o niri arrasta em vez de clicar.
        sink, p = novo()
        p.press()
        self.assertEqual(sink.keys(), [(Codes.BTN_LEFT, 1)])

    def test_press_seguido_de_release_solta_so_o_botao(self):
        sink, p = novo()
        p.press()
        sink.events.clear()
        p.release()
        self.assertEqual(sink.keys(), [(Codes.BTN_LEFT, 0)])

    def test_manter_pressionado_permite_arrastar(self):
        # Polegar fechado + mão andando = seleção/arrasto, como num trackpad.
        sink, p = novo()
        p.press()
        p.move(10, 10)
        p.move(10, 10)
        self.assertEqual(p.holding, "click")
        self.assertEqual(sink.keys().count((Codes.BTN_LEFT, 0)), 0)

    def test_press_nao_dobra(self):
        sink, p = novo()
        p.press()
        antes = len(sink.events)
        p.press()
        self.assertEqual(len(sink.events), antes)

    def test_trocar_de_modo_solta_o_anterior(self):
        # Ignorar o pedido em silêncio (o que se fazia antes) deixava o botão
        # pressionado para sempre: o clique travava o desktop inteiro. Trocar
        # de modo solta o que estava preso primeiro.
        sink, p = novo()
        p.grab()
        sink.events.clear()
        p.press()
        self.assertEqual(sink.keys(),
                         [(Codes.BTN_LEFT, 0), (Codes.KEY_LEFTMETA, 0),
                          (Codes.BTN_LEFT, 1)])
        self.assertEqual(p.holding, "click")

    def test_clique_para_arrasto_solta_o_clique(self):
        # O caminho que travou de verdade: clicando (polegar fechado), a mão
        # fecha de vez e vira punho. Sem soltar antes, o botão ficava preso.
        sink, p = novo()
        p.press()
        sink.events.clear()
        p.grab()
        self.assertEqual(sink.keys(),
                         [(Codes.BTN_LEFT, 0),
                          (Codes.KEY_LEFTMETA, 1), (Codes.BTN_LEFT, 1)])
        self.assertEqual(p.holding, "drag")

    def test_repetir_o_mesmo_modo_continua_sem_efeito(self):
        sink, p = novo()
        p.press()
        antes = len(sink.events)
        p.press()
        self.assertEqual(len(sink.events), antes)
        p2sink, p2 = novo()
        p2.grab()
        antes2 = len(p2sink.events)
        p2.grab()
        self.assertEqual(len(p2sink.events), antes2)

    def test_release_de_clique_nao_solta_super_que_nao_pressionou(self):
        sink, p = novo()
        p.press()
        sink.events.clear()
        p.release()
        self.assertNotIn((Codes.KEY_LEFTMETA, 0), sink.keys())

    def test_protocolo_do_clique(self):
        sink, p = novo()
        run_commands(["PRESS", "MOVE 5 5", "RELEASE", "QUIT"], p)
        self.assertEqual(sink.keys(), [(Codes.BTN_LEFT, 1), (Codes.BTN_LEFT, 0)])

    def test_quit_com_clique_preso_solta(self):
        sink, p = novo()
        run_commands(["PRESS", "MOVE 5 5", "QUIT"], p)
        self.assertIn((Codes.BTN_LEFT, 0), sink.keys())
        self.assertIsNone(p.holding)


class Move(unittest.TestCase):
    def test_deslocamento_relativo(self):
        sink, p = novo()
        p.move(14, -9)
        self.assertEqual(sink.rels(), {Codes.REL_X: 14, Codes.REL_Y: -9})

    def test_eixo_zerado_nao_vira_evento(self):
        sink, p = novo()
        p.move(7, 0)
        self.assertEqual(sink.rels(), {Codes.REL_X: 7})

    def test_fracao_vira_inteiro(self):
        sink, p = novo()
        p.move(3.7, -2.2)
        self.assertEqual(sink.rels(), {Codes.REL_X: 3, Codes.REL_Y: -2})


class Protocolo(unittest.TestCase):
    def test_sequencia_de_arrasto(self):
        sink, p = novo()
        run_commands(["GRAB", "MOVE 10 5", "MOVE -4 2", "RELEASE", "QUIT"], p)
        self.assertEqual(sink.keys(),
                         [(Codes.KEY_LEFTMETA, 1), (Codes.BTN_LEFT, 1),
                          (Codes.BTN_LEFT, 0), (Codes.KEY_LEFTMETA, 0)])
        self.assertFalse(p.holding)

    def test_quit_no_meio_do_arrasto_solta(self):
        # O caso feio: sair com o botão preso deixa a janela grudada no
        # ponteiro e o Super travado.
        sink, p = novo()
        run_commands(["GRAB", "MOVE 10 10", "QUIT"], p)
        self.assertIn((Codes.BTN_LEFT, 0), sink.keys())
        self.assertIn((Codes.KEY_LEFTMETA, 0), sink.keys())
        self.assertFalse(p.holding)

    def test_fim_da_entrada_tambem_solta(self):
        # O widget morreu e o stdin fechou: mesma história.
        sink, p = novo()
        run_commands(["GRAB"], p)
        self.assertFalse(p.holding)

    def test_comando_malformado_nao_interrompe(self):
        sink, p = novo()
        run_commands(["MOVE nada", "BANANA", "", "MOVE 5 5", "QUIT"], p)
        self.assertEqual(sink.rels(), {Codes.REL_X: 5, Codes.REL_Y: 5})

    def test_comandos_aceitam_minusculas(self):
        sink, p = novo()
        run_commands(["grab", "move 3 3", "release", "quit"], p)
        self.assertIn((Codes.KEY_LEFTMETA, 1), sink.keys())


class GuardaDeOciosidade(unittest.TestCase):
    """A rede de segurança: ninguém fica com o botão preso por esquecimento."""

    def test_tique_sem_comando_chama_o_guarda(self):
        sink, p = novo()
        chamadas = []
        run_commands(["PRESS", None, None, "QUIT"], p,
                     on_idle=lambda ptr: chamadas.append(ptr.holding))
        self.assertEqual(chamadas, ["click", "click"])

    def test_guarda_pode_soltar(self):
        # Simula o guarda decidindo que passou tempo demais.
        sink, p = novo()
        run_commands(["PRESS", None, "QUIT"], p,
                     on_idle=lambda ptr: ptr.release())
        self.assertIsNone(p.holding)
        self.assertIn((Codes.BTN_LEFT, 0), sink.keys())

    def test_sem_guarda_o_tique_e_ignorado(self):
        sink, p = novo()
        run_commands([None, "PRESS", None, "QUIT"], p)
        self.assertIn((Codes.BTN_LEFT, 1), sink.keys())


if __name__ == "__main__":
    unittest.main(verbosity=2)
