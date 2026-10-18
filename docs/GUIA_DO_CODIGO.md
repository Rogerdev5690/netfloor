# WaveLens — Guia para entender, explicar e editar o código

Este guia é para quem abre o código pela primeira vez. A explicação técnica completa (fórmulas, arquitetura, releases) está em `DOCUMENTACAO.md` e no PDF; aqui o foco é **onde cada coisa está**, **em que ordem explicar** e **onde mexer**.

> No VS Code: **Ctrl+P** abre um arquivo pelo nome, **Ctrl+Shift+O** lista as classes do arquivo aberto, **Ctrl+T** procura qualquer classe/função do projeto e **F12** (ou Ctrl+clique) vai à definição.

## 1. As duas pastas

| Pasta | O que é |
|---|---|
| `netfloor/` | **App web** (Flutter). Quase tudo está aqui: simulador, diagnóstico, laudo em PDF. |
| `netfloor_shell/` | **App Android** (APK): uma WebView que abre o site + ponte para Wi-Fi, ping e arquivos (Kotlin). |

Os nomes das pastas e dos repositórios continuam `netfloor` (só o nome exibido virou WaveLens — `DOCUMENTACAO.md`, seção 1.5).

## 2. Como o código do app web está organizado

O `lib/main.dart` ficou pequeno: tem só as importações, a lista de módulos e a função `main()`. O resto está em **30 arquivos**, cada um começando com um cabeçalho **ETAPA n** que diz *o que é, como funciona, quem usa e onde mexer*.

```text
lib/
├── main.dart                         importações + lista de módulos + main()
├── app/
│   ├── app.dart                      ETAPA 1   entrada do app e barra de navegação
│   ├── identidade.dart               ETAPA 2   nome e versão (kAppName, kAppVersion)
│   └── tema.dart                     ETAPA 3   Modo Apresentação / Modo Diagnóstico
├── core/
│   ├── utilitarios.dart              ETAPA 4   datas, cores de classe de sinal
│   └── dialogos.dart                 ETAPA 5   diálogos prontos, nome de arquivo seguro
├── simulador/
│   ├── modelo/roteadores.dart        ETAPA 6   catálogo de roteadores (dBm) e RouterNode
│   ├── modelo/plantas.dart           ETAPA 7   plantas, paredes, materiais, bandas, FloorState
│   ├── dados/biblioteca_plantas.dart ETAPA 8   as plantas prontas e a lista de projetos
│   ├── modelo/medicoes_laudo.dart    ETAPA 9   medições, pontos de medição, dados do laudo
│   ├── estado/network_model.dart     ETAPA 10  o estado do projeto (NetworkModel)
│   ├── fisica/fisica_sinal.dart      ETAPA 11  a física do sinal (SignalField)
│   ├── pintura/paleta_calor.dart     ETAPA 12  dBm → cor
│   ├── pintura/planta_fundo.dart     ETAPA 13  desenho da planta de fundo
│   ├── pintura/mapa_calor.dart       ETAPA 14  pintura do mapa de calor
│   ├── pintura/sobreposicoes.dart    ETAPA 15  paredes, régua, anéis, marcadores de ponto
│   ├── pintura/icones_roteador.dart  ETAPA 16  ícone de cada roteador
│   └── tela/tela_simulador.dart      ETAPA 17  a tela do simulador (gestos, barras, diálogos)
├── diagnostico/
│   ├── ponte_nativa.dart             ETAPA 18  ponte com o app Android
│   ├── modelos_diagnostico.dart      ETAPA 19  rede Wi-Fi, conexão, saúde do canal
│   ├── fontes_dados.dart             ETAPA 20  dados reais × simulados
│   ├── controlador_diagnostico.dart  ETAPA 21  temporizadores e medições
│   ├── tela_diagnostico.dart         ETAPA 22  a tela com 3 abas
│   ├── aba_espectro.dart             ETAPA 23  aba Espectro
│   ├── aba_sinal.dart                ETAPA 24  aba Sinal
│   └── aba_latencia.dart             ETAPA 25  aba Latência
├── infra/
│   ├── armazenamento.dart            ETAPA 26  salvar projetos no aparelho (IndexedDB)
│   └── arquivos.dart                 ETAPA 27  baixar / salvar / compartilhar arquivos
└── laudo/
    ├── assinatura.dart               ETAPA 28  assinatura na tela
    ├── tela_laudo.dart               ETAPA 29  formulário do laudo
    └── gerador_pdf.dart              ETAPA 30  geração do PDF
```

### Como funciona o `part` / `part of` (para explicar)

Cada arquivo de módulo começa (depois do cabeçalho) com `part of '../main.dart';`, e o `main.dart` lista todos com `part 'pasta/arquivo.dart';`. Isso faz o Dart tratar tudo como **um arquivo só** que foi apenas dividido: as importações ficam no `main.dart`, e os nomes que começam com `_` (privados) continuam visíveis entre os módulos. Por isso a divisão não mudou nenhuma linha de código.

**Para criar um módulo novo:** crie o arquivo com `part of` no topo (copie o caminho `../main.dart` conforme a profundidade da pasta), escreva o código e adicione uma linha `part '...';` no `main.dart`. Importações novas vão no `main.dart`, nunca no módulo.

## 3. Roteiro para explicar o app (nesta ordem)

1. **O que o app faz e como ele abre (Etapas 1–5).** "É um app de visita técnica: mostra a cobertura Wi-Fi sobre a planta da casa, mede a rede de verdade e gera um laudo em PDF." Abra `app/app.dart`: o `WaveLensShell` cria o estado, abre o banco, restaura o último projeto e mostra as duas abas.
2. **Os dados (Etapas 6–9).** "Um roteador tem modelo e potência; uma planta tem cômodos, paredes e escala." Mostre `roteadores.dart`, `plantas.dart` e `biblioteca_plantas.dart`. Ponto-chave: posições são **frações** (0 a 1) da planta, então não dependem do tamanho da tela.
3. **O estado do projeto (Etapa 10).** "O `NetworkModel` é o cérebro: guarda tudo e avisa as telas quando algo muda." Mostre `notifyListeners`, `calibrate` (a régua) e `toJson`/`applyJson` (exportar/importar).
4. **A física do sinal (Etapa 11).** "Sinal = potência − perda pela distância − paredes no caminho − laje entre andares, tudo em metros, e vale o maior roteador." Mostre `SignalField.at`.
5. **Como o sinal vira imagem (Etapas 12–16).** Paleta (dBm → cor) → `HeatmapPainter` pinta célula por célula → planta de fundo, paredes, anéis e ícones por cima.
6. **A tela e os gestos (Etapa 17).** "Cada ferramenta (roteador, parede, régua, ponto) muda o que o toque faz; dois dedos fazem zoom." É o arquivo maior (`tela_simulador.dart`): use **Ctrl+Shift+O** para navegar.
7. **O diagnóstico Wi-Fi (Etapas 18–25).** "No Android de verdade o app lê o Wi-Fi do aparelho; no navegador usa dados simulados." Explique a ponte (`ponte_nativa.dart`), a escolha da fonte (`fontes_dados.dart`) e o controlador com os temporizadores.
8. **Guardar e entregar (Etapas 26–30).** "Tudo é salvo sozinho no aparelho; o laudo vira PDF com mapas, tabelas e a assinatura do cliente." Mostre `armazenamento.dart`, `assinatura.dart` e `gerador_pdf.dart`.

## 4. Como rodar e testar

```bat
cd "C:\Users\Roger\Desktop\Nova pasta\netfloor"
flutter pub get
run_web.bat
```

Abre em `http://localhost:8090`. A primeira compilação demora ~1 minuto (tela preta) — recarregue a página quando o terminal disser que está servindo.

- Depois de editar e salvar, no terminal onde o Flutter está rodando aperte **R** (hot restart). Se não refletir, aperte **q** e rode `run_web.bat` de novo.
- Para checar erros sem rodar: `flutter analyze` (hoje: 0 erros; as ~26 observações restantes são de estilo).
- **Só roda no navegador.** O app usa `dart:js_interop`, então `flutter run -d windows` / Android direto não funciona. O app Android é o Shell, que abre o site.
- Não há testes automatizados; a validação é abrir o app e usar.

## 5. Receitas de edição

| Quero… | Mexa em… |
|---|---|
| Mudar o nome exibido | `app/identidade.dart` (`kAppName`), `web/index.html`, `web/manifest.json`, `android:label` no Shell |
| Adicionar um roteador | `modelo/roteadores.dart` (enum + catálogo) e `pintura/icones_roteador.dart` (um `_paintXxx` + `case`) |
| Mudar a potência de um roteador | `txPowerDbm` em `modelo/roteadores.dart` |
| Adicionar uma planta | PNG em `assets/floorplans/` → `FloorPlanDef` em `dados/biblioteca_plantas.dart` → incluir em `kBuiltInPlans` e `kProjectLibrary` |
| Mudar perda de paredes/materiais | `kWallMaterials` em `modelo/plantas.dart` |
| Mudar perda por banda (2.4/5/6 GHz) | `kRfBands` em `modelo/plantas.dart` |
| Mudar perda da laje / pé-direito / "Forte-Ruim" | `kSlabLossDb`, `kFloorHeightM`, `kStrongDbm`, `kWeakDbm` em `fisica/fisica_sinal.dart` |
| Mudar cores do mapa de calor | `_kStopColors` em `pintura/paleta_calor.dart` |
| Mudar móveis do desenho vetorial | `_drawFurniture` em `pintura/planta_fundo.dart` |
| Mudar textos/botões do simulador | `tela/tela_simulador.dart` (procure o texto com Ctrl+F) |
| Mudar regras do projeto (adicionar/mover/calibrar) | `estado/network_model.dart` |
| Mudar o diagnóstico (intervalos, medições) | `diagnostico/controlador_diagnostico.dart` |
| Mudar o conteúdo do laudo em PDF | `laudo/gerador_pdf.dart` (páginas) e `laudo/tela_laudo.dart` (formulário) |
| Mudar cores/tema | `app/tema.dart` |
| Mudar o ícone do app | Troque `assets/icon/icon.png` nos dois projetos; rode `dart run flutter_launcher_icons` no Shell (`DOCUMENTACAO.md`, seção 2.6) |

## 6. Publicar uma mudança

1. **Site (app web):** `flutter build web --release --base-href "/netfloor/" --pwa-strategy=none` e publicar `build/web` no branch `gh-pages` (passo a passo na seção 7.6 do `DOCUMENTACAO.md`). O app Android pega a versão nova **sozinho** na próxima abertura.
2. **APK:** só precisa gerar de novo se mudar algo **nativo** (Kotlin, permissões, ícone, nome). Veja a seção 7.7.

Enquanto você não publicar, a mudança existe só no seu PC.

## 7. Ter o código em outro computador

```bash
git clone https://github.com/Rogerdev5690/netfloor.git
git clone https://github.com/Rogerdev5690/netfloor-shell.git
```

Instale também:

- **Flutter 3.47.4** (a versão usada aqui; versões muito diferentes podem dar erros).
- **VS Code** com as extensões **Flutter** e **Dart**.
- Só para gerar o APK: **JDK 17** e o **Android SDK** (plataformas 35/36).

Depois: `flutter pub get` em cada pasta.
