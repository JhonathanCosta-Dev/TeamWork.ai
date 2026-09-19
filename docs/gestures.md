# Controle de janelas por gesto

Mexe nas janelas do compositor com a mão, pela **mesma webcam** que o avatar já
usa para olhar pra você — sem hardware novo e sem enviar nada pra fora: o
reconhecimento roda local, e do Python só saem os nomes dos gestos.

Ligue em **Config → Controle por gesto** (precisa da câmera ligada). Depende do
[niri](https://github.com/YaLTeR/niri), que recebe as ações por `niri msg`.

## Vocabulário

| gesto | ação |
| --- | --- |
| ✋ mão aberta, parada 0,5 s | entra no comando (arma) |
| ✋ desliza → / ← | próxima coluna / coluna anterior |
| ✋ desliza ↑ | maximiza a coluna |
| ✋ desliza ↓ | tela cheia |
| ✌ 4 dedos ↑↓←→ (polegar recolhido) | rola a página |
| ☝ polegar + indicador + médio | move o cursor do mouse |
| ☝ fecha o polegar | clica — mantido fechado, segura o clique |
| ✊ fecha a mão | pega a janela sob o cursor |
| ✊ move | a janela acompanha a mão |
| ✋ abre a mão | solta a janela onde estiver |

**Levante a mão aberta e segure meio segundo pra entrar no comando**: aparece um
selo na tela, e a partir daí os gestos valem. Três segundos sem gesto desarma
sozinho. Sem essa trava, gesticular numa conversa jogaria suas janelas pra outro
monitor.

## Rolagem

Os quatro dedos com o **polegar recolhido** contra a palma — é só isso que a
separa da mão aberta, que tem o polegar para fora. A distinção importa: sem
ela, armar a mão já começaria a rolar a página.

**O gesto trava no eixo em que começou**, como num trackpad. O primeiro
movimento acima de 2% do quadro decide se a rolagem é vertical ou horizontal, e
esse eixo vale até a mão sair da pose. Travar não é capricho: a mão nunca anda
reto, e sem isso cada tremida viraria rolagem no outro sentido — a página fugia
na diagonal. O movimento que escolhe o eixo não é perdido, ele sai inteiro no
primeiro passo.

A página segue a mão nos dois eixos: descendo rola para baixo, indo para a
direita rola para a direita. Só o eixo vertical inverte o sinal internamente,
porque o `y` da imagem cresce para baixo enquanto a roda positiva é para cima.

Um quadro lido errado no meio da rolagem não encerra o gesto: há uma folga de
0,15 s para leitura ruim, e a rolagem continua durante ela — quem piscou foi a
classificação da pose, não a posição da mão. Sem isso, cada dedo mal lido
custava a zona morta da trava inteira e a página travava no meio do movimento.

## Ponteiro

A mão de ponteiro (polegar, indicador e médio levantados; anelar e mindinho
dobrados) vira um mouse no ar: o cursor acompanha a mão, e o **polegar é o
botão** — fechou, clicou; mantido fechado, segura o clique, então dá para
arrastar e selecionar como num trackpad. É também como se mira numa janela
antes de fechar a mão inteira para pegá-la.

O polegar é medido pela **travessia da palma** (`dist(4,17) / dist(2,17)`), não
pela distância até a base do indicador: na pose de ponteiro o polegar fica
naturalmente perto do indicador, e a régua ingênua lia clique o tempo todo.

## Arrasto

O arrasto é literalmente o **Super + arrastar do mouse**: como o niri não expõe
o arrasto interativo por IPC, um ponteiro virtual (`/dev/uinput`) pressiona
Super + botão esquerdo e move o cursor — o compositor faz o resto, exatamente
como se você estivesse arrastando com a mão no mouse. Fechar a mão é o botão
descendo; abrir é soltar.

Um botão preso captura o desktop inteiro, então há três redes de proteção: o
reconhecedor solta o clique antes de pegar a janela, `Pointer.grab/press`
soltam o modo anterior, e um watchdog solta sozinho após 4 s sem comando.

## O que não é gesto

**Fechar janela não é um gesto.** Some da câmera qualquer caminho para uma ação
irreversível — o teclado dá conta disso, e um falso positivo custaria trabalho
não salvo.

Um rosto reconhecido como *não sendo você* também não comanda nada.

## Duas mãos no quadro

**Comanda a que está mais perto da câmera** — é a que você levantou de
propósito, enquanto a outra costuma estar no teclado. A régua é o tamanho da
**palma**, que é rígida: medir a mão inteira faria um punho perto perder para
uma mão aberta ao fundo.

## Câmera

Com mais de uma webcam, **Config → Câmera usada** lista as que existem e deixa
escolher. A lista sai de `services/cameras.py`, que pergunta ao driver quais
`/dev/videoN` capturam imagem de verdade — cada webcam expõe também um nó de
metadados, com nome idêntico, que nunca produz quadro.

## Fluidez

O cursor é tão fluido quanto a taxa com que a mão é amostrada, e quatro coisas
trabalham juntas nisso:

- enquanto a mão **comanda** (cursor, arrasto ou rolagem), o laço do tracker
  sobe para 30 Hz, e o rosto cede a vez — ninguém olha o avatar no meio de um
  arrasto;
- a posição passa por um **filtro 1€**, que corta o tremor sem atrasar o
  movimento;
- a velocidade estimada **adianta** a posição, compensando o tempo que o quadro
  levou para chegar;
- cada deslocamento é repartido em **passos curtos entregues a ~165 Hz**, para o
  cursor não andar aos saltos no ritmo da câmera.

## Onde os avisos aparecem

O selo "no comando" e o espelho da mão flutuam sobre a área de trabalho. Em
**Config → Onde mostrar os avisos de gesto e o espelho da mão** dá para escolher
o canto (a grade é uma miniatura da tela) e em qual monitor:

- **a do widget** — o mesmo monitor do widget (padrão)
- **a que estou usando** — segue a tela ativa do compositor
- **o nome da saída** — fixa numa tela específica

Sobre *"a que estou usando"*: no Wayland um cliente comum não tem como perguntar
onde está o ponteiro — não existe essa API, por design. A fonte é
`niri msg focused-output`, a noção do próprio compositor de tela ativa. Ela
acompanha o mouse de verdade se `focus-follows-mouse` estiver ligado na config
do niri; sem isso, segue a janela em foco, que na prática é a mesma tela quase
sempre.

## Ver a mão sendo captada

Em Config, logo abaixo do interruptor do controle por gesto, ligue *"Mostrar a
câmera e os traços da mão ao gesticular"*. Aparece um quadro sobre a área de
trabalho com a imagem da webcam e o esqueleto detectado desenhado por cima, mais
o que falta para comandar ("mão aberta — segure parada" → "no comando —
deslize").

A imagem vai para a memória da sessão (`$XDG_RUNTIME_DIR`), nunca para o disco,
e só enquanto há mão no quadro.

## Requisitos

Requer o modelo de mãos (`hand_landmarker.task`) e, para o arrasto e a rolagem,
o pacote `evdev` com permissão de escrita em `/dev/uinput` — tudo
instalado/verificado por `scripts/setup-facetrack.sh`. Numa sessão de desktop
comum a permissão do uinput vem por ACL do seat, sem root nem grupo extra
(`getfacl /dev/uinput`). Sem ela, os gestos de navegação funcionam e só o
arrasto, o ponteiro e a rolagem ficam de fora.

## Diagnóstico

**Se um gesto não pegar, rode isto antes de mexer em limiar:**

```bash
./scripts/gesture-doctor.sh      # Ctrl+C encerra; nada é executado
```

Ele mostra ao vivo a taxa real de quadros, se a câmera está vendo sua mão e em
que pose, e qual comando cada gesto teria disparado. A taxa importa mais do que
parece: os limiares assumem ~6 quadros/s (medido numa Intel UHD com
FaceLandmarker + HandLandmarker + reconhecimento de identidade no mesmo laço).
Abaixo disso, um deslize não junta amostras suficientes — o diagnóstico avisa.

Para o detalhe quadro a quadro, `TEAMWORK_FACE_DEBUG=1` grava em
`~/.local/share/teamwork-ai/facetrack/wave-debug.log` (desligado por padrão: o
arquivo cresce sem limite).

## Como isso é testado

O reconhecedor (`services/gestures.py`) não fala com câmera nenhuma: recebe
posições e poses, devolve eventos. As trajetórias dos testes são sintéticas, o
que permite verificar sem acenar pra webcam que um aceno não vira comando, que
um movimento lento não vira deslize, que a mão precisa estar armada, e que toda
saída de um gesto encerra o estado dele.

```bash
python3 apps/widget/services/test_gestures.py   # reconhecedor
python3 apps/widget/services/test_pointer.py    # ponteiro virtual
python3 apps/widget/services/test_cameras.py    # listagem de câmeras
```
