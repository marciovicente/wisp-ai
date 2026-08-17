# Firmware — Waveshare ESP32-S3-Touch-AMOLED-2.16

A placa é opcional. O app da barra de menu funciona sozinho; isto aqui é para
quem quer o mascote numa telinha em cima da mesa.

## Hardware

**ESP32-S3-Touch-AMOLED-2.16** — ESP32-S3R8 (8MB PSRAM octal, 16MB flash),
AMOLED CO5300 480×480 por QSPI, touch CST9217, acelerômetro QMI8658, gerenciador
de energia AXP2101, USB nativo.

Alimentação: USB-C, ou bateria de lítio 3,7V no conector MX1.25 de 2 pinos.

> **Polaridade.** O conector tem trava e só entra de um jeito, mas fabricantes
> de bateria não padronizam qual fio vai em qual pino. Confira na serigrafia da
> placa qual é o `+` e confirme que o vermelho cai nele **antes** de encaixar.
> Invertido, danifica placa e célula.

## Pré-requisitos

ESP-IDF **v5.5 ou mais novo** — o BSP da Waveshare declara `idf: ">=5.5"` e não
compila em 5.4.

```bash
git clone -b v5.5 --recursive https://github.com/espressif/esp-idf.git ~/esp/esp-idf
~/esp/esp-idf/install.sh esp32s3
source ~/esp/esp-idf/export.sh
```

## Antes de gravar: guarde o firmware de fábrica

A placa vem com uma demonstração da Waveshare que você não recupera depois.

```bash
esptool.py --chip esp32s3 -p /dev/cu.usbmodem* read_flash 0 0x1000000 backup/factory-firmware-16MB.bin
```

Use a velocidade padrão. O USB da placa é nativo (não há chip conversor), então
`--baud 921600` não acelera nada e provoca falha no meio da leitura.

## Compilar e gravar

```bash
cd firmware
idf.py set-target esp32s3
idf.py build
idf.py -p /dev/cu.usbmodem* flash monitor
```

Se a placa não aparecer em `/dev/cu.*`, confira se o cabo transmite dados —
muito cabo USB-C só carrega. Sem enumerar no USB, não há como gravar.

## Provisionar WiFi e token

As credenciais nunca ficam no código: vão direto para a partição NVS.

```bash
/usr/bin/python3 ../bridge/provision_wifi.py
```

Ele pergunta a rede, a senha (que não aparece na tela) e grava também o token
que o bridge exige. Depois disso você pode fechar a rede:

```json
// ~/.fagulha/config.json
"exigir_token": true
```

A placa só faz **2.4GHz**. Rede 5GHz-only não conecta nem com a senha certa.

## Como a placa acha o Mac

Procura o serviço mDNS `_fagulha._tcp`, que o bridge publica. Isso não depende
do nome da máquina — o macOS renomeia o computador sozinho quando detecta
conflito na rede, e uma placa presa a um hostname vira órfã quando isso
acontece. Como reserva, ela ainda tenta o hostname gravado na NVS.

## Uso

- **Deslizar para o lado** — painel de consumo e limites
- **Virar o aparelho** — a imagem gira junto, pelo acelerômetro
- **Sem sessão ativa** — relógio e previsão do tempo

## Notas de implementação

Duas decisões não óbvias, medidas e não supostas:

**Buffer de 16 linhas.** O `bsp_display_start()` fixa 50 linhas, o que faz o
driver SPI alocar um buffer de rebote de 48KB em RAM interna. Sem WiFi cabe;
com a pilha de rede ligada sobra pouco e vira `ESP_ERR_NO_MEM` no meio do
desenho. Com 16 linhas o teto cai para 15KB e a tela volta a desenhar com a
rede de pé — 66fps estáveis.

**Rotação por hardware.** O `lv_display_set_rotation()` do LVGL exige modo de
render DIRECT ou FULL, e rodamos em PARTIAL por causa do item acima — ele
apenas logava um aviso e não girava nada. A rotação usa o MADCTL do painel, o
que custa zero de CPU. O touch precisa girar junto, ou o toque cai no lugar
errado.
