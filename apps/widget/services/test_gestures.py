#!/usr/bin/env python3
"""Testes do reconhecedor de gestos (sem câmera, sem MediaPipe).

Rode com:  python3 apps/widget/services/test_gestures.py
"""
import unittest

from gestures import (
    ARM_HOLD,
    POSE_SCROLL,
    SCROLL_AXIS_LOCK,
    thumb_ratio,
    escolher_mao,
    tamanho_palma,
    HandGestures,
    POSE_FIST,
    POSE_OPEN,
    POSE_CLICK,
    POSE_OTHER,
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


def hand_scroll():
    """Quatro dedos de pé com o polegar recolhido contra a palma."""
    pts = hand_landmarks(True)
    pts[4] = (0.52, 0.80)
    return pts


def hand_aberta():
    """Mão aberta de verdade: os quatro dedos E o polegar para fora."""
    pts = hand_landmarks(True)
    pts[4] = (0.22, 0.83)
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


# --- profundidade: a perspectiva mente -------------------------------------

def girar_para_a_camera(mao, graus):
    """Inclina a mão em torno do eixo horizontal, em 3D de verdade.

    Devolve (pontos_em_3d, pontos_como_a_camera_ve). Os 3D são o que o modelo
    entrega em `hand_world_landmarks`; os 2D são a sombra deles na imagem —
    e é aí que a perspectiva come as distâncias.
    """
    import math
    r = math.radians(graus)
    tres_d, projetada = [], []
    for (x, y) in mao:
        dy = y - 0.9
        ny = dy * math.cos(r)
        nz = dy * math.sin(r)
        tres_d.append((x, 0.9 + ny, nz))
        projetada.append((x, 0.9 + ny))       # a câmera só vê x e y
    return tres_d, projetada


class Profundidade(unittest.TestCase):
    def test_medida_em_metros_nao_muda_com_a_inclinacao(self):
        # É o ganho de usar os pontos 3D: a mão inclinada continua sendo a
        # mesma mão. Em 2D, a mesma pose muda de número conforme o ângulo —
        # foi assim que um polegar aberto passou a medir como fechado.
        mao = hand_pointer(polegar_aberto=True)
        base = thumb_ratio([(x, y, 0.0) for (x, y) in mao])
        for graus in (20, 40, 60):
            tres_d, _ = girar_para_a_camera(mao, graus)
            self.assertAlmostEqual(
                thumb_ratio(tres_d), base, places=6,
                msg=f"a medida 3D mudou ao inclinar {graus}°")

    def test_medida_plana_se_perde_com_a_inclinacao(self):
        mao = hand_pointer(polegar_aberto=True)
        base = thumb_ratio(mao)
        _, projetada = girar_para_a_camera(mao, 60)
        self.assertNotAlmostEqual(
            thumb_ratio(projetada), base, places=2,
            msg="se o 2D não mudasse, não haveria motivo para usar o 3D")

    def test_pose_continua_certa_com_pontos_3d(self):
        tres_d, _ = girar_para_a_camera(hand_landmarks(True), 45)
        self.assertEqual(classify_pose(tres_d), POSE_OPEN)
        tres_d_punho, _ = girar_para_a_camera(hand_landmarks(False), 45)
        self.assertEqual(classify_pose(tres_d_punho), POSE_FIST)

    def test_pontos_2d_continuam_valendo(self):
        # Sem profundidade (pares simples), tudo segue como antes: z entra
        # como zero e nada muda.
        self.assertEqual(classify_pose(hand_landmarks(True)), POSE_OPEN)
        self.assertEqual(classify_pose(hand_landmarks(False)), POSE_FIST)

    def test_proximidade_ignora_a_profundidade(self):
        # `tamanho_palma` mede o tamanho APARENTE: é ele que revela quem está
        # mais perto. Se levasse o z em conta, toda mão mediria igual.
        longe = afastar(hand_landmarks(True), 0.5)
        com_z = [(x, y, 0.4) for (x, y) in longe]
        self.assertAlmostEqual(tamanho_palma(longe), tamanho_palma(com_z), places=6)


# --- rolagem com quatro dedos ---------------------------------------------

class Rolagem(unittest.TestCase):
    def armado(self):
        rec = HandGestures(mirror=False)
        feed(rec, 0.0, still(POSE_OPEN, ARM_HOLD + 0.3))
        assert rec.armed
        return rec

    def test_polegar_separa_rolagem_de_mao_aberta(self):
        # Os quatro dedos são iguais nas duas; o que muda é o polegar. Sem
        # essa distinção, armar a mão já começaria a rolar a página.
        self.assertEqual(classify_pose(hand_aberta()), POSE_OPEN)
        self.assertEqual(classify_pose(hand_scroll()), POSE_SCROLL)

    def test_quatro_dedos_comecam_a_rolar(self):
        rec = self.armado()
        evs = feed(rec, AFTER_ARM, still(POSE_SCROLL, 0.2))
        self.assertEqual(names(evs)[0], "scroll_start")
        self.assertTrue(rec.scrolling)

    def test_descer_a_mao_rola(self):
        rec = self.armado()
        evs = feed(rec, AFTER_ARM, slide_v(POSE_SCROLL, 0.4, 0.75, steps=5))
        passos = [e for e in evs if e["name"] == "scroll"]
        self.assertTrue(passos)
        self.assertTrue(all(p["axis"] == "v" for p in passos))
        self.assertTrue(all(p["d"] > 0 for p in passos), "todos para baixo")

    def test_subir_a_mao_rola_ao_contrario(self):
        rec = self.armado()
        evs = feed(rec, AFTER_ARM, slide_v(POSE_SCROLL, 0.75, 0.4, steps=5))
        passos = [e for e in evs if e["name"] == "scroll"]
        self.assertTrue(passos)
        self.assertTrue(all(p["axis"] == "v" for p in passos))
        self.assertTrue(all(p["d"] < 0 for p in passos), "todos para cima")

    def test_mao_para_a_direita_rola_de_lado(self):
        rec = self.armado()
        evs = feed(rec, AFTER_ARM, slide(POSE_SCROLL, 0.3, 0.8, steps=5))
        passos = [e for e in evs if e["name"] == "scroll"]
        self.assertTrue(passos)
        self.assertTrue(all(p["axis"] == "h" for p in passos))
        self.assertTrue(all(p["d"] > 0 for p in passos), "todos para a direita")

    def test_mao_para_a_esquerda_rola_ao_contrario(self):
        rec = self.armado()
        evs = feed(rec, AFTER_ARM, slide(POSE_SCROLL, 0.8, 0.3, steps=5))
        passos = [e for e in evs if e["name"] == "scroll"]
        self.assertTrue(passos)
        self.assertTrue(all(p["axis"] == "h" for p in passos))
        self.assertTrue(all(p["d"] < 0 for p in passos), "todos para a esquerda")

    def test_o_eixo_trava_no_que_comecou(self):
        # A mão nunca anda reto. Sem travar o eixo, cada tremida viraria
        # rolagem no outro sentido e a página fugia na diagonal.
        rec = self.armado()
        # Começa claramente na horizontal...
        evs = feed(rec, AFTER_ARM, slide(POSE_SCROLL, 0.3, 0.7, steps=4))
        self.assertEqual(rec._scroll_axis, "h")
        # ...e depois desce: nada disso pode virar rolagem vertical.
        evs += feed(rec, AFTER_ARM + 0.5,
                    slide_v(POSE_SCROLL, 0.4, 0.9, steps=4, x=0.7))
        passos = [e for e in evs if e["name"] == "scroll"]
        self.assertTrue(passos)
        self.assertTrue(all(p["axis"] == "h" for p in passos))

    def test_o_eixo_destrava_quando_o_gesto_recomeca(self):
        rec = self.armado()
        feed(rec, AFTER_ARM, slide(POSE_SCROLL, 0.3, 0.7, steps=4))
        self.assertEqual(rec._scroll_axis, "h")
        # Abre o polegar (encerra) e volta aos quatro dedos, agora subindo.
        feed(rec, AFTER_ARM + 0.5, still(POSE_OPEN, 0.5))
        evs = feed(rec, AFTER_ARM + 1.2, slide_v(POSE_SCROLL, 0.8, 0.3, steps=4))
        passos = [e for e in evs if e["name"] == "scroll"]
        self.assertTrue(passos)
        self.assertTrue(all(p["axis"] == "v" for p in passos))

    def test_tremida_curta_nao_escolhe_eixo_nenhum(self):
        # Abaixo do limiar de trava, o gesto ainda não disse para onde vai —
        # e nada pode rolar, ou o ruído da mão escolheria por você.
        rec = self.armado()
        evs = feed(rec, AFTER_ARM, slide_v(POSE_SCROLL, 0.50, 0.505, steps=4))
        self.assertEqual([e for e in evs if e["name"] == "scroll"], [])
        self.assertIsNone(rec._scroll_axis)

    def test_mao_parada_nao_rola(self):
        rec = self.armado()
        evs = feed(rec, AFTER_ARM, still(POSE_SCROLL, 0.8))
        self.assertEqual(names(evs).count("scroll"), 0)

    def test_abrir_o_polegar_encerra(self):
        rec = self.armado()
        feed(rec, AFTER_ARM, still(POSE_SCROLL, 0.2))
        evs = feed(rec, AFTER_ARM + 0.4, still(POSE_OPEN, 0.5))
        self.assertIn("scroll_end", names(evs))
        self.assertFalse(rec.scrolling)

    def test_um_quadro_lido_errado_nao_encerra(self):
        # Um dedo mal lido por um quadro é rotina. Se isso encerrasse o gesto,
        # recomeçar custaria a zona morta da trava inteira — a página travava
        # no meio do movimento.
        rec = self.armado()
        feed(rec, AFTER_ARM, slide_v(POSE_SCROLL, 0.35, 0.60, steps=4))
        self.assertEqual(rec._scroll_axis, "v")
        evs = feed(rec, AFTER_ARM + 0.5, still(POSE_OTHER, 0.06, dt=0.06))
        self.assertNotIn("scroll_end", names(evs))
        self.assertTrue(rec.scrolling)
        self.assertEqual(rec._scroll_axis, "v", "o eixo não pode se perder")

    def test_depois_da_folga_encerra_mesmo(self):
        rec = self.armado()
        feed(rec, AFTER_ARM, slide_v(POSE_SCROLL, 0.35, 0.60, steps=4))
        evs = feed(rec, AFTER_ARM + 0.5, still(POSE_OTHER, 0.5))
        self.assertIn("scroll_end", names(evs))
        self.assertFalse(rec.scrolling)

    def test_o_quadro_que_escolhe_o_eixo_ja_rola(self):
        # Anunciar a escolha sem rolar gastava um quadro — mais um engasgo no
        # começo de cada gesto.
        rec = self.armado()
        evs = feed(rec, AFTER_ARM, slide_v(POSE_SCROLL, 0.35, 0.80, steps=6))
        nomes = names(evs)
        i = nomes.index("scroll_axis")
        self.assertEqual(nomes[i + 1], "scroll")
        # E o movimento que escolheu o eixo não se perde: ele sai inteiro
        # nesse primeiro passo, por isso vale ao menos a zona morta da trava.
        self.assertGreaterEqual(abs(evs[i + 1]["d"]), SCROLL_AXIS_LOCK)

    def test_mao_sumindo_encerra(self):
        rec = self.armado()
        feed(rec, AFTER_ARM, still(POSE_SCROLL, 0.2))
        evs = rec.update(AFTER_ARM + 4.0, None)
        self.assertIn("scroll_end", names(evs))

    def test_nao_rola_sem_armar(self):
        rec = HandGestures(mirror=False)
        evs = feed(rec, 0.0, slide_v(POSE_SCROLL, 0.4, 0.8))
        self.assertEqual(names(evs), [])

    def test_fechar_a_mao_ao_terminar_encerra_a_rolagem(self):
        # Relaxar a mão depois de rolar vira punho — é o jeito mais comum de
        # terminar. O punho pega a janela; se a rolagem não for encerrada
        # junto, ela fica ligada para sempre e a página rola sozinha.
        rec = self.armado()
        feed(rec, AFTER_ARM, slide_v(POSE_SCROLL, 0.35, 0.65, steps=4))
        self.assertTrue(rec.scrolling)
        evs = feed(rec, AFTER_ARM + 0.5, still(POSE_FIST, 0.3))
        nomes = names(evs)
        self.assertIn("scroll_end", nomes)
        self.assertFalse(rec.scrolling)
        # E o fim da rolagem vem ANTES do grab: a interface não pode ficar
        # marcando "rolando" e "arrastando" ao mesmo tempo.
        self.assertLess(nomes.index("scroll_end"), nomes.index("grab"))

    def test_durante_o_arrasto_a_rolagem_nao_assume(self):
        rec = self.armado()
        feed(rec, AFTER_ARM, still(POSE_FIST, 0.2))
        self.assertTrue(rec.dragging)
        evs = feed(rec, AFTER_ARM + 0.3, still(POSE_SCROLL, 0.2))
        self.assertNotIn("scroll_start", names(evs))
        self.assertTrue(rec.dragging)


# --- previsão: adiantar sem passar do ponto --------------------------------

class Previsao(unittest.TestCase):
    """Compensar a latência é bom; ultrapassar o alvo é pior que chegar tarde."""

    def _posicoes(self, rec, amostras, dt=1 / 25):
        """Posições acumuladas do cursor durante o movimento."""
        t = ARM_HOLD + 0.5
        pos = 0.0
        for a in amostras:
            for ev in rec.update(t, a):
                if ev["name"] == "move":
                    pos += ev["dx"]
            t += dt
        return pos

    def armado(self):
        rec = HandGestures(mirror=False)
        feed(rec, 0.0, still(POSE_OPEN, ARM_HOLD + 0.3))
        return rec

    def test_movimento_constante_nao_ultrapassa(self):
        # A mão anda 0,3 e para. O cursor não pode ter andado mais que isso
        # com folga: a previsão adianta durante o movimento, mas o total tem
        # de bater com o percurso real.
        rec = self.armado()
        amostras = [{"x": 0.5 + 0.03 * i, "y": 0.5, "pose": POSE_POINT}
                    for i in range(11)]
        amostras += still(POSE_POINT, 1.2, x=0.8, y=0.5)   # freia e fica parada
        andou = self._posicoes(rec, amostras)
        self.assertLess(abs(andou - 0.3), 0.02,
                        f"o cursor andou {andou:.3f} para uma mão que andou 0,300")

    def test_parada_brusca_volta_ao_lugar(self):
        # Freada seca: a previsão chega a passar, mas tem de voltar — e o
        # resultado final precisa bater com onde a mão parou.
        rec = self.armado()
        amostras = [{"x": 0.4 + 0.05 * i, "y": 0.5, "pose": POSE_POINT}
                    for i in range(6)]
        amostras += still(POSE_POINT, 1.5, x=0.65, y=0.5)
        andou = self._posicoes(rec, amostras)
        self.assertLess(abs(andou - 0.25), 0.02,
                        f"sobrou {andou - 0.25:+.3f} depois da freada")

    def test_salto_previsto_tem_teto(self):
        from gestures import PREDICAO_MAXIMA, PREDICAO_SEGUNDOS, OneEuro
        f = OneEuro()
        t = 0.0
        # Velocidade absurda (quadro mal estimado): a projeção não pode
        # mandar o cursor para o outro lado da tela.
        for i in range(6):
            f(0.1 + i * 0.4, t)
            t += 1 / 25
        salto = abs(f.velocidade() * PREDICAO_SEGUNDOS)
        self.assertGreater(salto, PREDICAO_MAXIMA,
                           "o teste precisa de uma velocidade que estoure o teto")
        # E o limitador segura:
        from gestures import _limitar
        self.assertLessEqual(abs(_limitar(f.velocidade() * PREDICAO_SEGUNDOS,
                                          PREDICAO_MAXIMA)), PREDICAO_MAXIMA)

    def test_mao_parada_nao_gera_previsao(self):
        rec = self.armado()
        evs = feed(rec, AFTER_ARM, still(POSE_POINT, 1.0))
        self.assertEqual(names(evs).count("move"), 0,
                         "sem movimento não há o que prever")


# --- qual mão comanda -----------------------------------------------------

def afastar(mao, fator):
    """A mesma mão, menor no quadro — como se estivesse mais longe."""
    return [(0.5 + (x - 0.5) * fator, 0.9 + (y - 0.9) * fator) for (x, y) in mao]


class MaoMaisProxima(unittest.TestCase):
    def test_escolhe_a_maior_no_quadro(self):
        perto = hand_landmarks(True)
        longe = afastar(perto, 0.45)
        self.assertEqual(escolher_mao([longe, perto]), 1)
        self.assertEqual(escolher_mao([perto, longe]), 0)

    def test_sem_maos(self):
        self.assertIsNone(escolher_mao([]))

    def test_uma_mao_so(self):
        self.assertEqual(escolher_mao([hand_landmarks(True)]), 0)

    def test_punho_perto_ganha_de_mao_aberta_longe(self):
        # A armadilha: medir a mão INTEIRA faria o punho (compacto) parecer
        # menor que uma mão aberta ao fundo, e quem comanda passaria a
        # depender da pose em vez da distância. Por isso a régua é a palma,
        # que não encolhe ao fechar a mão.
        punho_perto = hand_landmarks(False)
        aberta_longe = afastar(hand_landmarks(True), 0.6)
        self.assertEqual(escolher_mao([aberta_longe, punho_perto]), 1)

    def test_a_pose_nao_muda_o_tamanho_da_palma(self):
        aberta = tamanho_palma(hand_landmarks(True))
        fechada = tamanho_palma(hand_landmarks(False))
        self.assertAlmostEqual(aberta, fechada, places=6,
                               msg="a palma é rígida: fechar a mão não a encolhe")

    def test_lixo_nao_quebra(self):
        self.assertEqual(tamanho_palma([]), 0.0)
        self.assertEqual(escolher_mao([[], hand_landmarks(True)]), 1)


# --- suavização do movimento ----------------------------------------------

class Suavizacao(unittest.TestCase):
    """O filtro 1€: tira tremor parado, mas não atrasa movimento de verdade."""

    def test_tremor_parado_e_reduzido(self):
        from gestures import OneEuro
        f = OneEuro()
        t = 0.0
        entrada, saida = [], []
        for i in range(30):
            # Mão "parada" com tremor de ±0,01 (o que a câmera entrega).
            v = 0.5 + (0.01 if i % 2 else -0.01)
            entrada.append(v)
            saida.append(f(v, t))
            t += 1 / 24
        # Variação ponta a ponta, depois do filtro assentar.
        amp_entrada = max(entrada[10:]) - min(entrada[10:])
        amp_saida = max(saida[10:]) - min(saida[10:])
        self.assertLess(amp_saida, amp_entrada / 3,
                        f"tremor mal filtrado: {amp_saida:.4f} vs {amp_entrada:.4f}")

    def test_movimento_rapido_nao_fica_para_tras(self):
        from gestures import OneEuro
        f = OneEuro()
        t = 0.0
        pos = 0.2
        for _ in range(20):          # varre o quadro depressa
            pos += 0.03
            saida = f(pos, t)
            t += 1 / 24
        # No fim do movimento, o filtro tem de estar colado na mão.
        self.assertLess(abs(saida - pos), 0.02,
                        f"atraso grande demais: {abs(saida - pos):.4f}")

    def test_mao_sumindo_zera_o_filtro(self):
        # Sem zerar, ao voltar em outro ponto o cursor "desliza" do lugar
        # antigo até o novo, como se a mão tivesse viajado.
        rec = HandGestures(mirror=False)
        feed(rec, 0.0, still(POSE_OPEN, ARM_HOLD + 0.3))
        feed(rec, AFTER_ARM, still(POSE_POINT, 0.2, x=0.3, y=0.3))
        rec.update(AFTER_ARM + 5.0, None)
        evs = feed(rec, AFTER_ARM + 6.0, still(POSE_POINT, 0.2, x=0.8, y=0.8))
        passos = [e for e in evs if e["name"] == "move"]
        self.assertFalse(any(abs(p["dx"]) > 0.2 for p in passos),
                         "salto do filtro virou movimento do cursor")


if __name__ == "__main__":
    unittest.main(verbosity=2)
