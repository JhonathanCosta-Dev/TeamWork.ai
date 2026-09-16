#!/usr/bin/env python3
"""Testes do reconhecedor de gestos (sem câmera, sem MediaPipe).

Rode com:  python3 apps/widget/services/test_gestures.py
"""
import unittest

from gestures import (
    ARM_HOLD,
    HandGestures,
    POSE_FIST,
    POSE_OPEN,
    POSE_CLICK,
    POSE_POINT,
    classify_pose,
    SWIPE_COOLDOWN,
)


# --- mãos sintéticas -------------------------------------------------------

def hand_landmarks(extended):
    """21 pontos com os quatro dedos estendidos (True) ou dobrados (False).

    Geometria simplificada, mas fiel no que importa para o classificador: a
    ponta do dedo estendido fica bem mais longe do pulso que a junta da base;
    dobrada, fica mais perto.
    """
    pts = [(0.5, 1.0)] * 21
    pts[0] = (0.5, 1.0)               # pulso
    pts[9] = (0.5, 0.8)               # base do médio (escala da mão)
    pts[5], pts[13], pts[17] = (0.45, 0.8), (0.55, 0.8), (0.6, 0.8)
    for tip, mcp in ((8, 5), (12, 9), (16, 13), (20, 17)):
        bx, by = pts[mcp]
        # Estendido: ponta bem além da base. Dobrado: ponta aquém dela.
        pts[tip] = (bx, by - 0.25) if extended else (bx, by + 0.14)
    pts[4] = (0.35, 0.85)             # polegar (ignorado pelo classificador)
    return pts


def hand_pointer(polegar_aberto=True):
    """Mão de ponteiro: indicador e médio de pé, anelar e mindinho dobrados.

    O polegar decide o resto: aberto é só mover o cursor, fechado é o botão
    pressionado.
    """
    pts = hand_landmarks(True)
    for tip, mcp in ((16, 13), (20, 17)):
        bx, by = pts[mcp]
        pts[tip] = (bx, by + 0.14)
    pts[4] = (0.30, 0.82) if polegar_aberto else (0.47, 0.75)
    return pts


def feed(rec, start, samples, dt=0.06):
    """Alimenta o reconhecedor e devolve todos os eventos disparados."""
    events = []
    t = start
    for s in samples:
        events += rec.update(t, s)
        t += dt
    return events


def still(pose, seconds, dt=0.06, x=0.5, y=0.5):
    return [{"x": x, "y": y, "pose": pose}] * int(seconds / dt)


def slide(pose, x_from, x_to, steps=8, y=0.5):
    step = (x_to - x_from) / (steps - 1)
    return [{"x": x_from + step * i, "y": y, "pose": pose} for i in range(steps)]


def slide_v(pose, y_from, y_to, steps=8, x=0.5):
    step = (y_to - y_from) / (steps - 1)
    return [{"x": x, "y": y_from + step * i, "pose": pose} for i in range(steps)]


def names(events):
    return [e["name"] for e in events]


# Instante em que a mão termina de armar (mais uma folga curta). Gestos
# alimentados a partir daqui chegam DENTRO da janela de atividade.
AFTER_ARM = ARM_HOLD + 0.5


# --- classificação da pose -------------------------------------------------

class ClassifyPose(unittest.TestCase):
    def test_open_hand(self):
        self.assertEqual(classify_pose(hand_landmarks(True)), POSE_OPEN)

    def test_fist(self):
        self.assertEqual(classify_pose(hand_landmarks(False)), POSE_FIST)

    def test_garbage_is_not_a_pose(self):
        self.assertEqual(classify_pose([(0.5, 0.5)] * 21), "other")
        self.assertEqual(classify_pose([]), "other")

    def test_accepts_objects_with_x_y(self):
        class P:
            def __init__(self, x, y):
                self.x, self.y = x, y
        pts = [P(x, y) for (x, y) in hand_landmarks(True)]
        self.assertEqual(classify_pose(pts), POSE_OPEN)


# --- armar e desarmar ------------------------------------------------------

class Arming(unittest.TestCase):
    def test_open_hand_held_arms(self):
        rec = HandGestures()
        evs = feed(rec, 0.0, still(POSE_OPEN, ARM_HOLD + 0.3))
        self.assertIn("arm", names(evs))
        self.assertTrue(rec.armed)

    def test_fist_does_not_arm(self):
        rec = HandGestures()
        evs = feed(rec, 0.0, still(POSE_FIST, ARM_HOLD + 1.0))
        self.assertEqual(names(evs), [])
        self.assertFalse(rec.armed)

    def test_moving_hand_does_not_arm(self):
        # Mão aberta, mas balançando: é gesticular, não comandar.
        rec = HandGestures()
        wobble = []
        for i in range(30):
            wobble.append({"x": 0.5 + (0.09 if i % 2 else -0.09), "y": 0.5,
                           "pose": POSE_OPEN})
        self.assertNotIn("arm", names(feed(rec, 0.0, wobble)))
        self.assertFalse(rec.armed)

    def test_disarms_when_hand_leaves(self):
        rec = HandGestures()
        feed(rec, 0.0, still(POSE_OPEN, ARM_HOLD + 0.3))
        self.assertTrue(rec.armed)
        # Mão some: a cada quadro sem mão, o tempo corre.
        evs = []
        t = AFTER_ARM
        for _ in range(5):
            evs += rec.update(t, None)
            t += 1.0
        self.assertIn("disarm", names(evs))
        self.assertFalse(rec.armed)


# --- deslizes --------------------------------------------------------------

class Swipes(unittest.TestCase):
    def armed(self):
        rec = HandGestures(mirror=False)
        feed(rec, 0.0, still(POSE_OPEN, ARM_HOLD + 0.3))
        assert rec.armed
        return rec

    def test_swipe_right_open_hand(self):
        rec = self.armed()
        evs = feed(rec, AFTER_ARM, slide(POSE_OPEN, 0.5, 0.95))
        self.assertIn({"name": "swipe_right", "pose": POSE_OPEN}, evs)

    def test_swipe_left_open_hand(self):
        rec = self.armed()
        evs = feed(rec, AFTER_ARM, slide(POSE_OPEN, 0.5, 0.05))
        self.assertIn({"name": "swipe_left", "pose": POSE_OPEN}, evs)

    def test_mao_fechada_arrasta_em_vez_de_deslizar(self):
        # O deslize é só da mão ABERTA. Com a mão fechada o movimento é
        # arrasto — a janela acompanha, em vez de a área de trabalho rolar.
        rec = self.armed()
        evs = feed(rec, AFTER_ARM, slide(POSE_FIST, 0.5, 0.95))
        nomes = names(evs)
        self.assertIn("grab", nomes)
        self.assertFalse(any(n.startswith("swipe") for n in nomes))

    def test_swipe_up_and_down(self):
        rec = self.armed()
        self.assertIn("swipe_up", names(feed(rec, AFTER_ARM, slide_v(POSE_OPEN, 0.5, 0.05))))
        rec2 = self.armed()
        self.assertIn("swipe_down", names(feed(rec2, AFTER_ARM, slide_v(POSE_OPEN, 0.5, 0.95))))

    def test_mirror_flips_horizontal_direction(self):
        # A webcam vê você de frente: mover a mão para a SUA direita faz o x do
        # quadro diminuir. Espelhado (padrão), isso tem de sair como "direita".
        rec = HandGestures(mirror=True)
        feed(rec, 0.0, still(POSE_OPEN, ARM_HOLD + 0.3))
        evs = feed(rec, AFTER_ARM, slide(POSE_OPEN, 0.5, 0.05))
        self.assertIn("swipe_right", names(evs))

    def test_short_movement_is_not_a_swipe(self):
        rec = self.armed()
        self.assertEqual(names(feed(rec, AFTER_ARM, slide(POSE_OPEN, 0.48, 0.55))), [])

    def test_slow_drift_is_not_a_swipe(self):
        # Mesma distância, tempo longo: é a mão passeando, não um comando.
        rec = self.armed()
        evs = feed(rec, AFTER_ARM, slide(POSE_OPEN, 0.5, 0.95, steps=8), dt=0.5)
        self.assertNotIn("swipe_right", names(evs))

    def test_diagonal_is_ignored(self):
        rec = self.armed()
        diag = [{"x": 0.5 + 0.06 * i, "y": 0.5 + 0.06 * i, "pose": POSE_OPEN}
                for i in range(8)]
        self.assertEqual(names(feed(rec, AFTER_ARM, diag)), [])

    def test_wobble_is_not_a_swipe(self):
        # Vai e volta: deslocamento grande, mas sem direção — um aceno.
        rec = self.armed()
        wave = []
        for i in range(12):
            wave.append({"x": 0.35 if i % 2 else 0.65, "y": 0.5, "pose": POSE_OPEN})
        self.assertEqual(names(feed(rec, AFTER_ARM, wave)), [])

    def test_not_armed_means_no_swipe(self):
        rec = HandGestures(mirror=False)
        self.assertEqual(names(feed(rec, 0.0, slide(POSE_OPEN, 0.5, 0.95))), [])

    def test_cooldown_prevents_one_gesture_becoming_three(self):
        rec = self.armed()
        first = feed(rec, AFTER_ARM, slide(POSE_OPEN, 0.5, 0.95))
        self.assertEqual(len([n for n in names(first) if n.startswith("swipe")]), 1)
        # Logo em seguida, dentro do descanso: nada.
        immediate = feed(rec, AFTER_ARM + SWIPE_COOLDOWN / 2, slide(POSE_OPEN, 0.5, 0.95))
        self.assertEqual(names(immediate), [])


# --- arrasto: fecha a mão, a janela segue, abre a mão ----------------------

class Drag(unittest.TestCase):
    def armed(self):
        rec = HandGestures(mirror=False)
        feed(rec, 0.0, still(POSE_OPEN, ARM_HOLD + 0.3))
        assert rec.armed
        return rec

    def test_fechar_a_mao_pega(self):
        rec = self.armed()
        evs = feed(rec, AFTER_ARM, still(POSE_FIST, 0.2))
        self.assertEqual(names(evs)[0], "grab")
        self.assertTrue(rec.dragging)

    def test_pegar_nao_espera_a_mao_parar(self):
        # Um único quadro de punho já pega: exigir tempo aqui atrasaria o
        # movimento contínuo que vem logo depois.
        rec = self.armed()
        evs = feed(rec, AFTER_ARM, [{"x": 0.5, "y": 0.5, "pose": POSE_FIST}])
        self.assertIn("grab", names(evs))

    def test_movimento_com_a_mao_fechada_vira_drag(self):
        rec = self.armed()
        evs = feed(rec, AFTER_ARM, slide(POSE_FIST, 0.5, 0.8, steps=5))
        nomes = names(evs)
        self.assertEqual(nomes[0], "grab")
        self.assertIn("drag", nomes)
        passos = [e for e in evs if e["name"] == "drag"]
        self.assertTrue(all(d["dx"] > 0 for d in passos), "todos pra direita")

    def test_drag_acompanha_os_dois_eixos(self):
        rec = self.armed()
        amostras = [{"x": 0.5 + 0.05 * i, "y": 0.5 - 0.04 * i, "pose": POSE_FIST}
                    for i in range(4)]
        evs = feed(rec, AFTER_ARM, amostras)
        passos = [e for e in evs if e["name"] == "drag"]
        self.assertTrue(passos)
        self.assertGreater(passos[0]["dx"], 0)
        self.assertLess(passos[0]["dy"], 0)

    def test_abrir_a_mao_solta(self):
        rec = self.armed()
        evs = feed(rec, AFTER_ARM,
                   still(POSE_FIST, 0.2) + slide(POSE_FIST, 0.5, 0.7, steps=3)
                   + still(POSE_OPEN, 0.2))
        self.assertIn("release", names(evs))
        self.assertFalse(rec.dragging)

    def test_mao_sumindo_solta(self):
        # Baixar o braço não pode deixar a janela grudada no ponteiro.
        rec = self.armed()
        feed(rec, AFTER_ARM, still(POSE_FIST, 0.2))
        self.assertTrue(rec.dragging)
        evs = rec.update(AFTER_ARM + 3.0, None)
        self.assertIn("release", names(evs))
        self.assertFalse(rec.dragging)

    def test_mao_parada_nao_gera_drag(self):
        # Sem isto, o tremor natural faria a janela vibrar no lugar.
        rec = self.armed()
        evs = feed(rec, AFTER_ARM, still(POSE_FIST, 0.6))
        self.assertEqual(names(evs).count("drag"), 0)

    def test_nao_arrasta_sem_armar(self):
        rec = HandGestures(mirror=False)
        evs = feed(rec, 0.0, still(POSE_FIST, 1.0) + slide(POSE_FIST, 0.5, 0.9))
        self.assertEqual(names(evs), [])

    def test_durante_o_arrasto_nao_sai_swipe(self):
        # O movimento é do arrasto; virar comando de coluna no meio seria
        # a janela indo pra um lado e a área de trabalho pro outro.
        rec = self.armed()
        evs = feed(rec, AFTER_ARM, slide(POSE_FIST, 0.5, 0.95, steps=6))
        self.assertFalse(any(n.startswith("swipe") for n in names(evs)))


# --- ponteiro livre: dois dedos movem só o cursor --------------------------

class Ponteiro(unittest.TestCase):
    def armed(self):
        rec = HandGestures(mirror=False)
        feed(rec, 0.0, still(POSE_OPEN, ARM_HOLD + 0.3))
        assert rec.armed
        return rec

    def test_classifica_a_mao_de_ponteiro(self):
        self.assertEqual(classify_pose(hand_pointer(True)), POSE_POINT)

    def test_polegar_fechado_vira_clique(self):
        self.assertEqual(classify_pose(hand_pointer(False)), POSE_CLICK)

    def test_mao_de_ponteiro_comeca_a_apontar(self):
        rec = self.armed()
        evs = feed(rec, AFTER_ARM, still(POSE_POINT, 0.2))
        self.assertEqual(names(evs)[0], "point_start")
        self.assertTrue(rec.pointing)

    def test_movimento_move_o_cursor(self):
        rec = self.armed()
        evs = feed(rec, AFTER_ARM, slide(POSE_POINT, 0.5, 0.8, steps=5))
        nomes = names(evs)
        self.assertIn("move", nomes)
        passos = [e for e in evs if e["name"] == "move"]
        self.assertTrue(all(p["dx"] > 0 for p in passos))

    def test_apontar_nao_pega_janela(self):
        # É a diferença para o punho: mover o cursor não arrasta nada.
        rec = self.armed()
        evs = feed(rec, AFTER_ARM, slide(POSE_POINT, 0.5, 0.9, steps=5))
        self.assertNotIn("grab", names(evs))
        self.assertFalse(rec.dragging)

    def test_abrir_a_mao_encerra_o_apontar(self):
        rec = self.armed()
        evs = feed(rec, AFTER_ARM, still(POSE_POINT, 0.2) + still(POSE_OPEN, 0.2))
        self.assertIn("point_end", names(evs))
        self.assertFalse(rec.pointing)

    def test_mao_sumindo_encerra_o_apontar(self):
        rec = self.armed()
        feed(rec, AFTER_ARM, still(POSE_POINT, 0.2))
        evs = rec.update(AFTER_ARM + 3.0, None)
        self.assertIn("point_end", names(evs))

    def test_mao_parada_nao_move_o_cursor(self):
        rec = self.armed()
        evs = feed(rec, AFTER_ARM, still(POSE_POINT, 0.6))
        self.assertEqual(names(evs).count("move"), 0)

    def test_nao_aponta_sem_armar(self):
        rec = HandGestures(mirror=False)
        evs = feed(rec, 0.0, slide(POSE_POINT, 0.5, 0.9))
        self.assertEqual(names(evs), [])

    def test_durante_o_arrasto_a_pose_de_ponteiro_nao_assume(self):
        # Segurando uma janela, um quadro mal classificado como "V" não pode
        # largar a janela e virar movimento de cursor.
        rec = self.armed()
        feed(rec, AFTER_ARM, still(POSE_FIST, 0.2))
        self.assertTrue(rec.dragging)
        evs = feed(rec, AFTER_ARM + 0.3, still(POSE_POINT, 0.2))
        self.assertNotIn("point_start", names(evs))
        self.assertTrue(rec.dragging)


# --- o polegar é o botão ---------------------------------------------------

class BotaoDoPolegar(unittest.TestCase):
    def apontando(self):
        rec = HandGestures(mirror=False)
        feed(rec, 0.0, still(POSE_OPEN, ARM_HOLD + 0.3))
        feed(rec, AFTER_ARM, still(POSE_POINT, 0.2))
        assert rec.pointing
        return rec

    def test_fechar_o_polegar_pressiona(self):
        rec = self.apontando()
        evs = feed(rec, AFTER_ARM + 0.3, still(POSE_CLICK, 0.2))
        self.assertIn("click_down", names(evs))
        self.assertTrue(rec.clicking)

    def test_abrir_o_polegar_solta(self):
        rec = self.apontando()
        feed(rec, AFTER_ARM + 0.3, still(POSE_CLICK, 0.2))
        evs = feed(rec, AFTER_ARM + 0.6, still(POSE_POINT, 0.2))
        self.assertIn("click_up", names(evs))
        self.assertFalse(rec.clicking)

    def test_manter_fechado_segura_o_clique(self):
        # Um clique só na descida: manter fechado é segurar o botão, não
        # clicar repetidamente.
        rec = self.apontando()
        evs = feed(rec, AFTER_ARM + 0.3, still(POSE_CLICK, 1.2))
        self.assertEqual(names(evs).count("click_down"), 1)
        self.assertTrue(rec.clicking)

    def test_com_o_polegar_fechado_o_cursor_continua_andando(self):
        # É o que permite arrastar e selecionar, como num trackpad.
        rec = self.apontando()
        evs = feed(rec, AFTER_ARM + 0.3, slide(POSE_CLICK, 0.5, 0.8, steps=5))
        self.assertIn("click_down", names(evs))
        self.assertIn("move", names(evs))

    def test_sair_da_pose_com_o_polegar_fechado_solta(self):
        # Sem isto o botão ficaria preso e capturaria tudo o que viesse depois.
        rec = self.apontando()
        feed(rec, AFTER_ARM + 0.3, still(POSE_CLICK, 0.2))
        evs = feed(rec, AFTER_ARM + 0.6, still(POSE_OPEN, 0.2))
        nomes = names(evs)
        self.assertIn("click_up", nomes)
        self.assertIn("point_end", nomes)
        self.assertLess(nomes.index("click_up"), nomes.index("point_end"))

    def test_fechar_a_mao_durante_o_clique_solta_antes_de_pegar(self):
        # O bug que travou na prática: clicando, a mão fecha de vez e vira
        # punho. Se o clique não for solto aqui, o botão fica pressionado e o
        # desktop para de responder.
        rec = self.apontando()
        feed(rec, AFTER_ARM + 0.3, still(POSE_CLICK, 0.2))
        self.assertTrue(rec.clicking)
        evs = feed(rec, AFTER_ARM + 0.6, still(POSE_FIST, 0.2))
        nomes = names(evs)
        self.assertIn("click_up", nomes)
        self.assertIn("grab", nomes)
        self.assertLess(nomes.index("click_up"), nomes.index("grab"),
                        "solta o clique ANTES de pegar a janela")
        self.assertFalse(rec.clicking)
        self.assertFalse(rec.pointing)
        self.assertTrue(rec.dragging)

    def test_mao_sumindo_com_o_polegar_fechado_solta(self):
        rec = self.apontando()
        feed(rec, AFTER_ARM + 0.3, still(POSE_CLICK, 0.2))
        evs = rec.update(AFTER_ARM + 4.0, None)
        self.assertIn("click_up", names(evs))
        self.assertFalse(rec.clicking)


# --- taxa de quadros real -------------------------------------------------

# A máquina de referência processa ~6 quadros/s, não os 15 que o tracker mira:
# o custo de FaceLandmarker + HandLandmarker + identidade no mesmo laço derruba
# a taxa. Toda a calibragem tem de caber aí — a primeira versão exigia 4
# amostras numa janela de 0,45 s, o que a 6 Hz dá 2 ou 3, e nenhum deslize era
# reconhecido na prática, apesar de todos os testes passarem a 16 Hz.
SLOW_DT = 1.0 / 6.0


class RealFrameRate(unittest.TestCase):
    def armed_slow(self):
        rec = HandGestures(mirror=False)
        feed(rec, 0.0, still(POSE_OPEN, ARM_HOLD + 0.5, dt=SLOW_DT), dt=SLOW_DT)
        assert rec.armed, "não armou a 6 Hz"
        return rec

    def test_arms_at_six_hz(self):
        rec = HandGestures(mirror=False)
        evs = feed(rec, 0.0, still(POSE_OPEN, ARM_HOLD + 0.5, dt=SLOW_DT), dt=SLOW_DT)
        self.assertIn("arm", names(evs))

    def test_swipe_at_six_hz(self):
        rec = self.armed_slow()
        evs = feed(rec, ARM_HOLD + 0.7, slide(POSE_OPEN, 0.5, 0.95, steps=4),
                   dt=SLOW_DT)
        self.assertIn("swipe_right", names(evs))

    def test_arrasto_a_seis_hz(self):
        rec = self.armed_slow()
        evs = feed(rec, ARM_HOLD + 0.7,
                   [{"x": 0.5, "y": 0.5, "pose": POSE_FIST}]
                   + slide(POSE_FIST, 0.5, 0.9, steps=4), dt=SLOW_DT)
        self.assertIn("grab", names(evs))
        self.assertIn("drag", names(evs))

    def test_normal_frame_interval_does_not_break_the_trajectory(self):
        # O intervalo comum a 6 Hz (0,17 s) não pode contar como buraco: se
        # contasse, a trajetória seria descartada a cada quadro e nada jamais
        # seria reconhecido.
        rec = self.armed_slow()
        evs = feed(rec, ARM_HOLD + 0.7, slide(POSE_OPEN, 0.5, 0.95, steps=4),
                   dt=SLOW_DT)
        self.assertTrue(any(n.startswith("swipe") for n in names(evs)))


if __name__ == "__main__":
    unittest.main(verbosity=2)
