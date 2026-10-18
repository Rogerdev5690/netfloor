// WaveLens v8.2 (Enterprise) — simulador de mapa de calor Wi-Fi 2.5D (vários
// pavimentos, 2.4/5/6 GHz, escala calibrável, materiais de parede) + WaveLens
// Diagnostic + laudo de vistoria em PDF com assinatura digital + projetos
// offline (.json). Rebranding v8.2: o app se chamava NetFloor até a v8.1;
// identificadores técnicos internos (repositórios GitHub, applicationId
// Android, ponte `NetFloorNative`, formato `netfloor-project`) permanecem
// com o nome antigo por compatibilidade — ver seção 1.5 da documentação.
//
// COMO ESTE CÓDIGO ESTÁ ORGANIZADO
// --------------------------------
// Este arquivo só tem as importações e a função main(). O resto do app foi
// dividido em módulos com `part` / `part of`: continua sendo UMA biblioteca
// Dart (mesmas importações, mesmos nomes privados `_`), só que espalhada em
// arquivos pequenos. Cada arquivo começa com um cabeçalho "ETAPA n" dizendo o
// que é, como funciona, quem usa e onde mexer. Para contar a história do app,
// siga as etapas na ordem:
//
//   app/          Etapas 1–3   entrada do app, nome/versão e temas
//   core/         Etapas 4–5   utilitários e diálogos reutilizáveis
//   simulador/    Etapas 6–17  dados (roteadores, plantas), estado do projeto,
//                              física do sinal, pintura do mapa e a tela
//   diagnostico/  Etapas 18–25 ponte com o Android, modelos, controlador e abas
//   infra/        Etapas 26–27 armazenamento local e entrega de arquivos
//   laudo/        Etapas 28–30 assinatura, tela do laudo e gerador de PDF
//
// Guia completo: docs/GUIA_DO_CODIGO.md
//
// pubspec.yaml (dependências necessárias):
//
//   dependencies:
//     flutter:
//       sdk: flutter
//     file_picker: ^13.1.0   # upload de plantas/logo/.json em memória (bytes), sem dart:io
//     fl_chart: ^1.2.0       # gráficos de linha (sinal e latência)
//     pdf: ^3.13.1           # laudo em PDF (100 % Dart)
//     image: ^4.10.1         # JPEG dos mapas de calor do laudo
//     web: ^1.1.1            # download de arquivos (Blob)
//     sembast: ^3.8.11       # banco local
//     sembast_web: ^2.4.6    # ... sobre IndexedDB (offline-first)
//
//   flutter:
//     uses-material-design: true
//     assets:
//       - assets/floorplans/  # casa_2q.png (+ planta_01..03.png e edificio_corporativo.png quando existirem)
//       - assets/fonts/       # Roboto (Regular, Bold, Italic) usada no PDF
//
// Este app compila para Flutter Web/PWA (usa dart:js_interop). Os recursos
// nativos do Android (varredura Wi-Fi, RSSI, ping, salvar/compartilhar arquivos)
// chegam pela ponte JS `NetFloorNative`, exposta pelo app WaveLens Shell
// (WebView). Fora do Shell (navegador comum / PWA), a aba Diagnóstico roda em
// modo simulação e os arquivos são baixados pelo navegador.

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as im;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:sembast_web/sembast_web.dart';
import 'package:web/web.dart' as web;

// ---------------------------------------------------------------------------
// Módulos do app (cada um começa com um cabeçalho "ETAPA n"). No Dart as
// diretivas `part` precisam vir antes de qualquer declaração (como main()).
// ---------------------------------------------------------------------------

// Etapa 1–5 · App, tema e utilitários
part 'app/app.dart';
part 'app/identidade.dart';
part 'app/tema.dart';
part 'core/utilitarios.dart';
part 'core/dialogos.dart';

// Etapa 6–17 · Simulador de mapa de calor
part 'simulador/modelo/roteadores.dart';
part 'simulador/modelo/plantas.dart';
part 'simulador/dados/biblioteca_plantas.dart';
part 'simulador/modelo/medicoes_laudo.dart';
part 'simulador/estado/network_model.dart';
part 'simulador/fisica/fisica_sinal.dart';
part 'simulador/pintura/paleta_calor.dart';
part 'simulador/pintura/planta_fundo.dart';
part 'simulador/pintura/mapa_calor.dart';
part 'simulador/pintura/sobreposicoes.dart';
part 'simulador/pintura/icones_roteador.dart';
part 'simulador/tela/tela_simulador.dart';

// Etapa 18–25 · Diagnóstico Wi-Fi (Android nativo ou simulado)
part 'diagnostico/ponte_nativa.dart';
part 'diagnostico/modelos_diagnostico.dart';
part 'diagnostico/fontes_dados.dart';
part 'diagnostico/controlador_diagnostico.dart';
part 'diagnostico/tela_diagnostico.dart';
part 'diagnostico/aba_espectro.dart';
part 'diagnostico/aba_sinal.dart';
part 'diagnostico/aba_latencia.dart';

// Etapa 26–30 · Armazenamento, arquivos e laudo em PDF
part 'infra/armazenamento.dart';
part 'infra/arquivos.dart';
part 'laudo/assinatura.dart';
part 'laudo/tela_laudo.dart';
part 'laudo/gerador_pdf.dart';

// ---------------------------------------------------------------------------
// Ponto de entrada: tudo começa aqui. O WaveLensApp está em app/app.dart.
// ---------------------------------------------------------------------------
void main() => runApp(const WaveLensApp());
