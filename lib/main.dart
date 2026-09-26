// WaveLens v8.2 (Enterprise) — simulador de mapa de calor Wi-Fi 2.5D (vários
// pavimentos, 2.4/5/6 GHz, escala calibrável, materiais de parede) + WaveLens
// Diagnostic + laudo de vistoria em PDF com assinatura digital + projetos
// offline (.json). Rebranding v8.2: o app se chamava NetFloor até a v8.1;
// identificadores técnicos internos (repositórios GitHub, applicationId
// Android, ponte `NetFloorNative`, formato `netfloor-project`) permanecem
// com o nome antigo por compatibilidade — ver seção 1.5 da documentação.
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
// Este arquivo compila para Flutter Web/PWA (usa dart:js_interop). Os recursos
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

void main() => runApp(const WaveLensApp());

class WaveLensApp extends StatelessWidget {
  const WaveLensApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ViewMode>(
      valueListenable: kViewMode,
      builder: (context, mode, _) => MaterialApp(
        title: kAppName,
        debugShowCheckedModeBanner: false,
        theme: buildTheme(mode),
        // Modo Diagnóstico: texto um pouco maior para leitura sob sol forte.
        builder: (context, child) => mode == ViewMode.diagnostic
            ? MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: MediaQuery.textScalerOf(context).clamp(minScaleFactor: 1.08)),
                child: child!,
              )
            : child!,
        home: const WaveLensShell(),
      ),
    );
  }
}

/// Navegação principal: Simulador (mapa de calor) e Diagnóstico (Wi-Fi).
/// Também é dono do estado compartilhado: modelo do projeto, controlador do
/// diagnóstico e armazenamento local (offline-first).
class WaveLensShell extends StatefulWidget {
  const WaveLensShell({super.key});

  @override
  State<WaveLensShell> createState() => _WaveLensShellState();
}

class _WaveLensShellState extends State<WaveLensShell> {
  final DiagnosticsController _diag = DiagnosticsController();
  final NetworkModel _net = NetworkModel();
  final AppStore _store = AppStore();
  int _index = 0;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      await _store.init();
      final mode = await _store.getSetting('viewMode');
      final parsed = ViewMode.values.asNameMap()[mode];
      if (parsed != null) kViewMode.value = parsed;
      await _store.restoreLast(_net);
    } catch (_) {
      // sem armazenamento: segue com o projeto padrão
    }
    _store.attach(_net);
    if (mounted) setState(() => _ready = true);
  }

  @override
  void dispose() {
    _diag.dispose();
    _net.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          TickerMode(enabled: _index == 0, child: SimulatorPage(model: _net, diag: _diag, store: _store)),
          TickerMode(enabled: _index == 1, child: DiagnosticPage(controller: _diag, active: _index == 1, model: _net)),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.map_outlined), selectedIcon: Icon(Icons.map), label: 'Simulador'),
          NavigationDestination(
            icon: Icon(Icons.network_check_outlined),
            selectedIcon: Icon(Icons.network_check),
            label: 'Diagnóstico',
          ),
        ],
      ),
    );
  }
}

// ===========================================================================
// PARTE 1 — SIMULADOR DE MAPA DE CALOR
// ===========================================================================

// ---------------------------------------------------------------------------
// Catálogo de roteadores: cada modelo tem uma potência de transmissão (dBm)
// diferente, usada diretamente no cálculo de propagação do sinal.
// ---------------------------------------------------------------------------

enum RouterModelType { huaweiAx3, tplinkDeco, unifiAp, zteE2320 }

class RouterModelSpec {
  final RouterModelType type;
  final String name;
  final String shortName;
  final double txPowerDbm;
  const RouterModelSpec({
    required this.type,
    required this.name,
    required this.shortName,
    required this.txPowerDbm,
  });
}

const List<RouterModelSpec> kRouterCatalog = [
  RouterModelSpec(
    type: RouterModelType.huaweiAx3,
    name: 'Huawei AX3 Pro / AX3s',
    shortName: 'Huawei AX3',
    txPowerDbm: 18,
  ),
  RouterModelSpec(
    type: RouterModelType.tplinkDeco,
    name: 'TP-Link Deco (Mesh)',
    shortName: 'TP-Link Deco',
    txPowerDbm: 23,
  ),
  RouterModelSpec(
    type: RouterModelType.unifiAp,
    name: 'Ubiquiti UniFi AP',
    shortName: 'UniFi AP',
    txPowerDbm: 28,
  ),
  // Ganho/potência configurados acima do Huawei AX3 (18 dBm): CPE Wi-Fi 6 com
  // maior EIRP por antena externa e beamforming — cobertura e alcance maiores
  // na simulação de propagação.
  RouterModelSpec(
    type: RouterModelType.zteE2320,
    name: 'ZTE E2320 / E2620 (ZXHN, Wi-Fi 6)',
    shortName: 'ZTE E2320',
    txPowerDbm: 20,
  ),
];

RouterModelSpec _specFor(RouterModelType type) => kRouterCatalog.firstWhere((s) => s.type == type);

// ---------------------------------------------------------------------------
// Projetos, pavimentos e plantas baixas.
//
// Um PROJETO tem um ou mais PAVIMENTOS (térreo, 1º andar...) e cada pavimento
// usa uma planta (FloorPlanDef) com `wallSegments` (paredes vetorizadas em
// coordenadas fracionárias) para o ray-casting de atenuação.
//
// Cada planta pode vir de: imagem remota (imageUrl) -> asset embutido
// (assetPath) -> desenho vetorial (rooms). Se o PNG ainda não existe em
// assets/floorplans/, o app cai sozinho no desenho vetorial; basta soltar o
// arquivo com o nome esperado na pasta (e ajustar o aspectRatio, se mudar).
// Plantas enviadas pelo usuário vivem só em memória (Uint8List + Image.memory),
// sem dart:io, e não têm paredes mapeadas.
// ---------------------------------------------------------------------------

class RoomDef {
  final String label;
  final Rect rectFrac; // coordenadas fracionárias (0..1) relativas à planta
  const RoomDef(this.label, this.rectFrac);
}

/// Materiais de parede (presets do desenhista de paredes). Os valores são a
/// perda típica, em dB, na banda de 2.4 GHz; em 5/6 GHz a perda é multiplicada
/// pelo fator da banda (ver [kRfBands]).
enum WallMaterial { drywall, ceramico, vidro, concreto }

class WallMaterialSpec {
  final WallMaterial material;
  final String label;
  final String shortLabel;
  final double minDb;
  final double maxDb;
  final double defaultDb;
  final Color color;
  const WallMaterialSpec(this.material, this.label, this.shortLabel, this.minDb, this.maxDb, this.defaultDb, this.color);

  bool get adjustable => maxDb > minDb;
}

const List<WallMaterialSpec> kWallMaterials = [
  WallMaterialSpec(WallMaterial.drywall, 'Gesso / Drywall', 'Gesso', 2, 2, 2, Color(0xFF22C55E)),
  WallMaterialSpec(WallMaterial.ceramico, 'Tijolo cerâmico', 'Cerâmico', 4, 4, 4, Color(0xFFF59E0B)),
  WallMaterialSpec(WallMaterial.vidro, 'Vidro / Espelho', 'Vidro', 5, 5, 5, Color(0xFF06B6D4)),
  WallMaterialSpec(WallMaterial.concreto, 'Concreto armado / Laje', 'Concreto', 12, 15, 13.5, Color(0xFFEF4444)),
];

WallMaterialSpec wallMaterialSpec(WallMaterial m) => kWallMaterials.firstWhere((s) => s.material == m);

class WallSegment {
  final Offset a; // coordenadas fracionárias (0..1)
  final Offset b;
  final double attenuationDb; // perda de sinal ao atravessar esta parede (em 2.4 GHz)
  final WallMaterial? material; // null = parede aproximada da planta (não desenhada pelo usuário)
  const WallSegment(this.a, this.b, {this.attenuationDb = 6.0, this.material});

  bool get isUser => material != null;
  Color get color => material == null ? const Color(0xFF64748B) : wallMaterialSpec(material!).color;
}

/// Banda de operação usada na simulação. A referência é 2.4 GHz; 5 e 6 GHz
/// têm perda de referência (a 1 m) maior, expoente de propagação maior e
/// paredes mais "opacas" — logo, alcance menor.
enum RfBand { ghz24, ghz5, ghz6 }

class RfBandSpec {
  final RfBand band;
  final String label;
  final double refOffsetDb; // deslocamento do nível a 1 m em relação a 2.4 GHz
  final double pathLossExp; // multiplicador de 10*log10(d): 22 = expoente n≈2.2
  final double wallFactor; // multiplicador da atenuação das paredes
  const RfBandSpec(this.band, this.label, this.refOffsetDb, this.pathLossExp, this.wallFactor);
}

const List<RfBandSpec> kRfBands = [
  RfBandSpec(RfBand.ghz24, '2.4 GHz', 0.0, 22.0, 1.0),
  RfBandSpec(RfBand.ghz5, '5 GHz', -6.4, 24.0, 1.35),
  RfBandSpec(RfBand.ghz6, '6 GHz', -7.9, 25.0, 1.5),
];

RfBandSpec rfBandSpec(RfBand b) => kRfBands.firstWhere((s) => s.band == b);

class FloorPlanDef {
  final String id;
  final String name;
  final String subtitle;
  final String? imageUrl; // imagem remota (Image.network), se disponível
  final String? assetPath; // asset local: fallback da imagem remota, ou única fonte
  final Uint8List? memoryBytes; // planta enviada pelo usuário (Image.memory)
  final double aspectRatio;
  final double defaultWidthM; // largura real estimada da planta (m), até o usuário calibrar a régua
  final List<RoomDef> rooms; // desenho vetorial (usado quando não há imagem)
  final List<WallSegment> wallSegments;
  const FloorPlanDef({
    required this.id,
    required this.name,
    required this.subtitle,
    this.imageUrl,
    this.assetPath,
    this.memoryBytes,
    required this.aspectRatio,
    this.defaultWidthM = 8.0,
    this.rooms = const [],
    this.wallSegments = const [],
  });

  bool get isCustom => memoryBytes != null;
}

class FloorDef {
  final String label;
  final FloorPlanDef plan;
  const FloorDef(this.label, this.plan);
}

class ProjectDef {
  final String id;
  final String name;
  final String subtitle;
  final List<FloorDef> floors;
  final bool isCustom;
  const ProjectDef({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.floors,
    this.isCustom = false,
  });
}

String floorLabel(int index) => index == 0 ? 'Térreo' : '${index}º Andar';

const String kGitHubRawBase = 'https://raw.githubusercontent.com/Rogerdev5690/netfloor/main/assets/floorplans';

const FloorPlanDef kPlanCasa2q = FloorPlanDef(
  id: 'casa_2q',
  name: 'Casa Térrea 2 Quartos',
  subtitle: '2 Quartos · Cozinha · Sala · Banheiro',
  imageUrl: '$kGitHubRawBase/casa_2q.png',
  assetPath: 'assets/floorplans/casa_2q.png',
  aspectRatio: 736 / 1105,
  // Aproximação das paredes internas visíveis na planta (não medidas a laser).
  wallSegments: [
    WallSegment(Offset(0.50, 0.24), Offset(0.50, 0.52)),
    WallSegment(Offset(0.50, 0.24), Offset(0.91, 0.24)),
    WallSegment(Offset(0.62, 0.49), Offset(0.92, 0.49)),
    WallSegment(Offset(0.62, 0.49), Offset(0.62, 0.625)),
    WallSegment(Offset(0.62, 0.625), Offset(0.92, 0.625)),
    WallSegment(Offset(0.52, 0.62), Offset(0.52, 0.90)),
  ],
);

// Casa 2 Pavimentos: modelo de referência para simulações em casas de dois
// andares — desenho vetorial próprio (corte esquemático), sem depender de
// foto de terceiros. Térreo: sala de leitura + escada + sala de TV. Andar
// superior: sala de estar com varanda + quarto.
const FloorPlanDef kPlanCasa2pTerreo = FloorPlanDef(
  id: 'casa_2p_terreo',
  name: 'Casa 2 Pavimentos — Térreo',
  subtitle: 'Sala de Leitura · Escada · Sala de TV',
  aspectRatio: 1.45,
  defaultWidthM: 9,
  rooms: [
    RoomDef('Sala de Estar', Rect.fromLTWH(0.00, 0.00, 0.42, 1.00)),
    RoomDef('Escada', Rect.fromLTWH(0.42, 0.00, 0.16, 1.00)),
    RoomDef('Sala de TV', Rect.fromLTWH(0.58, 0.00, 0.42, 1.00)),
  ],
  wallSegments: [
    WallSegment(Offset(0.42, 0.00), Offset(0.42, 1.00)),
    WallSegment(Offset(0.58, 0.00), Offset(0.58, 1.00)),
  ],
);

const FloorPlanDef kPlanCasa2pAndar = FloorPlanDef(
  id: 'casa_2p_andar',
  name: 'Casa 2 Pavimentos — 1º Andar',
  subtitle: 'Sala de Estar com Varanda · Quarto',
  aspectRatio: 1.45,
  defaultWidthM: 9,
  rooms: [
    RoomDef('Sala de Estar', Rect.fromLTWH(0.00, 0.00, 0.50, 0.84)),
    RoomDef('Varanda', Rect.fromLTWH(0.00, 0.84, 0.50, 0.16)),
    RoomDef('Quarto', Rect.fromLTWH(0.50, 0.00, 0.50, 1.00)),
  ],
  wallSegments: [
    WallSegment(Offset(0.50, 0.00), Offset(0.50, 1.00)),
    WallSegment(Offset(0.00, 0.84), Offset(0.50, 0.84), attenuationDb: 3.5),
  ],
);

// Plantas 01-03: espaço reservado para o lote de imagens limpas (sem marca
// d'água) da biblioteca: assets/floorplans/planta_01.png ... planta_03.png.
// Enquanto os PNGs não existirem, o app mostra estes desenhos provisórios.
const FloorPlanDef kPlanta01 = FloorPlanDef(
  id: 'planta_01',
  name: 'Planta 01 — Apartamento 3 Quartos',
  subtitle: 'Desenho provisório · aguardando planta_01.png',
  assetPath: 'assets/floorplans/planta_01.png',
  aspectRatio: 1.5,
  defaultWidthM: 12,
  rooms: [
    RoomDef('Cozinha', Rect.fromLTWH(0.00, 0.00, 0.32, 0.34)),
    RoomDef('Banheiro', Rect.fromLTWH(0.32, 0.00, 0.16, 0.34)),
    RoomDef('Lavanderia', Rect.fromLTWH(0.48, 0.00, 0.14, 0.34)),
    RoomDef('Quarto 3', Rect.fromLTWH(0.62, 0.00, 0.38, 0.34)),
    RoomDef('Sala de Estar', Rect.fromLTWH(0.00, 0.34, 0.38, 0.46)),
    RoomDef('Varanda', Rect.fromLTWH(0.00, 0.80, 0.38, 0.20)),
    RoomDef('Quarto 1', Rect.fromLTWH(0.38, 0.34, 0.31, 0.66)),
    RoomDef('Quarto 2', Rect.fromLTWH(0.69, 0.34, 0.31, 0.66)),
  ],
  wallSegments: [
    WallSegment(Offset(0.00, 0.34), Offset(1.00, 0.34)),
    WallSegment(Offset(0.32, 0.00), Offset(0.32, 0.34)),
    WallSegment(Offset(0.48, 0.00), Offset(0.48, 0.34)),
    WallSegment(Offset(0.62, 0.00), Offset(0.62, 0.34)),
    WallSegment(Offset(0.38, 0.34), Offset(0.38, 1.00)),
    WallSegment(Offset(0.69, 0.34), Offset(0.69, 1.00)),
    WallSegment(Offset(0.00, 0.80), Offset(0.38, 0.80), attenuationDb: 3.5),
  ],
);

const FloorPlanDef kPlanta02 = FloorPlanDef(
  id: 'planta_02',
  name: 'Planta 02 — Apartamento Open Space',
  subtitle: 'Desenho provisório · aguardando planta_02.png',
  assetPath: 'assets/floorplans/planta_02.png',
  aspectRatio: 1.5,
  defaultWidthM: 12,
  rooms: [
    RoomDef('Sala de Estar', Rect.fromLTWH(0.00, 0.00, 0.46, 0.58)),
    RoomDef('Cozinha', Rect.fromLTWH(0.00, 0.58, 0.46, 0.42)),
    RoomDef('Quarto 1', Rect.fromLTWH(0.46, 0.00, 0.27, 0.34)),
    RoomDef('Suíte', Rect.fromLTWH(0.73, 0.00, 0.27, 0.34)),
    RoomDef('Banheiro', Rect.fromLTWH(0.46, 0.34, 0.20, 0.26)),
    RoomDef('Banheiro', Rect.fromLTWH(0.66, 0.34, 0.20, 0.26)),
    RoomDef('Quarto 3', Rect.fromLTWH(0.46, 0.60, 0.40, 0.40)),
    RoomDef('Varanda', Rect.fromLTWH(0.86, 0.34, 0.14, 0.66)),
  ],
  wallSegments: [
    WallSegment(Offset(0.46, 0.00), Offset(0.46, 1.00)),
    WallSegment(Offset(0.46, 0.34), Offset(1.00, 0.34)),
    WallSegment(Offset(0.73, 0.00), Offset(0.73, 0.34)),
    WallSegment(Offset(0.46, 0.60), Offset(0.86, 0.60)),
    WallSegment(Offset(0.66, 0.34), Offset(0.66, 0.60)),
    WallSegment(Offset(0.86, 0.34), Offset(0.86, 1.00), attenuationDb: 3.5),
  ],
);

const FloorPlanDef kPlanta03 = FloorPlanDef(
  id: 'planta_03',
  name: 'Planta 03 — Apartamento com Terraço',
  subtitle: 'Desenho provisório · aguardando planta_03.png',
  assetPath: 'assets/floorplans/planta_03.png',
  aspectRatio: 1.0,
  defaultWidthM: 10,
  rooms: [
    RoomDef('Varanda', Rect.fromLTWH(0.00, 0.00, 1.00, 0.22)),
    RoomDef('Quarto 1', Rect.fromLTWH(0.00, 0.22, 0.30, 0.40)),
    RoomDef('Sala de Estar', Rect.fromLTWH(0.30, 0.22, 0.40, 0.54)),
    RoomDef('Quarto 2', Rect.fromLTWH(0.70, 0.22, 0.30, 0.40)),
    RoomDef('Banheiro', Rect.fromLTWH(0.00, 0.62, 0.30, 0.14)),
    RoomDef('Banheiro', Rect.fromLTWH(0.70, 0.62, 0.30, 0.14)),
    RoomDef('Quarto 3', Rect.fromLTWH(0.00, 0.76, 0.30, 0.24)),
    RoomDef('Cozinha', Rect.fromLTWH(0.30, 0.76, 0.70, 0.24)),
  ],
  wallSegments: [
    WallSegment(Offset(0.00, 0.22), Offset(1.00, 0.22), attenuationDb: 3.5),
    WallSegment(Offset(0.30, 0.22), Offset(0.30, 1.00)),
    WallSegment(Offset(0.70, 0.22), Offset(0.70, 0.76)),
    WallSegment(Offset(0.00, 0.62), Offset(0.30, 0.62)),
    WallSegment(Offset(0.70, 0.62), Offset(1.00, 0.62)),
    WallSegment(Offset(0.00, 0.76), Offset(1.00, 0.76)),
  ],
);

// Planta 04: mais um modelo residencial padrão (apartamento de 3 suítes),
// para ampliar as opções da biblioteca — desenho vetorial próprio.
const FloorPlanDef kPlanta04 = FloorPlanDef(
  id: 'planta_04',
  name: 'Planta 04 — Apartamento 3 Suítes',
  subtitle: 'Desenho provisório · aguardando planta_04.png',
  assetPath: 'assets/floorplans/planta_04.png',
  aspectRatio: 1.6,
  defaultWidthM: 15,
  rooms: [
    RoomDef('Cozinha', Rect.fromLTWH(0.00, 0.00, 0.28, 0.40)),
    RoomDef('Sala de Jantar', Rect.fromLTWH(0.28, 0.00, 0.30, 0.40)),
    RoomDef('Sala de Estar', Rect.fromLTWH(0.58, 0.00, 0.42, 0.40)),
    RoomDef('Quarto 1 (Suíte)', Rect.fromLTWH(0.00, 0.40, 0.34, 0.46)),
    RoomDef('Banheiro', Rect.fromLTWH(0.00, 0.86, 0.34, 0.14)),
    RoomDef('Quarto 2', Rect.fromLTWH(0.34, 0.40, 0.33, 0.60)),
    RoomDef('Quarto 3', Rect.fromLTWH(0.67, 0.40, 0.33, 0.60)),
  ],
  wallSegments: [
    WallSegment(Offset(0.28, 0.00), Offset(0.28, 0.40)),
    WallSegment(Offset(0.58, 0.00), Offset(0.58, 0.40)),
    WallSegment(Offset(0.00, 0.40), Offset(1.00, 0.40)),
    WallSegment(Offset(0.34, 0.40), Offset(0.34, 1.00)),
    WallSegment(Offset(0.67, 0.40), Offset(0.67, 1.00)),
    WallSegment(Offset(0.00, 0.86), Offset(0.34, 0.86), attenuationDb: 3.5),
  ],
);

// Prédio/escritório: sem imagem ainda (assets/floorplans/edificio_corporativo.png).
const FloorPlanDef kPlanEscritorio = FloorPlanDef(
  id: 'edificio_corporativo',
  name: 'Edifício Corporativo',
  subtitle: 'Open Space · Sala de Reunião · Diretoria · Copa',
  assetPath: 'assets/floorplans/edificio_corporativo.png',
  aspectRatio: 1.6,
  defaultWidthM: 20,
  rooms: [
    RoomDef('Open Space', Rect.fromLTWH(0.00, 0.00, 0.60, 1.00)),
    RoomDef('Sala de Reunião', Rect.fromLTWH(0.60, 0.00, 0.40, 0.40)),
    RoomDef('Diretoria', Rect.fromLTWH(0.60, 0.40, 0.40, 0.30)),
    RoomDef('Copa', Rect.fromLTWH(0.60, 0.70, 0.40, 0.30)),
  ],
  wallSegments: [
    WallSegment(Offset(0.60, 0.00), Offset(0.60, 1.00), attenuationDb: 10.0),
    WallSegment(Offset(0.60, 0.40), Offset(1.00, 0.40)),
    WallSegment(Offset(0.60, 0.70), Offset(1.00, 0.70)),
  ],
);

const List<ProjectDef> kProjectLibrary = [
  ProjectDef(
    id: 'casa_2q',
    name: 'Casa Térrea 2 Quartos',
    subtitle: '1 pavimento · 2 Quartos · Cozinha · Sala · Banheiro',
    floors: [FloorDef('Térreo', kPlanCasa2q)],
  ),
  ProjectDef(
    id: 'casa_2_pavimentos',
    name: 'Casa 2 Pavimentos (Referência)',
    subtitle: '2 pavimentos · modelo de referência para casas de dois andares',
    floors: [
      FloorDef('Térreo', kPlanCasa2pTerreo),
      FloorDef('1º Andar', kPlanCasa2pAndar),
    ],
  ),
  ProjectDef(
    id: 'planta_01',
    name: 'Planta 01 — Apartamento 3 Quartos',
    subtitle: '1 pavimento · desenho provisório (aguardando planta_01.png)',
    floors: [FloorDef('Térreo', kPlanta01)],
  ),
  ProjectDef(
    id: 'planta_02',
    name: 'Planta 02 — Apartamento Open Space',
    subtitle: '1 pavimento · desenho provisório (aguardando planta_02.png)',
    floors: [FloorDef('Térreo', kPlanta02)],
  ),
  ProjectDef(
    id: 'planta_03',
    name: 'Planta 03 — Apartamento com Terraço',
    subtitle: '1 pavimento · desenho provisório (aguardando planta_03.png)',
    floors: [FloorDef('Térreo', kPlanta03)],
  ),
  ProjectDef(
    id: 'planta_04',
    name: 'Planta 04 — Apartamento 3 Suítes',
    subtitle: '1 pavimento · desenho provisório (aguardando planta_04.png)',
    floors: [FloorDef('Térreo', kPlanta04)],
  ),
  ProjectDef(
    id: 'edificio',
    name: 'Edifício Corporativo',
    subtitle: '3 pavimentos · Open Space · Reunião · Diretoria · Copa',
    floors: [
      FloorDef('Térreo', kPlanEscritorio),
      FloorDef('1º Andar', kPlanEscritorio),
      FloorDef('2º Andar', kPlanEscritorio),
    ],
  ),
];

// ---------------------------------------------------------------------------
// Modelo de dados
// ---------------------------------------------------------------------------

class RouterNode {
  final String id;
  Offset frac; // posição normalizada (0..1) dentro do pavimento
  int floor; // índice do pavimento onde o roteador está instalado
  RouterModelType model;
  RouterNode({required this.id, required this.frac, required this.floor, required this.model});
}

const double kDefaultHeatOpacity = 0.48;

/// Plantas embutidas no app (para reabrir projetos salvos ou importados).
const List<FloorPlanDef> kBuiltInPlans = [
  kPlanCasa2q,
  kPlanCasa2pTerreo,
  kPlanCasa2pAndar,
  kPlanta01,
  kPlanta02,
  kPlanta03,
  kPlanta04,
  kPlanEscritorio,
];

FloorPlanDef? builtInPlanById(String id) {
  for (final p in kBuiltInPlans) {
    if (p.id == id) return p;
  }
  return null;
}

/// Estado mutável de um pavimento: a planta (imutável) + escala real + paredes
/// desenhadas pelo usuário.
class FloorState {
  final String label;
  final FloorPlanDef plan;
  double widthM; // largura real da planta, em metros (calibrada pela régua)
  bool calibrated;
  final List<WallSegment> userWalls;
  FloorState(this.label, this.plan, {double? widthM, this.calibrated = false, List<WallSegment>? userWalls})
      : widthM = widthM ?? plan.defaultWidthM,
        userWalls = userWalls ?? [];

  double get heightM => widthM / plan.aspectRatio;
  List<WallSegment> get allWalls => [...plan.wallSegments, ...userWalls];
}

// ---------------------------------------------------------------------------
// Pontos de medição, medições de campo e dados do laudo
// ---------------------------------------------------------------------------

/// Resultado de uma medição de campo (RSSI + PHY + ping gateway/Internet).
class Measurement {
  final DateTime time;
  final bool native; // false = dados simulados (fora do WaveLens Shell)
  final String ssid;
  final String bssid;
  final String bandLabel;
  final int channel;
  final int rssi;
  final int linkMbps;
  final String gateway;
  final double? gwAvgMs;
  final double gwLossPct;
  final int gwSent;
  final double? netAvgMs;
  final double netLossPct;
  final int netSent;
  final String? pointId;
  final String? pointName;
  final int? floor;

  const Measurement({
    required this.time,
    required this.native,
    this.ssid = '',
    this.bssid = '',
    this.bandLabel = '',
    this.channel = 0,
    this.rssi = -100,
    this.linkMbps = 0,
    this.gateway = '',
    this.gwAvgMs,
    this.gwLossPct = 0,
    this.gwSent = 0,
    this.netAvgMs,
    this.netLossPct = 0,
    this.netSent = 0,
    this.pointId,
    this.pointName,
    this.floor,
  });

  Measurement linkedTo(String? id, String? name, int? floorIndex) => Measurement(
        time: time,
        native: native,
        ssid: ssid,
        bssid: bssid,
        bandLabel: bandLabel,
        channel: channel,
        rssi: rssi,
        linkMbps: linkMbps,
        gateway: gateway,
        gwAvgMs: gwAvgMs,
        gwLossPct: gwLossPct,
        gwSent: gwSent,
        netAvgMs: netAvgMs,
        netLossPct: netLossPct,
        netSent: netSent,
        pointId: id,
        pointName: name,
        floor: floorIndex,
      );

  Map<String, dynamic> toJson() => {
        'time': time.toIso8601String(),
        'native': native,
        'ssid': ssid,
        'bssid': bssid,
        'band': bandLabel,
        'channel': channel,
        'rssi': rssi,
        'linkMbps': linkMbps,
        'gateway': gateway,
        'gwAvgMs': gwAvgMs,
        'gwLossPct': gwLossPct,
        'gwSent': gwSent,
        'netAvgMs': netAvgMs,
        'netLossPct': netLossPct,
        'netSent': netSent,
        'pointId': pointId,
        'pointName': pointName,
        'floor': floor,
      };

  factory Measurement.fromJson(Map<String, dynamic> j) => Measurement(
        time: DateTime.tryParse('${j['time']}') ?? DateTime.now(),
        native: j['native'] == true,
        ssid: (j['ssid'] as String?) ?? '',
        bssid: (j['bssid'] as String?) ?? '',
        bandLabel: (j['band'] as String?) ?? '',
        channel: (j['channel'] as num?)?.toInt() ?? 0,
        rssi: (j['rssi'] as num?)?.toInt() ?? -100,
        linkMbps: (j['linkMbps'] as num?)?.toInt() ?? 0,
        gateway: (j['gateway'] as String?) ?? '',
        gwAvgMs: (j['gwAvgMs'] as num?)?.toDouble(),
        gwLossPct: (j['gwLossPct'] as num?)?.toDouble() ?? 0,
        gwSent: (j['gwSent'] as num?)?.toInt() ?? 0,
        netAvgMs: (j['netAvgMs'] as num?)?.toDouble(),
        netLossPct: (j['netLossPct'] as num?)?.toDouble() ?? 0,
        netSent: (j['netSent'] as num?)?.toInt() ?? 0,
        pointId: j['pointId'] as String?,
        pointName: j['pointName'] as String?,
        floor: (j['floor'] as num?)?.toInt(),
      );
}

/// Ponto de medição marcado na planta (ex.: "Quarto 2"): recebe a previsão do
/// simulador e, opcionalmente, uma medição real.
class MeasurePoint {
  final String id;
  String name;
  Offset frac;
  int floor;
  Measurement? measured;
  MeasurePoint({required this.id, required this.name, required this.frac, required this.floor, this.measured});
}

/// Dados do laudo de vistoria (persistidos junto com o projeto).
class ReportInfo {
  String technician;
  String company;
  String client;
  String address;
  String notes;
  String signerName;
  DateTime? date;
  Uint8List? logo;
  Uint8List? signature;
  DateTime? signedAt;

  ReportInfo({
    this.technician = '',
    this.company = '',
    this.client = '',
    this.address = '',
    this.notes = '',
    this.signerName = '',
    this.date,
    this.logo,
    this.signature,
    this.signedAt,
  });

  Map<String, dynamic> toJson() => {
        'technician': technician,
        'company': company,
        'client': client,
        'address': address,
        'notes': notes,
        'signerName': signerName,
        'date': date?.toIso8601String(),
        'logo': logo == null ? null : base64Encode(logo!),
        'signature': signature == null ? null : base64Encode(signature!),
        'signedAt': signedAt?.toIso8601String(),
      };

  factory ReportInfo.fromJson(Map<String, dynamic> j) => ReportInfo(
        technician: (j['technician'] as String?) ?? '',
        company: (j['company'] as String?) ?? '',
        client: (j['client'] as String?) ?? '',
        address: (j['address'] as String?) ?? '',
        notes: (j['notes'] as String?) ?? '',
        signerName: (j['signerName'] as String?) ?? '',
        date: DateTime.tryParse('${j['date']}'),
        logo: j['logo'] is String ? base64Decode(j['logo'] as String) : null,
        signature: j['signature'] is String ? base64Decode(j['signature'] as String) : null,
        signedAt: DateTime.tryParse('${j['signedAt']}'),
      );
}

/// Ferramenta ativa sobre o mapa.
enum CanvasTool { routers, walls, ruler, points }

String _newId(String prefix) => '$prefix${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

/// Estado do simulador (projeto, pavimentos, roteadores, paredes, pontos e
/// laudo). Usa ChangeNotifier para que só o CustomPainter do mapa de calor seja
/// re-renderizado durante o arraste, sem reconstruir toda a árvore de widgets.
class NetworkModel extends ChangeNotifier {
  String workspaceId = _newId('w');
  String workspaceName = kProjectLibrary[0].name;
  DateTime updatedAt = DateTime.now();

  ProjectDef currentProject = kProjectLibrary[0];
  List<FloorState> floors = [for (final f in kProjectLibrary[0].floors) FloorState(f.label, f.plan)];
  int floorIndex = 0;
  RouterModelType selectedModel = RouterModelType.huaweiAx3;
  double heatOpacity = kDefaultHeatOpacity;
  RfBand band = RfBand.ghz24;

  CanvasTool tool = CanvasTool.routers;
  WallMaterial wallMaterial = WallMaterial.drywall;
  double concreteDb = 13.5;

  final List<RouterNode> routers = [];
  final List<MeasurePoint> points = [];
  final List<Measurement> logs = [];
  ReportInfo report = ReportInfo();
  int _counter = 0;
  int _pointCounter = 0;

  FloorState get currentFloor => floors[floorIndex];
  FloorPlanDef get currentPlan => currentFloor.plan;
  List<RouterNode> get routersOnFloor => routers.where((r) => r.floor == floorIndex).toList();
  List<MeasurePoint> get pointsOnFloor => points.where((p) => p.floor == floorIndex).toList();

  /// Atenuação (dB, em 2.4 GHz) do material de parede selecionado.
  double get selectedWallDb {
    final spec = wallMaterialSpec(wallMaterial);
    return spec.adjustable ? concreteDb.clamp(spec.minDb, spec.maxDb).toDouble() : spec.defaultDb;
  }

  SignalField fieldFor(int floor, {RfBand? band}) {
    final f = floors[floor];
    return SignalField(
      routers: routers,
      walls: f.allWalls,
      floorIndex: floor,
      widthM: f.widthM,
      aspect: f.plan.aspectRatio,
      band: band ?? this.band,
    );
  }

  /// Começa um projeto novo (área de trabalho vazia) a partir de uma planta.
  void setProject(ProjectDef project) {
    workspaceId = _newId('w');
    workspaceName = project.name;
    currentProject = project;
    floors = [for (final f in project.floors) FloorState(f.label, f.plan)];
    floorIndex = 0;
    routers.clear();
    points.clear();
    logs.clear();
    report = ReportInfo();
    _counter = 0;
    _pointCounter = 0;
    tool = CanvasTool.routers;
    notifyListeners();
  }

  void setFloor(int index) {
    if (index < 0 || index >= floors.length || index == floorIndex) return;
    floorIndex = index;
    notifyListeners();
  }

  /// Acrescenta pavimentos ao projeto atual e passa a mostrar o primeiro deles.
  void addFloors(List<FloorDef> extra) {
    if (extra.isEmpty) return;
    floors = [...floors, for (final f in extra) FloorState(f.label, f.plan)];
    floorIndex = floors.length - extra.length;
    notifyListeners();
  }

  void setHeatOpacity(double value) {
    heatOpacity = value;
    notifyListeners();
  }

  void setBand(RfBand value) {
    if (band == value) return;
    band = value;
    notifyListeners();
  }

  void setTool(CanvasTool value) {
    if (tool == value) return;
    tool = value;
    notifyListeners();
  }

  void setWallMaterial(WallMaterial value) {
    wallMaterial = value;
    notifyListeners();
  }

  void setConcreteDb(double value) {
    concreteDb = value;
    notifyListeners();
  }

  void setSelectedModel(RouterModelType type) {
    if (selectedModel == type) return;
    selectedModel = type;
    notifyListeners();
  }

  void addRouter(Offset frac, {RouterModelType? model}) {
    routers.add(RouterNode(id: 'r${_counter++}', frac: frac, floor: floorIndex, model: model ?? selectedModel));
    notifyListeners();
  }

  void moveRouter(String id, Offset frac) {
    final router = routers.firstWhere((r) => r.id == id);
    router.frac = frac;
    notifyListeners();
  }

  void removeRouter(String id) {
    routers.removeWhere((r) => r.id == id);
    notifyListeners();
  }

  void clear() {
    if (routers.isEmpty) return;
    routers.clear();
    notifyListeners();
  }

  // --- Paredes desenhadas pelo usuário ---

  void addUserWall(Offset a, Offset b) {
    currentFloor.userWalls.add(WallSegment(a, b, attenuationDb: selectedWallDb, material: wallMaterial));
    notifyListeners();
  }

  void updateUserWall(int index, WallMaterial material, double db) {
    final old = currentFloor.userWalls[index];
    currentFloor.userWalls[index] = WallSegment(old.a, old.b, attenuationDb: db, material: material);
    notifyListeners();
  }

  void removeUserWall(int index) {
    currentFloor.userWalls.removeAt(index);
    notifyListeners();
  }

  void clearUserWalls() {
    if (currentFloor.userWalls.isEmpty) return;
    currentFloor.userWalls.clear();
    notifyListeners();
  }

  // --- Calibração da régua: define a largura real da planta atual ---

  /// [a] e [b] são as pontas da linha de calibração (frações) e [meters] a
  /// distância real entre elas. A largura da planta é derivada da proporção.
  void calibrate(Offset a, Offset b, double meters) {
    final aspect = currentPlan.aspectRatio;
    // Comprimento da linha medido em "larguras da planta" (a altura vale 1/aspect).
    final lenInWidths = sqrt(pow(b.dx - a.dx, 2) + pow((b.dy - a.dy) / aspect, 2));
    if (lenInWidths < 1e-4 || meters <= 0) return;
    currentFloor.widthM = meters / lenInWidths;
    currentFloor.calibrated = true;
    notifyListeners();
  }

  void resetCalibration() {
    currentFloor.widthM = currentPlan.defaultWidthM;
    currentFloor.calibrated = false;
    notifyListeners();
  }

  /// Comprimento real (m) de um segmento em frações da planta atual.
  double lengthMeters(Offset a, Offset b) {
    final f = currentFloor;
    final dx = (b.dx - a.dx) * f.widthM;
    final dy = (b.dy - a.dy) * f.heightM;
    return sqrt(dx * dx + dy * dy);
  }

  // --- Pontos de medição e registros de diagnóstico ---

  MeasurePoint addPoint(Offset frac, {String? name}) {
    final n = ++_pointCounter;
    final p = MeasurePoint(id: 'p${_newId('')}', name: name ?? 'P$n', frac: frac, floor: floorIndex);
    points.add(p);
    notifyListeners();
    return p;
  }

  void movePoint(String id, Offset frac) {
    points.firstWhere((p) => p.id == id).frac = frac;
    notifyListeners();
  }

  void renamePoint(String id, String name) {
    points.firstWhere((p) => p.id == id).name = name;
    notifyListeners();
  }

  void removePoint(String id) {
    points.removeWhere((p) => p.id == id);
    notifyListeners();
  }

  /// Registra uma medição no histórico e, se houver [point], vincula ao ponto.
  void recordMeasurement(Measurement m, {MeasurePoint? point}) {
    final linked = m.linkedTo(point?.id, point?.name, point?.floor);
    logs.add(linked);
    if (point != null) point.measured = linked;
    notifyListeners();
  }

  void clearLogs() {
    logs.clear();
    for (final p in points) {
      p.measured = null;
    }
    notifyListeners();
  }

  /// Avisa que dados do laudo mudaram (para o autosave).
  void touch() => notifyListeners();

  // --- Serialização (armazenamento local e arquivo .json) ---

  Map<String, dynamic> toJson({required bool embedImages}) {
    return {
      'format': 'netfloor-project',
      'schema': 1,
      'appVersion': kAppVersion,
      'id': workspaceId,
      'name': workspaceName,
      'updatedAt': updatedAt.toIso8601String(),
      'projectId': currentProject.id,
      'projectName': currentProject.name,
      'projectSubtitle': currentProject.subtitle,
      'isCustom': currentProject.isCustom,
      'floorIndex': floorIndex,
      'band': band.name,
      'model': selectedModel.name,
      'heatOpacity': heatOpacity,
      'floors': [
        for (final f in floors)
          {
            'label': f.label,
            'planId': f.plan.id,
            'planName': f.plan.name,
            'planSubtitle': f.plan.subtitle,
            'aspect': f.plan.aspectRatio,
            'custom': f.plan.isCustom,
            if (f.plan.isCustom) 'imageId': f.plan.id,
            if (f.plan.isCustom && embedImages) 'imageBase64': base64Encode(f.plan.memoryBytes!),
            'widthM': f.widthM,
            'calibrated': f.calibrated,
            'walls': [
              for (final w in f.userWalls)
                {'ax': w.a.dx, 'ay': w.a.dy, 'bx': w.b.dx, 'by': w.b.dy, 'db': w.attenuationDb, 'mat': w.material?.name},
            ],
          },
      ],
      'routers': [
        for (final r in routers) {'id': r.id, 'x': r.frac.dx, 'y': r.frac.dy, 'floor': r.floor, 'model': r.model.name},
      ],
      'points': [
        for (final p in points)
          {'id': p.id, 'name': p.name, 'x': p.frac.dx, 'y': p.frac.dy, 'floor': p.floor, 'measured': p.measured?.toJson()},
      ],
      'logs': [for (final l in logs) l.toJson()],
      'report': report.toJson(),
    };
  }

  /// Ids das imagens personalizadas que o documento [j] precisa.
  static List<String> customImageIds(Map<String, dynamic> j) {
    return [
      for (final f in (j['floors'] as List? ?? const []))
        if (f is Map && f['custom'] == true && f['imageId'] is String) f['imageId'] as String,
    ];
  }

  /// Restaura o estado a partir de [j]. [images] traz os bytes das plantas
  /// personalizadas (por id). Lança [FormatException] se o documento for inválido.
  void applyJson(Map<String, dynamic> j, Map<String, Uint8List> images, {bool newId = false}) {
    // 'netfloor-project' é o identificador interno do formato (mantido por compatibilidade com exports antigos).
    if (j['format'] != 'netfloor-project') throw const FormatException('Arquivo não é um projeto do WaveLens.');
    final newFloors = <FloorState>[];
    for (final raw in (j['floors'] as List? ?? const [])) {
      final f = (raw as Map).cast<String, dynamic>();
      FloorPlanDef? plan;
      if (f['custom'] == true) {
        final id = newId ? _newId('custom_') : ((f['imageId'] as String?) ?? (f['planId'] as String? ?? _newId('custom_')));
        final embedded = f['imageBase64'];
        final bytes = embedded is String ? base64Decode(embedded) : images[(f['imageId'] as String?) ?? id];
        if (bytes == null) throw FormatException('Imagem da planta ausente (${f['planName']}).');
        plan = FloorPlanDef(
          id: id,
          name: (f['planName'] as String?) ?? 'Planta',
          subtitle: (f['planSubtitle'] as String?) ?? 'Planta personalizada',
          memoryBytes: bytes,
          aspectRatio: (f['aspect'] as num?)?.toDouble() ?? 1.0,
        );
      } else {
        plan = builtInPlanById('${f['planId']}');
        if (plan == null) throw FormatException('Planta desconhecida: ${f['planId']}');
      }
      newFloors.add(
        FloorState(
          (f['label'] as String?) ?? floorLabel(newFloors.length),
          plan,
          widthM: (f['widthM'] as num?)?.toDouble(),
          calibrated: f['calibrated'] == true,
          userWalls: [
            for (final w in (f['walls'] as List? ?? const []))
              WallSegment(
                Offset(((w as Map)['ax'] as num).toDouble(), (w['ay'] as num).toDouble()),
                Offset((w['bx'] as num).toDouble(), (w['by'] as num).toDouble()),
                attenuationDb: (w['db'] as num?)?.toDouble() ?? 6.0,
                material: WallMaterial.values.asNameMap()[w['mat']] ?? WallMaterial.drywall,
              ),
          ],
        ),
      );
    }
    if (newFloors.isEmpty) throw const FormatException('Projeto sem pavimentos.');

    workspaceId = newId ? _newId('w') : ((j['id'] as String?) ?? _newId('w'));
    workspaceName = (j['name'] as String?) ?? 'Projeto importado';
    updatedAt = DateTime.tryParse('${j['updatedAt']}') ?? DateTime.now();
    final builtIn = kProjectLibrary.where((p) => p.id == j['projectId']);
    currentProject = builtIn.isNotEmpty
        ? builtIn.first
        : ProjectDef(
            id: (j['projectId'] as String?) ?? workspaceId,
            name: (j['projectName'] as String?) ?? workspaceName,
            subtitle: (j['projectSubtitle'] as String?) ?? '',
            floors: [for (final f in newFloors) FloorDef(f.label, f.plan)],
            isCustom: j['isCustom'] == true,
          );
    floors = newFloors;
    floorIndex = ((j['floorIndex'] as num?)?.toInt() ?? 0).clamp(0, newFloors.length - 1);
    band = RfBand.values.asNameMap()[j['band']] ?? RfBand.ghz24;
    selectedModel = RouterModelType.values.asNameMap()[j['model']] ?? RouterModelType.huaweiAx3;
    heatOpacity = (j['heatOpacity'] as num?)?.toDouble() ?? kDefaultHeatOpacity;

    routers
      ..clear()
      ..addAll([
        for (final r in (j['routers'] as List? ?? const []))
          RouterNode(
            id: (r as Map)['id'] as String,
            frac: Offset((r['x'] as num).toDouble(), (r['y'] as num).toDouble()),
            floor: ((r['floor'] as num?)?.toInt() ?? 0).clamp(0, newFloors.length - 1),
            model: RouterModelType.values.asNameMap()[r['model']] ?? RouterModelType.huaweiAx3,
          ),
      ]);
    points
      ..clear()
      ..addAll([
        for (final p in (j['points'] as List? ?? const []))
          MeasurePoint(
            id: (p as Map)['id'] as String,
            name: (p['name'] as String?) ?? 'P',
            frac: Offset((p['x'] as num).toDouble(), (p['y'] as num).toDouble()),
            floor: ((p['floor'] as num?)?.toInt() ?? 0).clamp(0, newFloors.length - 1),
            measured: p['measured'] is Map ? Measurement.fromJson((p['measured'] as Map).cast<String, dynamic>()) : null,
          ),
      ]);
    logs
      ..clear()
      ..addAll([
        for (final l in (j['logs'] as List? ?? const [])) Measurement.fromJson((l as Map).cast<String, dynamic>()),
      ]);
    report = j['report'] is Map ? ReportInfo.fromJson((j['report'] as Map).cast<String, dynamic>()) : ReportInfo();
    _counter = routers.length + 1000;
    _pointCounter = points.length;
    tool = CanvasTool.routers;
    notifyListeners();
  }
}

const String kAppVersion = '8.2';

/// Nome do produto exibido ao usuário (título, cabeçalhos, laudo em PDF).
/// Identificadores técnicos internos (bridge `NetFloorNative`, formato de
/// arquivo `netfloor-project`, repositórios/URL) não mudam com o rebranding.
const String kAppName = 'WaveLens';

// ---------------------------------------------------------------------------
// Modelo de propagação de sinal (2.5D), agora em METROS reais
//
//   Sinal(x,y) = max_i ( Ptx_i + Δref(banda) − k(banda)·log10(d3D_i)
//                        − fator(banda) · Σ perda de paredes − 15 · Δandares )
//   d3D = sqrt(dx² + dy² + (Δandares · altura do piso)²), mínimo de 1 m
//
// A escala (m por unidade de planta) vem da largura real do pavimento, que o
// usuário calibra com a régua. Os pavimentos são empilhados sobre a mesma
// pegada (mesma posição fracionária x,y em cada andar); as paredes usadas são
// as do pavimento exibido.
// ---------------------------------------------------------------------------

const double kFloorHeightM = 3.0; // altura entre pisos
const double kSlabLossDb = 15.0; // laje de concreto, por andar (não depende da banda)

/// Limiares da legenda (dBm).
const double kStrongDbm = 12.0;
const double kWeakDbm = -10.0;

/// Teste de interseção entre dois segmentos de reta (caso geral).
bool _segmentsIntersect(Offset p1, Offset p2, Offset p3, Offset p4) {
  double orient(Offset a, Offset b, Offset c) => (b.dx - a.dx) * (c.dy - a.dy) - (b.dy - a.dy) * (c.dx - a.dx);
  final o1 = orient(p1, p2, p3);
  final o2 = orient(p1, p2, p4);
  final o3 = orient(p3, p4, p1);
  final o4 = orient(p3, p4, p2);
  return ((o1 > 0) != (o2 > 0)) && ((o3 > 0) != (o4 > 0));
}

/// Uma parede já convertida para o espaço em metros do pavimento.
class _MeterWall {
  final Offset a;
  final Offset b;
  final double attenuationDb;
  const _MeterWall(this.a, this.b, this.attenuationDb);
}

/// Campo de sinal de um pavimento: dado um ponto (fração da planta), devolve o
/// nível em dBm. Compartilhado pelo mapa de calor, pelos pontos de medição e
/// pelo laudo em PDF.
class SignalField {
  final double widthM;
  final double heightM;
  final RfBandSpec _band;
  final int floorIndex;
  final List<Offset> _pos;
  final List<double> _power;
  final List<int> _gap;
  final List<_MeterWall> _walls;

  SignalField._(this.widthM, this.heightM, this._band, this.floorIndex, this._pos, this._power, this._gap, this._walls);

  factory SignalField({
    required List<RouterNode> routers,
    required List<WallSegment> walls,
    required int floorIndex,
    required double widthM,
    required double aspect,
    required RfBand band,
  }) {
    final heightM = widthM / aspect;
    Offset toM(Offset f) => Offset(f.dx * widthM, f.dy * heightM);
    return SignalField._(
      widthM,
      heightM,
      rfBandSpec(band),
      floorIndex,
      [for (final r in routers) toM(r.frac)],
      [for (final r in routers) _specFor(r.model).txPowerDbm],
      [for (final r in routers) (r.floor - floorIndex).abs()],
      [for (final w in walls) _MeterWall(toM(w.a), toM(w.b), w.attenuationDb)],
    );
  }

  bool get hasRouters => _pos.isNotEmpty;

  /// Nível previsto (dBm) no ponto [frac] do pavimento. Sem roteadores: -1000.
  double at(Offset frac) {
    final p = Offset(frac.dx * widthM, frac.dy * heightM);
    double best = -1000.0;
    for (var i = 0; i < _pos.length; i++) {
      final dxy = (p - _pos[i]).distance;
      final dz = _gap[i] * kFloorHeightM;
      final d = max(sqrt(dxy * dxy + dz * dz), 1.0);
      double walls = 0;
      for (final w in _walls) {
        if (_segmentsIntersect(p, _pos[i], w.a, w.b)) walls += w.attenuationDb;
      }
      final v = _power[i] +
          _band.refOffsetDb -
          _band.pathLossExp * (log(d) / ln10) -
          walls * _band.wallFactor -
          _gap[i] * kSlabLossDb;
      if (v > best) best = v;
    }
    return best;
  }
}

/// Classificação da legenda para um nível em dBm.
String signalClassLabel(double dbm) {
  if (dbm >= kStrongDbm) return 'Forte';
  if (dbm >= kWeakDbm) return 'Intermediário';
  return 'Ruim';
}

/// Estatística de cobertura de um pavimento (amostragem em grade).
class CoverageStats {
  final double strongPct;
  final double midPct;
  final double weakPct;
  final double bestDbm;
  final double worstDbm;
  final Offset worstFrac;
  const CoverageStats(this.strongPct, this.midPct, this.weakPct, this.bestDbm, this.worstDbm, this.worstFrac);
}

CoverageStats computeCoverage(SignalField field, {int cols = 60}) {
  final rows = max(1, (cols * field.heightM / field.widthM).round());
  var strong = 0, mid = 0, weak = 0;
  var best = -1000.0, worst = 1000.0;
  var worstFrac = const Offset(0.5, 0.5);
  for (var j = 0; j < rows; j++) {
    for (var i = 0; i < cols; i++) {
      final f = Offset((i + 0.5) / cols, (j + 0.5) / rows);
      final v = field.at(f);
      if (v >= kStrongDbm) {
        strong++;
      } else if (v >= kWeakDbm) {
        mid++;
      } else {
        weak++;
      }
      if (v > best) best = v;
      if (v < worst) {
        worst = v;
        worstFrac = f;
      }
    }
  }
  final total = (cols * rows).toDouble();
  return CoverageStats(strong / total * 100, mid / total * 100, weak / total * 100, best, worst, worstFrac);
}

// ---------------------------------------------------------------------------
// Paleta de calor estilo "jet", com desvanecimento (alpha) nas áreas de
// sinal fraco para deixar a planta visível por baixo do overlay.
// ---------------------------------------------------------------------------

const double _kDbmFloor = -30.0; // t = 0.0 (sem cobertura)
const double _kDbmCeil = 26.0; // t = 1.0 (perto da potência máxima do catálogo)

const List<double> _kStops = [0.0, 0.18, 0.38, 0.58, 0.74, 0.88, 1.0];
const List<Color> _kStopColors = [
  Color(0xFF1E3A8A), // azul profundo
  Color(0xFF2563EB), // azul
  Color(0xFF06B6D4), // ciano
  Color(0xFF22C55E), // verde
  Color(0xFFFACC15), // amarelo
  Color(0xFFFB923C), // laranja
  Color(0xFFEF4444), // vermelho
];

double _signalToT(double dbm) {
  return ((dbm - _kDbmFloor) / (_kDbmCeil - _kDbmFloor)).clamp(0.0, 1.0);
}

Color _jetColor(double t) {
  for (var i = 0; i < _kStops.length - 1; i++) {
    if (t <= _kStops[i + 1] || i == _kStops.length - 2) {
      final localT = ((t - _kStops[i]) / (_kStops[i + 1] - _kStops[i])).clamp(0.0, 1.0);
      return Color.lerp(_kStopColors[i], _kStopColors[i + 1], localT)!;
    }
  }
  return _kStopColors.last;
}

/// Suaviza a transição para transparente nas áreas de sinal muito fraco.
/// [maxAlpha] é a opacidade máxima do overlay (ajustável pelo usuário).
double _alphaForT(double t, double maxAlpha) {
  const lo = 0.04, hi = 0.55;
  final x = ((t - lo) / (hi - lo)).clamp(0.0, 1.0);
  final smooth = x * x * (3 - 2 * x);
  return smooth * maxAlpha;
}

// ---------------------------------------------------------------------------
// Pintura: planta baixa ilustrada (piso texturizado + paredes espessas +
// silhuetas de móveis), usada quando não há imagem disponível.
// ---------------------------------------------------------------------------

class FloorPlanPainter extends CustomPainter {
  final List<RoomDef> rooms;
  const FloorPlanPainter(this.rooms);

  bool _isWetArea(String label) {
    final l = label.toLowerCase();
    return l.contains('banheiro') || l.contains('lavabo') || l.contains('lavanderia') || l.contains('cozinha') || l.contains('copa');
  }

  void _drawFloor(Canvas canvas, Rect r, String label) {
    if (_isWetArea(label)) {
      canvas.drawRect(r, Paint()..color = const Color(0xFFF3F4F6));
      final grout = Paint()
        ..color = const Color(0xFFDDE3EA)
        ..strokeWidth = 1;
      const tile = 16.0;
      for (double x = r.left; x < r.right; x += tile) {
        canvas.drawLine(Offset(x, r.top), Offset(x, r.bottom), grout);
      }
      for (double y = r.top; y < r.bottom; y += tile) {
        canvas.drawLine(Offset(r.left, y), Offset(r.right, y), grout);
      }
    } else {
      canvas.drawRect(r, Paint()..color = const Color(0xFFE7D2B0));
      final plank = Paint()
        ..color = const Color(0xFFD4B489)
        ..strokeWidth = 1;
      const step = 18.0;
      for (double y = r.top; y < r.bottom; y += step) {
        canvas.drawLine(Offset(r.left, y), Offset(r.right, y), plank);
      }
    }
  }

  void _drawFurniture(Canvas canvas, Rect r, String label) {
    final wood = Paint()..color = const Color(0xFFB08968);
    final woodLight = Paint()..color = const Color(0xFFC9A67D);
    final fabric = Paint()..color = const Color(0xFFAEB8C4);
    final white = Paint()..color = Colors.white;
    final metal = Paint()..color = const Color(0xFF94A3B8);
    final short = min(r.width, r.height);
    final l = label.toLowerCase();

    if (l.contains('quarto') || l.contains('suíte') || l.contains('suite')) {
      final bed = Rect.fromLTWH(r.left + r.width * 0.10, r.top + r.height * 0.10, r.width * 0.52, r.height * 0.60);
      canvas.drawRRect(RRect.fromRectAndRadius(bed, const Radius.circular(6)), woodLight);
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(bed.left, bed.top, bed.width, bed.height * 0.24), const Radius.circular(6)),
        white,
      );
    } else if (l.contains('jantar')) {
      final table = Rect.fromLTWH(r.left + r.width * 0.24, r.top + r.height * 0.32, r.width * 0.52, r.height * 0.28);
      canvas.drawRRect(RRect.fromRectAndRadius(table, const Radius.circular(4)), wood);
      for (final dx in [0.30, 0.50, 0.70]) {
        canvas.drawCircle(Offset(r.left + r.width * dx, r.top + r.height * 0.18), short * 0.035, woodLight);
        canvas.drawCircle(Offset(r.left + r.width * dx, r.top + r.height * 0.68), short * 0.035, woodLight);
      }
    } else if (l.contains('sala') && !l.contains('reunião') && !l.contains('reuniao')) {
      final sofa = Rect.fromLTWH(r.left + r.width * 0.06, r.top + r.height * 0.55, r.width * 0.40, r.height * 0.30);
      canvas.drawRRect(RRect.fromRectAndRadius(sofa, const Radius.circular(8)), fabric);
      canvas.drawCircle(Offset(r.left + r.width * 0.60, r.top + r.height * 0.70), short * 0.07, woodLight);
    } else if (l.contains('cozinha') || l.contains('copa')) {
      canvas.drawRect(Rect.fromLTWH(r.left, r.top, r.width * 0.20, r.height), metal);
      canvas.drawRect(Rect.fromLTWH(r.left + r.width * 0.04, r.top + r.height * 0.10, r.width * 0.12, r.height * 0.14), white);
    } else if (l.contains('banheiro') || l.contains('lavabo')) {
      canvas.drawOval(Rect.fromLTWH(r.right - r.width * 0.32, r.bottom - r.height * 0.30, r.width * 0.24, r.height * 0.20), white);
      canvas.drawRect(Rect.fromLTWH(r.left + r.width * 0.08, r.top + r.height * 0.08, r.width * 0.22, r.height * 0.12), white);
    } else if (l.contains('reunião') ||
        l.contains('reuniao') ||
        l.contains('diretoria') ||
        l.contains('open space') ||
        l.contains('escritório') ||
        l.contains('escritorio')) {
      final table = Rect.fromLTWH(r.left + r.width * 0.18, r.top + r.height * 0.35, r.width * 0.64, r.height * 0.28);
      canvas.drawRRect(RRect.fromRectAndRadius(table, const Radius.circular(4)), wood);
    } else if (l.contains('varanda')) {
      final rail = Paint()
        ..color = const Color(0xFF94A3B8)
        ..strokeWidth = 1.4;
      for (double x = r.left + 6; x < r.right - 6; x += 10) {
        canvas.drawLine(Offset(x, r.top + 6), Offset(x, r.top + 20), rail);
      }
    } else if (l.contains('escada')) {
      final step = Paint()
        ..color = const Color(0xFF8B6A4A)
        ..strokeWidth = 2;
      const steps = 8;
      for (var i = 0; i <= steps; i++) {
        final y = r.top + r.height * i / steps;
        canvas.drawLine(Offset(r.left + r.width * 0.10, y), Offset(r.right - r.width * 0.10, y), step);
      }
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFF7F5F0));

    Rect rectOf(RoomDef room) => Rect.fromLTWH(
          room.rectFrac.left * size.width,
          room.rectFrac.top * size.height,
          room.rectFrac.width * size.width,
          room.rectFrac.height * size.height,
        );

    for (final room in rooms) {
      final rect = rectOf(room);
      _drawFloor(canvas, rect, room.label);
      _drawFurniture(canvas, rect, room.label);
    }

    // Paredes estruturais espessas por cima do piso/móveis.
    final wallPaint = Paint()
      ..color = const Color(0xFF211F1C)
      ..style = PaintingStyle.stroke
      ..strokeWidth = max(4.0, size.shortestSide * 0.018)
      ..strokeJoin = StrokeJoin.round;
    for (final room in rooms) {
      final rect = rectOf(room);
      canvas.drawRect(rect, wallPaint);

      final tp = TextPainter(
        text: TextSpan(
          text: room.label,
          style: const TextStyle(
            color: Colors.black87,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            backgroundColor: Color(0xB3FFFFFF),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: rect.width - 8);
      tp.paint(canvas, Offset(rect.left + 6, rect.top + 6));
    }

    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = const Color(0xFF211F1C)
        ..style = PaintingStyle.stroke
        ..strokeWidth = max(6.0, size.shortestSide * 0.03),
    );
  }

  @override
  bool shouldRepaint(covariant FloorPlanPainter oldDelegate) => oldDelegate.rooms != rooms;
}

// ---------------------------------------------------------------------------
// Planta de fundo com imagem remota (Image.network), com indicador de
// carregamento e um fallback (asset local ou desenho vetorial) se a rede falhar.
// ---------------------------------------------------------------------------

class NetworkFloorPlanImage extends StatelessWidget {
  final String url;
  final Widget fallback;
  const NetworkFloorPlanImage({super.key, required this.url, required this.fallback});

  @override
  Widget build(BuildContext context) {
    return Image.network(
      url,
      fit: BoxFit.fill,
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        return Container(
          color: Colors.grey.shade100,
          alignment: Alignment.center,
          child: const CircularProgressIndicator(),
        );
      },
      errorBuilder: (context, error, stackTrace) => fallback,
    );
  }
}

// ---------------------------------------------------------------------------
// Pintura: mapa de calor 2.5D com atenuação por paredes (ray-casting) e por
// lajes (roteadores de outros pavimentos).
// ---------------------------------------------------------------------------

class HeatmapPainter extends CustomPainter {
  final SignalField field;
  final double maxAlpha;
  final double cell; // lado da célula de amostragem (px do canvas onde é pintado)
  HeatmapPainter(this.field, this.maxAlpha, {this.cell = 8.0});

  // Amostragem em grade: equilíbrio entre qualidade visual e performance.
  // A grade é depois suavizada com um blur (ver ImageFiltered no build).
  final Paint _cellPaint = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    if (!field.hasRouters) return;

    for (double y = 0; y < size.height; y += cell) {
      final h = min(cell, size.height - y);
      for (double x = 0; x < size.width; x += cell) {
        final w = min(cell, size.width - x);
        final best = field.at(Offset((x + w / 2) / size.width, (y + h / 2) / size.height));

        final t = _signalToT(best);
        final alpha = _alphaForT(t, maxAlpha);
        if (alpha <= 0.003) continue;

        _cellPaint.color = _jetColor(t).withOpacity(alpha);
        canvas.drawRect(Rect.fromLTWH(x, y, w, h), _cellPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant HeatmapPainter oldDelegate) {
    // Este painter só é reconstruído dentro do AnimatedBuilder ligado ao
    // NetworkModel, ou seja, toda vez que uma nova instância é criada é
    // porque algo realmente mudou (roteador adicionado/movido/removido).
    return true;
  }
}

// ---------------------------------------------------------------------------
// Pintura: ferramentas de desenho sobre o mapa (paredes e régua de calibração)
// ---------------------------------------------------------------------------

void _dashedLine(Canvas canvas, Offset a, Offset b, Paint paint, {double dash = 6, double gap = 4}) {
  final total = (b - a).distance;
  if (total < 0.01) return;
  final dir = (b - a) / total;
  var d = 0.0;
  while (d < total) {
    final e = min(d + dash, total);
    canvas.drawLine(a + dir * d, a + dir * e, paint);
    d += dash + gap;
  }
}

class ToolOverlayPainter extends CustomPainter {
  final CanvasTool tool;
  final List<WallSegment> builtInWalls;
  final List<WallSegment> userWalls;
  final Offset? draftA; // fração
  final Offset? draftB; // fração
  final Color draftColor;
  final String? rulerLabel;
  final double zoom; // compensa o zoom do InteractiveViewer (traços de largura constante na tela)
  ToolOverlayPainter({
    required this.tool,
    required this.builtInWalls,
    required this.userWalls,
    required this.draftA,
    required this.draftB,
    required this.draftColor,
    required this.rulerLabel,
    required this.zoom,
  });

  @override
  void paint(Canvas canvas, Size size) {
    Offset px(Offset f) => Offset(f.dx * size.width, f.dy * size.height);
    final z = zoom <= 0 ? 1.0 : zoom;

    if (tool == CanvasTool.walls) {
      final thin = Paint()
        ..color = const Color(0xFF475569).withOpacity(0.85)
        ..strokeWidth = 2.0 / z
        ..strokeCap = StrokeCap.round;
      for (final w in builtInWalls) {
        _dashedLine(canvas, px(w.a), px(w.b), thin, dash: 7 / z, gap: 5 / z);
      }
    }
    {
      // Paredes do usuário ficam sempre visíveis (finas), para o técnico ver o que o cálculo considera.
      final bold = tool == CanvasTool.walls;
      for (final w in userWalls) {
        if (bold) {
          canvas.drawLine(
            px(w.a),
            px(w.b),
            Paint()
              ..color = Colors.white
              ..strokeWidth = 7.0 / z
              ..strokeCap = StrokeCap.round,
          );
        }
        canvas.drawLine(
          px(w.a),
          px(w.b),
          Paint()
            ..color = w.color
            ..strokeWidth = (bold ? 4.0 : 2.2) / z
            ..strokeCap = StrokeCap.round,
        );
      }
    }

    if (draftA != null && draftB != null && (tool == CanvasTool.walls || tool == CanvasTool.ruler)) {
      final a = px(draftA!);
      final b = px(draftB!);
      if (tool == CanvasTool.walls) {
        canvas.drawLine(
          a,
          b,
          Paint()
            ..color = Colors.white
            ..strokeWidth = 7.0 / z
            ..strokeCap = StrokeCap.round,
        );
        canvas.drawLine(
          a,
          b,
          Paint()
            ..color = draftColor
            ..strokeWidth = 4.0 / z
            ..strokeCap = StrokeCap.round,
        );
      } else {
        const ruler = Color(0xFFFF00C8);
        canvas.drawLine(
          a,
          b,
          Paint()
            ..color = Colors.black
            ..strokeWidth = 5.0 / z
            ..strokeCap = StrokeCap.round,
        );
        canvas.drawLine(
          a,
          b,
          Paint()
            ..color = ruler
            ..strokeWidth = 2.5 / z
            ..strokeCap = StrokeCap.round,
        );
        for (final e in [a, b]) {
          canvas.drawCircle(e, 6 / z, Paint()..color = Colors.black);
          canvas.drawCircle(e, 4.5 / z, Paint()..color = ruler);
        }
        if (rulerLabel != null) {
          final tp = TextPainter(
            text: TextSpan(
              text: rulerLabel,
              style: TextStyle(
                color: Colors.white,
                fontSize: 12 / z,
                fontWeight: FontWeight.bold,
                backgroundColor: Colors.black.withOpacity(0.78),
              ),
            ),
            textDirection: TextDirection.ltr,
          )..layout();
          final mid = (a + b) / 2;
          tp.paint(canvas, mid + Offset(-tp.width / 2, -tp.height - 8 / z));
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant ToolOverlayPainter oldDelegate) => true;
}

// ---------------------------------------------------------------------------
// Pintura: pulso de frequência saindo do roteador (efeito "radar")
// ---------------------------------------------------------------------------

class RadarPingPainter extends CustomPainter {
  final List<RouterNode> routers; // só os do pavimento exibido
  final double t; // progresso da animação, 0..1, em loop
  final double scale; // 1/zoom: mantém o tamanho do pulso constante na tela
  RadarPingPainter(this.routers, this.t, [this.scale = 1.0]);

  static const double _minRadius = 15.0;
  static const double _maxRadius = 48.0;

  void _ring(Canvas canvas, Offset center, double localT) {
    final radius = (_minRadius + (_maxRadius - _minRadius) * localT) * scale;
    final opacity = (1 - localT).clamp(0.0, 1.0) * 0.55;
    if (opacity <= 0.01) return;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = Colors.white.withOpacity(opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6 * scale,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    for (final r in routers) {
      final center = Offset(r.frac.dx * size.width, r.frac.dy * size.height);
      _ring(canvas, center, t);
      _ring(canvas, center, (t + 0.5) % 1.0);
    }
  }

  @override
  bool shouldRepaint(covariant RadarPingPainter oldDelegate) => true;
}

// ---------------------------------------------------------------------------
// Ícones dos roteadores, um estilo por modelo de hardware do catálogo.
// ---------------------------------------------------------------------------

class RouterDevicePainter extends CustomPainter {
  final RouterModelType model;
  const RouterDevicePainter(this.model);

  void _shadow(Canvas canvas, RRect rrect) {
    canvas.drawRRect(
      rrect.shift(const Offset(0, 1.6)),
      Paint()
        ..color = Colors.black.withOpacity(0.30)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.0),
    );
  }

  // Huawei AX3 Pro/AX3s: roteador de mesa clássico com 4 antenas externas.
  void _paintHuawei(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final bodyRect = Rect.fromLTWH(w * 0.14, h * 0.40, w * 0.72, h * 0.36);
    final bodyRRect = RRect.fromRectAndRadius(bodyRect, Radius.circular(h * 0.09));
    _shadow(canvas, bodyRRect);

    final antennaPaint = Paint()
      ..color = const Color(0xFF2A2D38)
      ..strokeWidth = w * 0.045
      ..strokeCap = StrokeCap.round;
    final xs = [
      bodyRect.left + w * 0.06,
      bodyRect.left + w * 0.22,
      bodyRect.right - w * 0.22,
      bodyRect.right - w * 0.06,
    ];
    for (final x in xs) {
      canvas.drawLine(Offset(x, bodyRect.top + h * 0.02), Offset(x, h * 0.01), antennaPaint);
    }

    canvas.drawRRect(
      bodyRRect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF4B5166), Color(0xFF1E212B)],
        ).createShader(bodyRect),
    );
    canvas.drawCircle(bodyRect.center, h * 0.045, Paint()..color = const Color(0xFF22C55E));
  }

  // TP-Link Deco: cilindro/torre minimalista, sem antenas visíveis.
  void _paintDeco(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final bodyRect = Rect.fromLTWH(w * 0.30, h * 0.12, w * 0.40, h * 0.74);
    final bodyRRect = RRect.fromRectAndRadius(bodyRect, Radius.circular(w * 0.20));
    _shadow(canvas, bodyRRect);

    canvas.drawRRect(
      bodyRRect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFF7F7F9), Color(0xFFD9D9DF)],
        ).createShader(bodyRect),
    );
    canvas.drawRRect(
      bodyRRect,
      Paint()
        ..color = Colors.black.withOpacity(0.08)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0,
    );
    canvas.drawLine(
      Offset(bodyRect.left + 2, bodyRect.center.dy),
      Offset(bodyRect.right - 2, bodyRect.center.dy),
      Paint()
        ..color = Colors.black.withOpacity(0.07)
        ..strokeWidth = 1.0,
    );
    canvas.drawCircle(Offset(bodyRect.center.dx, bodyRect.top + h * 0.10), h * 0.035, Paint()..color = const Color(0xFF22C55E));
  }

  // Ubiquiti UniFi AP: disco de teto circular com anel de iluminação central.
  void _paintUnifi(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final center = Offset(w / 2, h / 2);
    final radius = min(w, h) * 0.42;

    canvas.drawCircle(
      center.translate(0, 1.6),
      radius,
      Paint()
        ..color = Colors.black.withOpacity(0.28)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.2),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(colors: const [Color(0xFFFFFFFF), Color(0xFFE1E4E8)]).createShader(
          Rect.fromCircle(center: center, radius: radius),
        ),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = Colors.black.withOpacity(0.08)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0,
    );
    canvas.drawCircle(
      center,
      radius * 0.32,
      Paint()
        ..color = const Color(0xFF38BDF8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.05,
    );
  }

  // ZTE E2320 / E2620 (ZXHN, Wi-Fi 6): ONT/roteador branco compacto de mesa,
  // com duas antenas externas inclinadas e faixa de LEDs de status.
  void _paintZte(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final bodyRect = Rect.fromLTWH(w * 0.16, h * 0.42, w * 0.68, h * 0.34);
    final bodyRRect = RRect.fromRectAndRadius(bodyRect, Radius.circular(h * 0.07));
    _shadow(canvas, bodyRRect);

    final antennaPaint = Paint()
      ..color = const Color(0xFF3A3D46)
      ..strokeWidth = w * 0.05
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(bodyRect.left + w * 0.10, bodyRect.top + h * 0.02),
      Offset(bodyRect.left - w * 0.02, h * 0.00),
      antennaPaint,
    );
    canvas.drawLine(
      Offset(bodyRect.right - w * 0.10, bodyRect.top + h * 0.02),
      Offset(bodyRect.right + w * 0.02, h * 0.00),
      antennaPaint,
    );

    canvas.drawRRect(
      bodyRRect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFFDFDFD), Color(0xFFE4E6EA)],
        ).createShader(bodyRect),
    );
    canvas.drawRRect(
      bodyRRect,
      Paint()
        ..color = Colors.black.withOpacity(0.10)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0,
    );
    // Faixa de LEDs de status, padrão dos ONT/roteadores ZTE.
    final ledY = bodyRect.top + bodyRect.height * 0.62;
    const ledColors = [Color(0xFF22C55E), Color(0xFF38BDF8), Color(0xFF22C55E)];
    for (var i = 0; i < 3; i++) {
      canvas.drawCircle(
        Offset(bodyRect.left + bodyRect.width * (0.32 + i * 0.18), ledY),
        h * 0.018,
        Paint()..color = ledColors[i],
      );
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    switch (model) {
      case RouterModelType.huaweiAx3:
        _paintHuawei(canvas, size);
        break;
      case RouterModelType.tplinkDeco:
        _paintDeco(canvas, size);
        break;
      case RouterModelType.unifiAp:
        _paintUnifi(canvas, size);
        break;
      case RouterModelType.zteE2320:
        _paintZte(canvas, size);
        break;
    }
  }

  @override
  bool shouldRepaint(covariant RouterDevicePainter oldDelegate) => oldDelegate.model != model;
}

// ---------------------------------------------------------------------------
// Tela do simulador
// ---------------------------------------------------------------------------

/// Filtro de cor do "Modo Apresentação": inverte a luminosidade da planta
/// (fundo escuro, traços claros) preservando os matizes (equivale a
/// `invert(.9) hue-rotate(180deg)`), para o mapa de calor "saltar" da tela.
const ColorFilter kDarkPlanFilter = ColorFilter.matrix(<double>[
  0.5166, -1.287, -0.1296, 0, 243.5, //
  -0.3834, -0.387, -0.1296, 0, 243.5, //
  -0.3834, -1.287, 0.7704, 0, 243.5, //
  0, 0, 0, 1, 0,
]);

/// Filtro do "Modo Diagnóstico": planta em tons de cinza com contraste
/// aumentado — o calor colorido se destaca sob sol forte.
const ColorFilter kContrastPlanFilter = ColorFilter.matrix(<double>[
  0.2764, 0.9298, 0.0939, 0, -38.4, //
  0.2764, 0.9298, 0.0939, 0, -38.4, //
  0.2764, 0.9298, 0.0939, 0, -38.4, //
  0, 0, 0, 1, 0,
]);

class SimulatorPage extends StatefulWidget {
  final NetworkModel model;
  final DiagnosticsController diag;
  final AppStore store;
  const SimulatorPage({super.key, required this.model, required this.diag, required this.store});

  @override
  State<SimulatorPage> createState() => _SimulatorPageState();
}

class _SimulatorPageState extends State<SimulatorPage> with SingleTickerProviderStateMixin {
  NetworkModel get _model => widget.model;
  late final AnimationController _pingController;
  final TransformationController _tc = TransformationController();
  final ValueNotifier<int> _draftTick = ValueNotifier<int>(0);

  static const double _markerRadius = 20.0;
  static const double _maxZoom = 12.0;
  static const String _uploadSentinel = 'upload';
  static const String _importSentinel = 'import';
  Size _lastCanvasSize = const Size(320, 320 / (736 / 1105));

  // Interação no mapa por ponteiros "crus" (Listener): assim os toques/arrastos
  // do técnico convivem com o pinch-zoom/pan do InteractiveViewer.
  final Map<int, Offset> _ptrs = {};
  bool _multi = false;
  bool _moved = false;
  Offset _downLocal = Offset.zero;
  Offset _downGlobal = Offset.zero;
  DateTime _downTime = DateTime.now();
  String? _dragRouterId;
  String? _dragPointId;
  Offset _grab = Offset.zero;
  Offset? _draftA;
  Offset? _draftB;

  double get _zoom => _tc.value.getMaxScaleOnAxis();

  @override
  void initState() {
    super.initState();
    _pingController = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400))..repeat();
  }

  @override
  void dispose() {
    _pingController.dispose();
    _tc.dispose();
    _draftTick.dispose();
    super.dispose();
  }

  // Posições são frações (0..1) do pavimento; aqui convertemos de/para pixels
  // do canvas (coordenadas do filho do InteractiveViewer, sem o zoom).
  Offset _toPx(Offset frac, Size b) => Offset(frac.dx * b.width, frac.dy * b.height);
  Offset _toFrac(Offset px) {
    final b = _lastCanvasSize;
    return Offset((px.dx / b.width).clamp(0.0, 1.0).toDouble(), (px.dy / b.height).clamp(0.0, 1.0).toDouble());
  }

  Offset _clampFrac(Offset frac, Size b) {
    if (b.width <= 0 || b.height <= 0) return frac;
    final r = _markerRadius / _zoom;
    final mx = r / b.width;
    final my = r / b.height;
    return Offset(
      frac.dx.clamp(mx, max(mx, 1 - mx)).toDouble(),
      frac.dy.clamp(my, max(my, 1 - my)).toDouble(),
    );
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _resetZoom() => _tc.value = Matrix4.identity();

  /// Zoom pelos botões (+/−), ancorado no centro do mapa.
  void _zoomBy(double factor) {
    final cur = _zoom;
    final target = (cur * factor).clamp(1.0, _maxZoom).toDouble();
    final k = target / cur;
    final w = _lastCanvasSize.width, h = _lastCanvasSize.height;
    final c = Offset(w / 2, h / 2);
    final t = Matrix4.identity()
      ..translateByDouble(c.dx, c.dy, 0, 1)
      ..scaleByDouble(k, k, 1, 1)
      ..translateByDouble(-c.dx, -c.dy, 0, 1);
    final res = t * _tc.value;
    final s = res.getMaxScaleOnAxis();
    final tr = res.getTranslation();
    res.setTranslationRaw(tr.x.clamp(w * (1 - s), 0.0).toDouble(), tr.y.clamp(h * (1 - s), 0.0).toDouble(), 0);
    _tc.value = res;
  }

  // ---------------------------------------------------------------------
  // Hit-tests (em pixels do canvas)
  // ---------------------------------------------------------------------

  RouterNode? _hitRouter(Offset local) {
    final limit = (_markerRadius + 6) / _zoom;
    RouterNode? best;
    var bestD = limit;
    for (final r in _model.routersOnFloor) {
      final d = (_toPx(r.frac, _lastCanvasSize) - local).distance;
      if (d <= bestD) {
        best = r;
        bestD = d;
      }
    }
    return best;
  }

  MeasurePoint? _hitPoint(Offset local) {
    final limit = 16 / _zoom;
    MeasurePoint? best;
    var bestD = limit;
    for (final p in _model.pointsOnFloor) {
      final d = (_toPx(p.frac, _lastCanvasSize) - local).distance;
      if (d <= bestD) {
        best = p;
        bestD = d;
      }
    }
    return best;
  }

  int? _hitUserWall(Offset local) {
    final limit = 12 / _zoom;
    int? best;
    var bestD = limit;
    final walls = _model.currentFloor.userWalls;
    for (var i = 0; i < walls.length; i++) {
      final a = _toPx(walls[i].a, _lastCanvasSize);
      final b = _toPx(walls[i].b, _lastCanvasSize);
      final ab = b - a;
      final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
      final t = len2 == 0 ? 0.0 : (((local - a).dx * ab.dx + (local - a).dy * ab.dy) / len2).clamp(0.0, 1.0);
      final d = (local - (a + ab * t)).distance;
      if (d <= bestD) {
        best = i;
        bestD = d;
      }
    }
    return best;
  }

  /// Ajusta o ponto [f] às pontas de paredes existentes (encaixe de cantos).
  Offset _snapToCorners(Offset f) {
    final limit = 12 / _zoom;
    Offset? best;
    var bestD = limit;
    for (final w in _model.currentFloor.allWalls) {
      for (final e in [w.a, w.b]) {
        final d = (_toPx(e, _lastCanvasSize) - _toPx(f, _lastCanvasSize)).distance;
        if (d <= bestD) {
          best = e;
          bestD = d;
        }
      }
    }
    return best ?? f;
  }

  /// Trava a linha em horizontal/vertical quando está a menos de ~4° do eixo.
  Offset _snapAxis(Offset a, Offset b) {
    final size = _lastCanvasSize;
    final d = _toPx(b, size) - _toPx(a, size);
    if (d.distance < 12) return b;
    final deg = atan2(d.dy, d.dx) * 180 / pi;
    final m = (deg / 90).round() * 90;
    if ((deg - m).abs() > 4) return b;
    return m % 180 == 0 ? Offset(b.dx, a.dy) : Offset(a.dx, b.dy);
  }

  // ---------------------------------------------------------------------
  // Gestos no mapa
  // ---------------------------------------------------------------------

  void _cancelGesture() {
    _dragRouterId = null;
    _dragPointId = null;
    if (_draftA != null) {
      _draftA = null;
      _draftB = null;
      _draftTick.value++;
    }
  }

  void _onPointerDown(PointerDownEvent e) {
    _ptrs[e.pointer] = e.localPosition;
    if (_ptrs.length > 1) {
      // Segundo dedo: vira gesto de navegação (pinch/pan do InteractiveViewer).
      _multi = true;
      _cancelGesture();
      setState(() {});
      return;
    }
    _multi = false;
    _moved = false;
    _downLocal = e.localPosition;
    _downGlobal = e.position;
    _downTime = DateTime.now();

    switch (_model.tool) {
      case CanvasTool.routers:
        final hit = _hitRouter(e.localPosition);
        if (hit != null) {
          _dragRouterId = hit.id;
          _grab = _toPx(hit.frac, _lastCanvasSize) - e.localPosition;
          setState(() {}); // bloqueia o pan do InteractiveViewer durante o arraste
        }
      case CanvasTool.points:
        final hit = _hitPoint(e.localPosition);
        if (hit != null) {
          _dragPointId = hit.id;
          _grab = _toPx(hit.frac, _lastCanvasSize) - e.localPosition;
          setState(() {});
        }
      case CanvasTool.walls:
        _draftA = _snapToCorners(_toFrac(e.localPosition));
        _draftB = _draftA;
        _draftTick.value++;
      case CanvasTool.ruler:
        _draftA = _toFrac(e.localPosition);
        _draftB = _draftA;
        _draftTick.value++;
    }
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (!_ptrs.containsKey(e.pointer)) return;
    _ptrs[e.pointer] = e.localPosition;
    if (_multi) return;
    if (!_moved && (e.position - _downGlobal).distance > 8) _moved = true;
    if (!_moved) return;

    final size = _lastCanvasSize;
    if (_dragRouterId != null) {
      final px = e.localPosition + _grab;
      _model.moveRouter(_dragRouterId!, _clampFrac(Offset(px.dx / size.width, px.dy / size.height), size));
    } else if (_dragPointId != null) {
      final px = e.localPosition + _grab;
      _model.movePoint(_dragPointId!, _clampFrac(Offset(px.dx / size.width, px.dy / size.height), size));
    } else if (_draftA != null) {
      final raw = _toFrac(e.localPosition);
      _draftB = _model.tool == CanvasTool.walls ? _snapAxis(_draftA!, _snapToCorners(raw)) : raw;
      _draftTick.value++;
    }
  }

  void _onPointerUp(PointerUpEvent e) {
    final wasMulti = _multi;
    _ptrs.remove(e.pointer);
    if (_ptrs.isNotEmpty) return;
    _multi = false;
    if (!wasMulti) _finishGesture(e);
    final hadDrag = _dragRouterId != null || _dragPointId != null;
    _dragRouterId = null;
    _dragPointId = null;
    if (hadDrag || wasMulti) setState(() {});
  }

  void _onPointerCancel(PointerCancelEvent e) {
    _ptrs.remove(e.pointer);
    if (_ptrs.isEmpty) {
      _multi = false;
      _cancelGesture();
      setState(() {});
    }
  }

  Future<void> _finishGesture(PointerUpEvent e) async {
    final isTap = !_moved && DateTime.now().difference(_downTime).inMilliseconds < 600;
    final size = _lastCanvasSize;
    switch (_model.tool) {
      case CanvasTool.routers:
        if (isTap && _dragRouterId == null) {
          _model.addRouter(_clampFrac(_toFrac(_downLocal), size));
        } else if (isTap && _dragRouterId != null) {
          // toque simples sobre um roteador existente: nada a fazer (evita duplicar)
        }
      case CanvasTool.points:
        if (isTap) {
          final hit = _hitPoint(_downLocal);
          if (hit != null) {
            _showPointSheet(hit);
          } else {
            final p = _model.addPoint(_clampFrac(_toFrac(_downLocal), size));
            _showPointSheet(p, isNew: true);
          }
        }
      case CanvasTool.walls:
        final a = _draftA, b = _draftB;
        _draftA = _draftB = null;
        _draftTick.value++;
        if (isTap) {
          final idx = _hitUserWall(_downLocal);
          if (idx != null) _showWallSheet(idx);
        } else if (a != null && b != null && _model.lengthMeters(a, b) >= 0.3) {
          _model.addUserWall(a, b);
        }
      case CanvasTool.ruler:
        final a = _draftA, b = _draftB;
        if (a == null || b == null || isTap) {
          _draftA = _draftB = null;
          _draftTick.value++;
          return;
        }
        final lenPx = (_toPx(b, size) - _toPx(a, size)).distance;
        if (lenPx < 20) {
          _draftA = _draftB = null;
          _draftTick.value++;
          return;
        }
        await _askCalibration(a, b);
        _draftA = _draftB = null;
        _draftTick.value++;
    }
  }

  // ---------------------------------------------------------------------
  // Diálogos: calibração, paredes, pontos
  // ---------------------------------------------------------------------

  Future<void> _askCalibration(Offset a, Offset b) async {
    final current = _model.lengthMeters(a, b);
    final controller = TextEditingController();
    final result = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Calibrar escala'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Qual é a distância real entre as duas pontas da linha?\n'
              '(estimativa atual: ${current.toStringAsFixed(2)} m)',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Distância real', suffixText: 'm', border: OutlineInputBorder()),
              onSubmitted: (v) => Navigator.pop(ctx, double.tryParse(v.replaceAll(',', '.'))),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, double.tryParse(controller.text.replaceAll(',', '.'))),
            child: const Text('Calibrar'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null || result <= 0) return;
    _model.calibrate(a, b, result);
    if (mounted) {
      _snack('Escala calibrada: a planta tem ${_model.currentFloor.widthM.toStringAsFixed(2)} m de largura.');
    }
  }

  void _showWallSheet(int index) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final wall = _model.currentFloor.userWalls[index];
          final spec = wallMaterialSpec(wall.material ?? WallMaterial.drywall);
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Parede · ${_model.lengthMeters(wall.a, wall.b).toStringAsFixed(2)} m',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final m in kWallMaterials)
                        ChoiceChip(
                          avatar: CircleAvatar(backgroundColor: m.color, radius: 6),
                          label: Text('${m.shortLabel} −${m.defaultDb.toStringAsFixed(m.defaultDb % 1 == 0 ? 0 : 1)} dB'),
                          selected: m.material == spec.material,
                          onSelected: (_) {
                            _model.updateUserWall(index, m.material, m.defaultDb);
                            setSheet(() {});
                          },
                        ),
                    ],
                  ),
                  if (spec.adjustable) ...[
                    const SizedBox(height: 8),
                    Text('Perda: −${wall.attenuationDb.toStringAsFixed(1)} dB (${spec.minDb.round()} a ${spec.maxDb.round()})'),
                    Slider(
                      value: wall.attenuationDb.clamp(spec.minDb, spec.maxDb).toDouble(),
                      min: spec.minDb,
                      max: spec.maxDb,
                      divisions: ((spec.maxDb - spec.minDb) * 2).round(),
                      label: wall.attenuationDb.toStringAsFixed(1),
                      onChanged: (v) {
                        _model.updateUserWall(index, spec.material, v);
                        setSheet(() {});
                      },
                    ),
                  ],
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      TextButton.icon(
                        onPressed: () {
                          _model.removeUserWall(index);
                          Navigator.pop(ctx);
                        },
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Remover parede'),
                      ),
                      const Spacer(),
                      FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Pronto')),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showPointSheet(MeasurePoint p, {bool isNew = false}) {
    final nameController = TextEditingController(text: p.name);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final predicted = _model.fieldFor(p.floor).at(p.frac);
          final m = p.measured;
          return SafeArea(
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(isNew ? 'Novo ponto de medição' : 'Ponto de medição',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 10),
                  TextField(
                    controller: nameController,
                    decoration: const InputDecoration(labelText: 'Nome do ponto (ex.: Quarto 2)', border: OutlineInputBorder()),
                    onChanged: (v) => _model.renamePoint(p.id, v.trim().isEmpty ? p.name : v.trim()),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    predicted < -500
                        ? 'Previsão: adicione roteadores para calcular.'
                        : 'Previsão do simulador: ${predicted.toStringAsFixed(1)} dBm (${signalClassLabel(predicted)}) · ${rfBandSpec(_model.band).label}',
                  ),
                  const SizedBox(height: 6),
                  if (m == null)
                    const Text('Sem medição real neste ponto ainda.', style: TextStyle(fontSize: 13))
                  else
                    Text(
                      'Medido (${m.native ? 'real' : 'simulado'}): ${m.rssi} dBm · PHY ${m.linkMbps} Mbps · '
                      'gateway ${m.gwAvgMs == null ? '—' : '${m.gwAvgMs!.toStringAsFixed(1)} ms'} · '
                      'Internet ${m.netAvgMs == null ? '—' : '${m.netAvgMs!.toStringAsFixed(0)} ms'} · '
                      'perda ${m.netLossPct.toStringAsFixed(0)}%',
                      style: const TextStyle(fontSize: 13),
                    ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      FilledButton.icon(
                        onPressed: () async {
                          Navigator.pop(ctx);
                          await _measureAt(p);
                        },
                        icon: const Icon(Icons.speed),
                        label: const Text('Medir agora'),
                      ),
                      const SizedBox(width: 8),
                      TextButton.icon(
                        onPressed: () {
                          _model.removePoint(p.id);
                          Navigator.pop(ctx);
                        },
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Remover'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ).whenComplete(nameController.dispose);
  }

  Future<void> _measureAt(MeasurePoint p) async {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const BusyDialog('Medindo sinal, ping e perda de pacotes…'),
    );
    try {
      final m = await widget.diag.captureSnapshot();
      _model.recordMeasurement(m, point: p);
      if (mounted) {
        _snack('${p.name}: ${m.rssi} dBm · ping Internet ${m.netAvgMs?.toStringAsFixed(0) ?? '—'} ms'
            '${m.native ? '' : ' (dados simulados)'}');
      }
    } catch (e) {
      if (mounted) _snack('Falha na medição: $e');
    } finally {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }
  }

  // ---------------------------------------------------------------------
  // Seletores e planilhas (modelo de roteador, projetos, opacidade)
  // ---------------------------------------------------------------------

  Future<RouterModelType?> _pickModel() {
    return showModalBottomSheet<RouterModelType>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Escolha o modelo do roteador', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ),
            ),
            for (final spec in kRouterCatalog)
              ListTile(
                leading: SizedBox(width: 40, height: 40, child: CustomPaint(painter: RouterDevicePainter(spec.type))),
                title: Text(spec.name),
                subtitle: Text('Potência de transmissão: ${spec.txPowerDbm.toStringAsFixed(0)} dBm'),
                trailing: _model.selectedModel == spec.type ? Icon(Icons.check, color: Theme.of(ctx).colorScheme.primary) : null,
                onTap: () => Navigator.pop(ctx, spec.type),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _showProjectsSheet() async {
    var future = widget.store.list();
    final selected = await showModalBottomSheet<Object>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Projetos e plantas', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 12),
                Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  color: Theme.of(ctx).colorScheme.primaryContainer,
                  child: ListTile(
                    leading: const Icon(Icons.upload_file),
                    title: const Text('Carregar plantas do dispositivo'),
                    subtitle: const Text('Uma ou várias imagens (PNG, JPG, WEBP): cada uma vira um pavimento'),
                    onTap: () => Navigator.pop(ctx, _uploadSentinel),
                  ),
                ),
                Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: const Icon(Icons.file_open_outlined),
                    title: const Text('Importar projeto (.json)'),
                    subtitle: const Text('Reabre um projeto exportado pelo WaveLens'),
                    onTap: () => Navigator.pop(ctx, _importSentinel),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Text('Meus projetos (salvos neste aparelho)', style: TextStyle(fontWeight: FontWeight.w600)),
                    const Spacer(),
                    if (!widget.store.available) const Icon(Icons.cloud_off_outlined, size: 18),
                  ],
                ),
                const SizedBox(height: 6),
                FutureBuilder<List<WorkspaceSummary>>(
                  future: future,
                  builder: (ctx, snap) {
                    final list = snap.data ?? const <WorkspaceSummary>[];
                    if (snap.connectionState != ConnectionState.done) {
                      return const Padding(padding: EdgeInsets.all(12), child: LinearProgressIndicator());
                    }
                    if (list.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          widget.store.available
                              ? 'Nenhum projeto salvo ainda — o WaveLens salva automaticamente o que você faz.'
                              : 'O armazenamento local do navegador está indisponível: os projetos não serão salvos.',
                          style: const TextStyle(fontSize: 13),
                        ),
                      );
                    }
                    return Column(
                      children: [
                        for (final w in list)
                          Card(
                            margin: const EdgeInsets.only(bottom: 8),
                            child: ListTile(
                              leading: Icon(w.id == _model.workspaceId ? Icons.folder_open : Icons.folder_outlined),
                              title: Text(w.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(
                                '${w.floors} pav. · ${w.routers} roteador(es) · ${w.points} ponto(s) · ${_fmtDateTime(w.updatedAt)}',
                              ),
                              trailing: IconButton(
                                tooltip: 'Excluir projeto salvo',
                                icon: const Icon(Icons.delete_outline),
                                onPressed: w.id == _model.workspaceId
                                    ? null
                                    : () async {
                                        final ok = await confirmDialog(
                                          ctx,
                                          title: 'Excluir "${w.name}"?',
                                          message: 'O projeto será apagado deste aparelho. Isso não pode ser desfeito.',
                                          confirmLabel: 'Excluir',
                                        );
                                        if (ok) {
                                          await widget.store.delete(w.id);
                                          setSheet(() => future = widget.store.list());
                                        }
                                      },
                              ),
                              onTap: () => Navigator.pop(ctx, w),
                            ),
                          ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 12),
                const Text('Biblioteca de plantas', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                for (final project in kProjectLibrary)
                  Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      leading: Icon(project.floors.length > 1 ? Icons.apartment : Icons.house_outlined),
                      title: Text(project.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(project.subtitle),
                      onTap: () => Navigator.pop(ctx, project),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (selected == _uploadSentinel) {
      await _uploadProject();
    } else if (selected == _importSentinel) {
      await _importProject();
    } else if (selected is ProjectDef) {
      await widget.store.saveNow(_model);
      _model.setProject(selected);
      _resetZoom();
    } else if (selected is WorkspaceSummary) {
      await widget.store.saveNow(_model);
      try {
        await widget.store.open(selected.id, _model);
        _resetZoom();
      } catch (e) {
        if (mounted) _snack('Não foi possível abrir o projeto: $e');
      }
    }
  }

  /// Lê uma ou várias imagens como bytes na memória (Uint8List) — sem dart:io,
  /// para funcionar igual em Web/PWA, no WebView do Android e no desktop. Cada
  /// imagem vira um pavimento, na ordem em que foram selecionadas.
  Future<List<FloorDef>> _pickFloorsFromDevice({required int firstIndex}) async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp'],
    );
    final floors = <FloorDef>[];
    final stamp = DateTime.now().microsecondsSinceEpoch;
    for (var i = 0; i < files.length; i++) {
      final bytes = await files[i].readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final w = frame.image.width;
      final h = frame.image.height;
      frame.image.dispose();
      codec.dispose();
      floors.add(
        FloorDef(
          floorLabel(firstIndex + i),
          FloorPlanDef(
            id: 'custom_${stamp}_$i',
            name: files[i].name,
            subtitle: 'Planta personalizada · $w×$h px',
            memoryBytes: bytes,
            aspectRatio: w / h,
            defaultWidthM: 10,
          ),
        ),
      );
    }
    return floors;
  }

  Future<void> _uploadProject() async {
    try {
      final floors = await _pickFloorsFromDevice(firstIndex: 0);
      if (floors.isEmpty || !mounted) return;
      final project = ProjectDef(
        id: 'custom_${DateTime.now().microsecondsSinceEpoch}',
        name: floors.length == 1 ? floors.first.plan.name : 'Projeto personalizado',
        subtitle: '${floors.length} pavimento(s) · enviado do dispositivo',
        floors: floors,
        isCustom: true,
      );
      await widget.store.saveNow(_model);
      _model.setProject(project);
      _resetZoom();
      if (mounted) _snack('Planta carregada. Use a Régua para calibrar a escala e a ferramenta Parede para mapear as paredes.');
    } catch (e) {
      if (mounted) _snack('Não foi possível carregar a imagem: $e');
    }
  }

  Future<void> _addFloorsFromDevice() async {
    try {
      final floors = await _pickFloorsFromDevice(firstIndex: _model.floors.length);
      if (floors.isEmpty || !mounted) return;
      _model.addFloors(floors);
    } catch (e) {
      if (mounted) _snack('Não foi possível carregar a imagem: $e');
    }
  }

  Future<void> _exportProject() async {
    try {
      final json = const JsonEncoder.withIndent(' ').convert(_model.toJson(embedImages: true));
      final name = '${safeFileName(_model.workspaceName)}.netfloor.json';
      final where = await FileIO.deliver(name, 'application/json', Uint8List.fromList(utf8.encode(json)));
      if (mounted) _snack(where);
    } catch (e) {
      if (mounted) _snack('Não foi possível exportar: $e');
    }
  }

  Future<void> _importProject() async {
    try {
      final file = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['json']);
      if (file == null || !mounted) return;
      final text = utf8.decode(await file.readAsBytes());
      final j = jsonDecode(text);
      if (j is! Map<String, dynamic>) throw const FormatException('JSON inválido.');
      await widget.store.saveNow(_model);
      _model.applyJson(j, const {}, newId: true);
      _resetZoom();
      if (mounted) _snack('Projeto "${_model.workspaceName}" importado.');
    } catch (e) {
      if (mounted) _snack('Não foi possível importar: $e');
    }
  }

  void _showOpacitySheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final percent = (_model.heatOpacity * 100).round();
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Opacidade do mapa de calor', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Slider(
                          value: _model.heatOpacity,
                          min: 0.15,
                          max: 0.90,
                          divisions: 15,
                          label: '$percent%',
                          onChanged: (v) {
                            _model.setHeatOpacity(v);
                            setSheet(() {});
                          },
                        ),
                      ),
                      SizedBox(width: 48, child: Text('$percent%', textAlign: TextAlign.end)),
                    ],
                  ),
                  Text(
                    'Menos opacidade deixa a planta mais visível por baixo do sinal.',
                    style: TextStyle(fontSize: 12, color: _muted(ctx)),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _handleAddViaButton() async {
    final selected = await _pickModel();
    if (selected == null) return;
    final n = _model.routersOnFloor.length;
    final frac = _clampFrac(Offset(0.5 + 0.06 * (n % 5), 0.5 + 0.04 * (n % 3)), _lastCanvasSize);
    _model.setSelectedModel(selected);
    _model.addRouter(frac, model: selected);
  }

  Widget _buildFloorPlanBackground(FloorPlanDef plan) {
    Widget vectorFallback() => plan.rooms.isNotEmpty
        ? CustomPaint(painter: FloorPlanPainter(plan.rooms))
        : Container(
            color: Colors.grey.shade200,
            alignment: Alignment.center,
            child: const Icon(Icons.broken_image_outlined, size: 40, color: Colors.grey),
          );

    if (plan.memoryBytes != null) {
      return Image.memory(plan.memoryBytes!, fit: BoxFit.fill, gaplessPlayback: true);
    }
    Widget assetImage() => Image.asset(
          plan.assetPath!,
          fit: BoxFit.fill,
          errorBuilder: (context, error, stackTrace) => vectorFallback(),
        );
    if (plan.imageUrl != null) {
      return NetworkFloorPlanImage(
        url: plan.imageUrl!,
        fallback: plan.assetPath != null ? assetImage() : vectorFallback(),
      );
    }
    if (plan.assetPath != null) return assetImage();
    return vectorFallback();
  }

  // ---------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 12,
        title: AnimatedBuilder(
          animation: Listenable.merge([_model, widget.store.status]),
          builder: (context, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Row(
                mainAxisSize: MainAxisSize.min,
                children: [const Icon(Icons.wifi_tethering), const SizedBox(width: 8), Text(kAppName)],
              ),
              Text(
                '${_model.workspaceName}${widget.store.status.value.isEmpty ? '' : ' · ${widget.store.status.value}'}',
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w400),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        actions: [
          ValueListenableBuilder<ViewMode>(
            valueListenable: kViewMode,
            builder: (context, mode, _) => IconButton(
              icon: Icon(mode == ViewMode.presentation ? Icons.contrast : Icons.dark_mode_outlined),
              tooltip: mode == ViewMode.presentation
                  ? 'Mudar para Modo Diagnóstico (alto contraste)'
                  : 'Mudar para Modo Apresentação (escuro)',
              onPressed: () => setViewMode(mode == ViewMode.presentation ? ViewMode.diagnostic : ViewMode.presentation, widget.store),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.opacity),
            tooltip: 'Opacidade do mapa de calor',
            onPressed: _showOpacitySheet,
          ),
          IconButton(
            icon: const Icon(Icons.description_outlined),
            tooltip: 'Laudo de vistoria (PDF)',
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ReportPage(model: _model, diag: widget.diag, store: widget.store),
                ),
              );
            },
          ),
          PopupMenuButton<String>(
            tooltip: 'Mais opções',
            onSelected: (v) {
              switch (v) {
                case 'projects':
                  _showProjectsSheet();
                case 'export':
                  _exportProject();
                case 'import':
                  _importProject();
                case 'calib_reset':
                  _model.resetCalibration();
                case 'walls_clear':
                  _model.clearUserWalls();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'projects', child: ListTile(leading: Icon(Icons.layers_outlined), title: Text('Projetos e plantas'))),
              PopupMenuItem(value: 'export', child: ListTile(leading: Icon(Icons.file_download_outlined), title: Text('Exportar projeto (.json)'))),
              PopupMenuItem(value: 'import', child: ListTile(leading: Icon(Icons.file_open_outlined), title: Text('Importar projeto (.json)'))),
              PopupMenuItem(value: 'calib_reset', child: ListTile(leading: Icon(Icons.straighten), title: Text('Restaurar escala padrão'))),
              PopupMenuItem(value: 'walls_clear', child: ListTile(leading: Icon(Icons.layers_clear_outlined), title: Text('Apagar paredes desenhadas'))),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            AnimatedBuilder(animation: _model, builder: (context, _) => _buildFloorBar()),
            AnimatedBuilder(animation: _model, builder: (context, _) => _buildBandBar()),
            AnimatedBuilder(animation: _model, builder: (context, _) => _buildToolBar()),
            AnimatedBuilder(animation: _model, builder: (context, _) => _buildToolOptions()),
            Expanded(child: _buildCanvas()),
            AnimatedBuilder(animation: _model, builder: (context, _) => _buildActionBar()),
          ],
        ),
      ),
    );
  }

  Widget _buildCanvas() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 6),
      child: Center(
        child: AnimatedBuilder(
          animation: Listenable.merge([_model, _tc, _draftTick]),
          builder: (context, _) {
            final floor = _model.currentFloor;
            final plan = floor.plan;
            final zoom = _zoom;
            final mode = kViewMode.value;
            final tool = _model.tool;
            final draggingMarker = _dragRouterId != null || _dragPointId != null;
            final panAllowed = !draggingMarker && !_multi && (tool == CanvasTool.routers || tool == CanvasTool.points);
            final field = _model.fieldFor(_model.floorIndex);
            final scheme = Theme.of(context).colorScheme;
            final heatAlpha = mode == ViewMode.diagnostic ? min(0.95, _model.heatOpacity * 1.25) : _model.heatOpacity;

            Widget background = _buildFloorPlanBackground(plan);
            if (mode == ViewMode.presentation) {
              background = ColorFiltered(colorFilter: kDarkPlanFilter, child: background);
            } else if (mode == ViewMode.diagnostic) {
              background = ColorFiltered(colorFilter: kContrastPlanFilter, child: background);
            }

            return AspectRatio(
              aspectRatio: plan.aspectRatio,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  _lastCanvasSize = Size(constraints.maxWidth, constraints.maxHeight);
                  final size = _lastCanvasSize;
                  final mk = _markerRadius / zoom;
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest,
                        border: mode == ViewMode.diagnostic ? Border.all(color: Colors.black, width: 2) : null,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: InteractiveViewer(
                              transformationController: _tc,
                              minScale: 1.0,
                              maxScale: _maxZoom,
                              panEnabled: panAllowed,
                              scaleEnabled: true,
                              child: Listener(
                                behavior: HitTestBehavior.opaque,
                                onPointerDown: _onPointerDown,
                                onPointerMove: _onPointerMove,
                                onPointerUp: _onPointerUp,
                                onPointerCancel: _onPointerCancel,
                                child: SizedBox(
                                  width: size.width,
                                  height: size.height,
                                  child: Stack(
                                    children: [
                                      Positioned.fill(child: RepaintBoundary(child: background)),
                                      Positioned.fill(
                                        child: ImageFiltered(
                                          imageFilter: ui.ImageFilter.blur(sigmaX: 9, sigmaY: 9, tileMode: TileMode.decal),
                                          child: CustomPaint(painter: HeatmapPainter(field, heatAlpha)),
                                        ),
                                      ),
                                      Positioned.fill(
                                        child: IgnorePointer(
                                          child: CustomPaint(
                                            painter: ToolOverlayPainter(
                                              tool: tool,
                                              builtInWalls: plan.wallSegments,
                                              userWalls: floor.userWalls,
                                              draftA: _draftA,
                                              draftB: _draftB,
                                              draftColor: wallMaterialSpec(_model.wallMaterial).color,
                                              rulerLabel: (_draftA != null && _draftB != null)
                                                  ? '≈ ${_model.lengthMeters(_draftA!, _draftB!).toStringAsFixed(2)} m'
                                                  : null,
                                              zoom: zoom,
                                            ),
                                          ),
                                        ),
                                      ),
                                      Positioned.fill(
                                        child: IgnorePointer(
                                          child: AnimatedBuilder(
                                            animation: _pingController,
                                            builder: (context, _) => CustomPaint(
                                              painter: RadarPingPainter(_model.routersOnFloor, _pingController.value, 1 / zoom),
                                            ),
                                          ),
                                        ),
                                      ),
                                      for (final r in _model.routers.where((r) => r.floor != _model.floorIndex))
                                        _buildGhostMarker(r, size, mk),
                                      for (final p in _model.pointsOnFloor) _buildPointMarker(p, size, field, zoom),
                                      for (final r in _model.routersOnFloor) _buildRouterMarker(r, size, mk),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          // Sobreposições fixas (não acompanham o zoom)
                          Positioned(left: 8, top: 8, child: _buildScaleBadge()),
                          Positioned(left: 8, bottom: 8, child: _buildLegendPill(mode)),
                          Positioned(right: 8, bottom: 8, child: _buildZoomControls(zoom)),
                        ],
                      ),
                    ),
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _pill({required Widget child}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(color: Colors.black.withOpacity(0.72), borderRadius: BorderRadius.circular(20)),
      child: DefaultTextStyle(
        style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
        child: child,
      ),
    );
  }

  Widget _buildScaleBadge() {
    final f = _model.currentFloor;
    return _pill(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(f.calibrated ? Icons.check_circle : Icons.straighten, size: 13, color: f.calibrated ? kConnectedColor : Colors.amber),
          const SizedBox(width: 4),
          Text('${f.widthM.toStringAsFixed(1)} m${f.calibrated ? '' : ' (estimada)'}'),
        ],
      ),
    );
  }

  Widget _buildLegendPill(ViewMode mode) {
    Widget item(double t, String label) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 9, height: 9, decoration: BoxDecoration(color: _jetColor(t), shape: BoxShape.circle)),
            const SizedBox(width: 4),
            Text(label),
          ],
        );
    return _pill(
      child: Wrap(
        spacing: 9,
        children: [
          item(1.0, 'Forte ≥ ${kStrongDbm.round()}'),
          item(0.55, 'Interm.'),
          item(0.15, 'Ruim < ${kWeakDbm.round()} dBm'),
        ],
      ),
    );
  }

  Widget _buildZoomControls(double zoom) {
    Widget btn(IconData icon, String tip, VoidCallback onTap) => Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Material(
            color: Colors.black.withOpacity(0.72),
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: Tooltip(message: tip, child: SizedBox(width: 34, height: 34, child: Icon(icon, color: Colors.white, size: 18))),
            ),
          ),
        );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        btn(Icons.add, 'Aproximar', () => _zoomBy(1.6)),
        btn(Icons.remove, 'Afastar', () => _zoomBy(1 / 1.6)),
        if (zoom > 1.01) btn(Icons.fit_screen, 'Ajustar à tela', _resetZoom),
      ],
    );
  }

  /// Seletor de pavimento (térreo, 1º andar...) + botão para adicionar mais.
  Widget _buildFloorBar() {
    return SizedBox(
      height: 42,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (var i = 0; i < _model.floors.length; i++)
            Padding(
              padding: const EdgeInsets.only(right: 6, top: 3, bottom: 3),
              child: ChoiceChip(
                visualDensity: VisualDensity.compact,
                label: Text(() {
                  final n = _model.routers.where((r) => r.floor == i).length;
                  return n == 0 ? _model.floors[i].label : '${_model.floors[i].label} · $n';
                }()),
                selected: i == _model.floorIndex,
                onSelected: (_) => _model.setFloor(i),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: ActionChip(
              visualDensity: VisualDensity.compact,
              avatar: const Icon(Icons.add, size: 18),
              label: const Text('Pavimento'),
              tooltip: 'Adicionar pavimento(s) a partir de imagens do dispositivo',
              onPressed: _addFloorsFromDevice,
            ),
          ),
        ],
      ),
    );
  }

  /// Alternador rápido de banda: 2.4 ↔ 5 ↔ 6 GHz.
  Widget _buildBandBar() {
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          const Padding(
            padding: EdgeInsets.only(right: 8),
            child: Center(child: Icon(Icons.wifi, size: 18)),
          ),
          for (final b in kRfBands)
            Padding(
              padding: const EdgeInsets.only(right: 6, top: 3, bottom: 3),
              child: ChoiceChip(
                visualDensity: VisualDensity.compact,
                label: Text(b.label),
                selected: _model.band == b.band,
                onSelected: (_) => _model.setBand(b.band),
              ),
            ),
          Center(
            child: Text(
              _model.band == RfBand.ghz24 ? 'maior alcance' : 'menor alcance · paredes ×${rfBandSpec(_model.band).wallFactor}',
              style: TextStyle(fontSize: 11, color: _muted(context)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolBar() {
    Widget chip(CanvasTool t, IconData icon, String label) => Padding(
          padding: const EdgeInsets.only(right: 6, top: 3, bottom: 3),
          child: ChoiceChip(
            visualDensity: VisualDensity.compact,
            avatar: Icon(icon, size: 17),
            label: Text(label),
            selected: _model.tool == t,
            onSelected: (_) {
              _cancelGesture();
              _model.setTool(t);
            },
          ),
        );
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          chip(CanvasTool.routers, Icons.router_outlined, 'Roteador'),
          chip(CanvasTool.walls, Icons.border_style, 'Parede'),
          chip(CanvasTool.ruler, Icons.straighten, 'Régua'),
          chip(CanvasTool.points, Icons.location_on_outlined, 'Ponto'),
        ],
      ),
    );
  }

  /// Linha de opções da ferramenta ativa (materiais de parede, dicas).
  Widget _buildToolOptions() {
    final muted = TextStyle(fontSize: 12, color: _muted(context));
    switch (_model.tool) {
      case CanvasTool.walls:
        final spec = wallMaterialSpec(_model.wallMaterial);
        return Column(
          children: [
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final m in kWallMaterials)
                    Padding(
                      padding: const EdgeInsets.only(right: 6, top: 3, bottom: 3),
                      child: ChoiceChip(
                        visualDensity: VisualDensity.compact,
                        avatar: CircleAvatar(backgroundColor: m.color, radius: 6),
                        label: Text(
                          m.adjustable
                              ? '${m.shortLabel} −${m.minDb.round()} a −${m.maxDb.round()} dB'
                              : '${m.shortLabel} −${m.defaultDb.round()} dB',
                        ),
                        selected: m.material == _model.wallMaterial,
                        onSelected: (_) => _model.setWallMaterial(m.material),
                      ),
                    ),
                ],
              ),
            ),
            if (spec.adjustable)
              SizedBox(
                height: 34,
                child: Row(
                  children: [
                    const SizedBox(width: 16),
                    Text('Perda: −${_model.concreteDb.toStringAsFixed(1)} dB', style: muted),
                    Expanded(
                      child: Slider(
                        value: _model.concreteDb.clamp(spec.minDb, spec.maxDb).toDouble(),
                        min: spec.minDb,
                        max: spec.maxDb,
                        divisions: ((spec.maxDb - spec.minDb) * 2).round(),
                        onChanged: _model.setConcreteDb,
                      ),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 2),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Arraste no mapa para traçar · toque numa parede para editar/remover · 2 dedos: zoom/mover', style: muted),
              ),
            ),
          ],
        );
      case CanvasTool.ruler:
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
          child: Text(
            'Arraste sobre uma parede (ou medida conhecida) e informe a distância real em metros. '
            'A escala do mapa de calor é ajustada.',
            style: muted,
          ),
        );
      case CanvasTool.points:
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
          child: Text('Toque no mapa para marcar um ponto de medição · toque num ponto para medir/renomear · arraste para mover.', style: muted),
        );
      case CanvasTool.routers:
        return const SizedBox.shrink();
    }
  }

  Widget _buildRouterMarker(RouterNode router, Size bounds, double mk) {
    final p = _toPx(router.frac, bounds);
    return Positioned(
      left: p.dx - mk,
      top: p.dy - mk,
      child: IgnorePointer(
        child: SizedBox(width: mk * 2, height: mk * 2, child: CustomPaint(painter: RouterDevicePainter(router.model))),
      ),
    );
  }

  /// Roteador instalado em outro pavimento: aparece esmaecido, sem interação.
  Widget _buildGhostMarker(RouterNode router, Size bounds, double mk) {
    final p = _toPx(router.frac, bounds);
    return Positioned(
      left: p.dx - mk,
      top: p.dy - mk,
      child: IgnorePointer(
        child: Opacity(
          opacity: 0.55,
          child: SizedBox(width: mk * 2, height: mk * 2, child: CustomPaint(painter: RouterDevicePainter(router.model))),
        ),
      ),
    );
  }

  Widget _buildPointMarker(MeasurePoint point, Size bounds, SignalField field, double zoom) {
    final p = _toPx(point.frac, bounds);
    final predicted = field.at(point.frac);
    final r = 9 / zoom;
    return Positioned(
      left: p.dx - r,
      top: p.dy - r,
      child: IgnorePointer(
        child: SizedBox(
          width: r * 2,
          height: r * 2,
          child: CustomPaint(
            painter: PointMarkerPainter(
              label: predicted < -500 ? point.name : '${point.name} · ${predicted.round()} dBm',
              color: predicted < -500 ? Colors.blueGrey : _signalClassColor(predicted),
              measured: point.measured != null,
              zoom: zoom,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildActionBar() {
    final spec = _specFor(_model.selectedModel);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () async {
                final selected = await _pickModel();
                if (selected != null) _model.setSelectedModel(selected);
              },
              icon: SizedBox(width: 20, height: 20, child: CustomPaint(painter: RouterDevicePainter(spec.type))),
              label: Text('${spec.shortName} (${spec.txPowerDbm.toStringAsFixed(0)} dBm)', overflow: TextOverflow.ellipsis),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: _handleAddViaButton,
            icon: const Icon(Icons.add),
            label: const Text('Roteador'),
          ),
          const SizedBox(width: 4),
          IconButton.outlined(
            onPressed: _model.clear,
            tooltip: 'Limpar roteadores',
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
    );
  }
}

Color _signalClassColor(double dbm) {
  if (dbm >= kStrongDbm) return const Color(0xFF16A34A);
  if (dbm >= kWeakDbm) return const Color(0xFFD97706);
  return const Color(0xFFDC2626);
}

/// Cor de texto secundário que funciona nos dois temas.
Color _muted(BuildContext context) => Theme.of(context).colorScheme.onSurfaceVariant;

String _fmtDate(DateTime t) => '${_two(t.day)}/${_two(t.month)}/${t.year}';
String _fmtDateTime(DateTime t) => '${_fmtDate(t)} ${_two(t.hour)}:${_two(t.minute)}';

/// Marcador de ponto de medição: bolinha colorida pela previsão + rótulo.
class PointMarkerPainter extends CustomPainter {
  final String label;
  final Color color;
  final bool measured;
  final double zoom;
  const PointMarkerPainter({required this.label, required this.color, required this.measured, required this.zoom});

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    canvas.drawCircle(c, r + 1.5 / zoom, Paint()..color = Colors.white);
    canvas.drawCircle(c, r, Paint()..color = color);
    if (measured) {
      canvas.drawCircle(
        c,
        r * 0.42,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.fill,
      );
    }
    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: Colors.white,
          fontSize: 11 / zoom,
          fontWeight: FontWeight.w700,
          backgroundColor: Colors.black.withOpacity(0.72),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(c.dx - tp.width / 2, c.dy - r - tp.height - 3 / zoom));
  }

  @override
  bool shouldRepaint(covariant PointMarkerPainter old) => true;
}


// ===========================================================================
// PARTE 2 — NETFLOOR DIAGNOSTIC (varredura de espectro, sinal e latência)
// ===========================================================================

// ---------------------------------------------------------------------------
// Ponte nativa (Android): disponível apenas dentro do WaveLens Shell, que
// expõe `window.NetFloorNative.postMessage(json)` e responde chamando
// `window.__netfloorNativeResponse(json)`.
// ---------------------------------------------------------------------------

@JS('NetFloorNative')
external JSObject? get _netFloorNative;

class NativeBridge {
  static bool get available => _netFloorNative != null;

  static int _nextId = 1;
  static final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  static bool _listening = false;

  static void _listen() {
    if (_listening) return;
    _listening = true;
    globalContext.setProperty(
      '__netfloorNativeResponse'.toJS,
      ((JSString raw) {
        try {
          final msg = jsonDecode(raw.toDart) as Map<String, dynamic>;
          _pending.remove(msg['id'])?.complete(msg);
        } catch (_) {}
      }).toJS,
    );
  }

  /// Chama um método nativo e devolve o campo `data` da resposta.
  static Future<Map<String, dynamic>> call(
    String method, {
    Map<String, dynamic>? args,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final channel = _netFloorNative;
    if (channel == null) throw StateError('Ponte nativa indisponível');
    _listen();
    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    channel.callMethod<JSAny?>('postMessage'.toJS, jsonEncode({'id': id, 'method': method, 'args': args ?? {}}).toJS);
    final msg = await completer.future.timeout(timeout, onTimeout: () {
      _pending.remove(id);
      throw TimeoutException('Sem resposta do app Android ($method)');
    });
    if (msg['ok'] != true) throw StateError('${msg['error'] ?? 'erro desconhecido'}');
    final data = msg['data'];
    return data is Map ? data.cast<String, dynamic>() : <String, dynamic>{};
  }
}

// ---------------------------------------------------------------------------
// Modelos de dados do diagnóstico
// ---------------------------------------------------------------------------

enum WifiBand { ghz24, ghz5 }

const List<int> kChannels5Ghz = [
  36, 40, 44, 48, 52, 56, 60, 64, //
  100, 104, 108, 112, 116, 120, 124, 128, 132, 136, 140, 144,
  149, 153, 157, 161, 165,
];

int channelToMhz(WifiBand band, int channel) {
  if (band == WifiBand.ghz24) return channel == 14 ? 2484 : 2407 + 5 * channel;
  return 5000 + 5 * channel;
}

class WifiNetwork {
  final String ssid;
  final String bssid;
  final int frequency; // MHz do canal primário
  final int centerFreq; // MHz do centro do bloco (20/40/80/160 MHz)
  final int widthMhz;
  final int level; // dBm
  final bool connected;
  const WifiNetwork({
    required this.ssid,
    required this.bssid,
    required this.frequency,
    required this.centerFreq,
    required this.widthMhz,
    required this.level,
    this.connected = false,
  });

  factory WifiNetwork.fromJson(Map<String, dynamic> j) {
    final freq = (j['frequency'] as num?)?.toInt() ?? 0;
    final center = (j['centerFreq'] as num?)?.toInt() ?? 0;
    return WifiNetwork(
      ssid: (j['ssid'] as String?) ?? '',
      bssid: (j['bssid'] as String?) ?? '',
      frequency: freq,
      centerFreq: center > 0 ? center : freq,
      widthMhz: (j['widthMhz'] as num?)?.toInt() ?? 20,
      level: (j['level'] as num?)?.toInt() ?? -100,
      connected: j['connected'] == true,
    );
  }

  WifiBand? get band {
    if (frequency >= 2400 && frequency < 2500) return WifiBand.ghz24;
    if (frequency >= 5150 && frequency < 5900) return WifiBand.ghz5;
    return null;
  }

  int get channel => band == WifiBand.ghz24 ? (frequency == 2484 ? 14 : (frequency - 2407) ~/ 5) : (frequency - 5000) ~/ 5;
  double get lowMhz => centerFreq - widthMhz / 2;
  double get highMhz => centerFreq + widthMhz / 2;
  String get displayName => ssid.isEmpty ? '(rede oculta)' : ssid;
}

class LinkInfo {
  final bool connected;
  final String ssid;
  final String bssid;
  final int rssi;
  final int frequency;
  final int linkSpeedMbps;
  final String gateway;
  const LinkInfo({
    required this.connected,
    this.ssid = '',
    this.bssid = '',
    this.rssi = -100,
    this.frequency = 0,
    this.linkSpeedMbps = 0,
    this.gateway = '',
  });

  factory LinkInfo.fromJson(Map<String, dynamic> j) {
    return LinkInfo(
      connected: j['connected'] == true,
      ssid: (j['ssid'] as String?) ?? '',
      bssid: (j['bssid'] as String?) ?? '',
      rssi: (j['rssi'] as num?)?.toInt() ?? -100,
      frequency: (j['frequency'] as num?)?.toInt() ?? 0,
      linkSpeedMbps: (j['linkSpeed'] as num?)?.toInt() ?? 0,
      gateway: (j['gateway'] as String?) ?? '',
    );
  }

  int get channel => frequency >= 5925
      ? (frequency - 5950) ~/ 5
      : frequency >= 5000
          ? (frequency - 5000) ~/ 5
          : (frequency == 2484 ? 14 : (frequency - 2407) ~/ 5);
  String get bandLabel => frequency >= 5925 ? '6 GHz' : (frequency >= 5000 ? '5 GHz' : '2.4 GHz');
}

class DiagPermissions {
  final bool granted;
  final bool locationServicesEnabled;
  const DiagPermissions({required this.granted, required this.locationServicesEnabled});
}

// ---------------------------------------------------------------------------
// Fontes de dados: nativa (via ponte do Shell Android) ou simulada.
// ---------------------------------------------------------------------------

abstract class DiagnosticsSource {
  bool get isNative;
  Future<DiagPermissions> ensurePermissions();
  Future<List<WifiNetwork>> scan();
  Future<LinkInfo?> linkInfo();

  /// Latência em ms, ou null se o pacote foi perdido.
  Future<double?> ping(String host);
}

const String kDnsHost = '8.8.8.8';

class NativeBridgeDiagnostics implements DiagnosticsSource {
  @override
  bool get isNative => true;

  @override
  Future<DiagPermissions> ensurePermissions() async {
    final d = await NativeBridge.call('permissions', timeout: const Duration(seconds: 90));
    final granted = d['location'] == true || d['nearby'] == true;
    return DiagPermissions(granted: granted, locationServicesEnabled: d['locationServices'] != false);
  }

  @override
  Future<List<WifiNetwork>> scan() async {
    final d = await NativeBridge.call('scan', timeout: const Duration(seconds: 20));
    final list = (d['networks'] as List?) ?? const [];
    final nets = list
        .map((e) => WifiNetwork.fromJson((e as Map).cast<String, dynamic>()))
        .where((n) => n.band != null)
        .toList();
    final error = d['error'];
    if (nets.isEmpty && error != null) throw StateError('$error');
    return nets;
  }

  @override
  Future<LinkInfo?> linkInfo() async {
    final d = await NativeBridge.call('linkInfo');
    return LinkInfo.fromJson(d);
  }

  @override
  Future<double?> ping(String host) async {
    final d = await NativeBridge.call('ping', args: {'host': host}, timeout: const Duration(seconds: 8));
    final ms = d['ms'];
    return ms is num ? ms.toDouble() : null;
  }
}

class SimulatedDiagnostics implements DiagnosticsSource {
  final Random _rng = Random();
  double _rssi = -55;
  double _rssiTarget = -55;

  static const List<WifiNetwork> _base = [
    WifiNetwork(ssid: 'MinhaRede', bssid: 'AA:BB:CC:00:11:22', frequency: 5220, centerFreq: 5210, widthMhz: 80, level: -52, connected: true),
    WifiNetwork(ssid: 'MinhaRede', bssid: 'AA:BB:CC:00:11:23', frequency: 2437, centerFreq: 2437, widthMhz: 20, level: -50),
    WifiNetwork(ssid: 'VIVO-1A2B', bssid: '10:20:30:40:50:01', frequency: 2412, centerFreq: 2412, widthMhz: 20, level: -63),
    WifiNetwork(ssid: 'Claro_WiFi_45', bssid: '10:20:30:40:50:02', frequency: 2437, centerFreq: 2437, widthMhz: 20, level: -72),
    WifiNetwork(ssid: 'NET_9F3C', bssid: '10:20:30:40:50:03', frequency: 2462, centerFreq: 2462, widthMhz: 20, level: -58),
    WifiNetwork(ssid: 'TP-LINK_7788', bssid: '10:20:30:40:50:04', frequency: 2462, centerFreq: 2462, widthMhz: 20, level: -80),
    WifiNetwork(ssid: 'Vizinho_Casa', bssid: '10:20:30:40:50:05', frequency: 2422, centerFreq: 2432, widthMhz: 40, level: -76),
    WifiNetwork(ssid: 'Oi_Fibra_22', bssid: '10:20:30:40:50:06', frequency: 2452, centerFreq: 2452, widthMhz: 20, level: -84),
    WifiNetwork(ssid: 'VIVO-1A2B-5G', bssid: '10:20:30:40:50:11', frequency: 5180, centerFreq: 5180, widthMhz: 20, level: -70),
    WifiNetwork(ssid: 'NET_9F3C_5G', bssid: '10:20:30:40:50:12', frequency: 5745, centerFreq: 5775, widthMhz: 80, level: -66),
    WifiNetwork(ssid: 'Claro_5G_45', bssid: '10:20:30:40:50:13', frequency: 5500, centerFreq: 5510, widthMhz: 40, level: -78),
    WifiNetwork(ssid: 'Apto_302', bssid: '10:20:30:40:50:14', frequency: 5785, centerFreq: 5785, widthMhz: 20, level: -74),
    WifiNetwork(ssid: 'Escritorio_5G', bssid: '10:20:30:40:50:15', frequency: 5260, centerFreq: 5270, widthMhz: 40, level: -68),
  ];

  @override
  bool get isNative => false;

  @override
  Future<DiagPermissions> ensurePermissions() async =>
      const DiagPermissions(granted: true, locationServicesEnabled: true);

  @override
  Future<List<WifiNetwork>> scan() async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    return [
      for (final n in _base)
        WifiNetwork(
          ssid: n.ssid,
          bssid: n.bssid,
          frequency: n.frequency,
          centerFreq: n.centerFreq,
          widthMhz: n.widthMhz,
          level: n.level + _rng.nextInt(7) - 3,
          connected: n.connected,
        ),
    ];
  }

  @override
  Future<LinkInfo?> linkInfo() async {
    if (_rng.nextDouble() < 0.12) _rssiTarget = -45.0 - _rng.nextInt(38);
    _rssi += (_rssiTarget - _rssi) * 0.25 + (_rng.nextDouble() * 2 - 1);
    _rssi = _rssi.clamp(-92.0, -38.0).toDouble();
    final speed = _rssi > -55
        ? 866
        : _rssi > -65
            ? 650
            : _rssi > -75
                ? 433
                : 150;
    return LinkInfo(
      connected: true,
      ssid: 'MinhaRede',
      bssid: 'AA:BB:CC:00:11:22',
      rssi: _rssi.round(),
      frequency: 5220,
      linkSpeedMbps: speed,
      gateway: '192.168.0.1',
    );
  }

  @override
  Future<double?> ping(String host) async {
    await Future<void>.delayed(Duration(milliseconds: 40 + _rng.nextInt(80)));
    if (_rng.nextDouble() < 0.03) return null;
    if (host == kDnsHost) {
      final spike = _rng.nextDouble() < 0.06 ? 40.0 + _rng.nextInt(60) : 0.0;
      return 14 + _rng.nextDouble() * 18 + spike;
    }
    return 1.5 + _rng.nextDouble() * 4.5;
  }
}

// ---------------------------------------------------------------------------
// Saúde do canal: interferência estimada por canal de 20 MHz, considerando
// apenas as redes vizinhas (a rede conectada não conta como interferência).
// ---------------------------------------------------------------------------

enum ChannelRating { excelente, bom, ruim }

extension ChannelRatingUi on ChannelRating {
  String get label => switch (this) {
        ChannelRating.excelente => 'Excelente',
        ChannelRating.bom => 'Bom',
        ChannelRating.ruim => 'Ruim',
      };

  Color get color => switch (this) {
        ChannelRating.excelente => const Color(0xFF16A34A),
        ChannelRating.bom => const Color(0xFFD97706),
        ChannelRating.ruim => const Color(0xFFDC2626),
      };
}

class ChannelHealth {
  final int channel;
  final int freq;
  final int overlapping;
  final double score;
  final ChannelRating rating;
  const ChannelHealth({
    required this.channel,
    required this.freq,
    required this.overlapping,
    required this.score,
    required this.rating,
  });
}

List<ChannelHealth> computeChannelHealth(WifiBand band, List<WifiNetwork> all, {String connectedSsid = ''}) {
  final channels = band == WifiBand.ghz24 ? [for (var c = 1; c <= 13; c++) c] : kChannels5Ghz;
  final neighbors = all
      .where((n) => n.band == band && !n.connected && !(connectedSsid.isNotEmpty && n.ssid == connectedSsid))
      .toList();
  final out = <ChannelHealth>[];
  for (final ch in channels) {
    final fc = channelToMhz(band, ch);
    final lo = fc - 10.0;
    final hi = fc + 10.0;
    var score = 0.0;
    var count = 0;
    for (final n in neighbors) {
      final overlap = (min(hi, n.highMhz) - max(lo, n.lowMhz)) / 20.0;
      if (overlap <= 0) continue;
      count++;
      final strength = ((n.level + 95) / 55).clamp(0.0, 1.0).toDouble();
      score += overlap.clamp(0.0, 1.0).toDouble() * strength;
    }
    final rating = score < 0.25
        ? ChannelRating.excelente
        : score < 1.0
            ? ChannelRating.bom
            : ChannelRating.ruim;
    out.add(ChannelHealth(channel: ch, freq: fc, overlapping: count, score: score, rating: rating));
  }
  return out;
}

// ---------------------------------------------------------------------------
// Controlador do diagnóstico: mantém os dados e só roda os temporizadores da
// aba visível (varredura a cada 30 s, sinal e ping a cada 1 s).
// ---------------------------------------------------------------------------

const int kMaxSamples = 60;

class DiagnosticsController extends ChangeNotifier {
  DiagnosticsSource _source = SimulatedDiagnostics();
  DiagnosticsSource get source => _source;
  bool get isNative => _source.isNative;

  bool _active = false;
  int _tab = 0;
  bool _disposed = false;

  DiagPermissions? permissions;
  bool _permissionsAsked = false;

  WifiBand band = WifiBand.ghz24;
  List<WifiNetwork> networks = const [];
  DateTime? lastScan;
  bool scanning = false;
  String? scanError;

  LinkInfo? link;
  final List<double> rssiSamples = [];
  bool walkRunning = true;
  String? signalError;

  final List<double?> gwSamples = [];
  final List<double?> dnsSamples = [];
  int gwSent = 0, gwLost = 0, dnsSent = 0, dnsLost = 0;
  bool pingRunning = true;
  String gatewayIp = '192.168.0.1';
  String? pingError;

  Timer? _scanTimer;
  Timer? _signalTimer;
  Timer? _pingTimer;
  bool _signalBusy = false;
  bool _pingBusy = false;
  int _pingTick = 0;

  /// Nome da rede em que o aparelho está conectado (vem da varredura; se o
  /// Android ocultar o BSSID, cai para o nome lido da conexão atual).
  String get connectedSsid {
    for (final n in networks) {
      if (n.connected && n.ssid.isNotEmpty) return n.ssid;
    }
    final s = link?.ssid ?? '';
    return s.startsWith('<') ? '' : s;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _scanTimer?.cancel();
    _signalTimer?.cancel();
    _pingTimer?.cancel();
    super.dispose();
  }

  void setActive(bool value) {
    _active = value;
    _sync();
  }

  void setTab(int index) {
    _tab = index;
    _sync();
  }

  void setBand(WifiBand value) {
    band = value;
    _notify();
  }

  void _refreshSource() {
    if (_source.isNative || !NativeBridge.available) return;
    _source = NativeBridgeDiagnostics();
    permissions = null;
    _permissionsAsked = false;
    networks = const [];
    lastScan = null;
    link = null;
    rssiSamples.clear();
    gwSamples.clear();
    dnsSamples.clear();
    gwSent = gwLost = dnsSent = dnsLost = 0;
    gatewayIp = '';
  }

  void _sync() {
    _refreshSource();
    _scanTimer?.cancel();
    _signalTimer?.cancel();
    _pingTimer?.cancel();
    _scanTimer = _signalTimer = _pingTimer = null;
    if (!_active) return;

    if (_tab == 0) {
      unawaited(scanNow());
      _scanTimer = Timer.periodic(const Duration(seconds: 30), (_) => scanNow());
    } else if (_tab == 1 && walkRunning) {
      unawaited(_pollSignal());
      _signalTimer = Timer.periodic(const Duration(seconds: 1), (_) => _pollSignal());
    } else if (_tab == 2 && pingRunning) {
      unawaited(_pollPing());
      _pingTimer = Timer.periodic(const Duration(seconds: 1), (_) => _pollPing());
    }
  }

  Future<bool> _ensurePermissions() async {
    if (!_permissionsAsked) {
      _permissionsAsked = true;
      try {
        permissions = await _source.ensurePermissions();
      } catch (e) {
        permissions = const DiagPermissions(granted: false, locationServicesEnabled: true);
        scanError = 'Não foi possível pedir permissões: $e';
      }
      _notify();
    }
    return permissions?.granted ?? true;
  }

  Future<void> requestPermissions() async {
    _permissionsAsked = false;
    await _ensurePermissions();
    _sync();
  }

  Future<void> scanNow() async {
    if (scanning) return;
    scanning = true;
    scanError = null;
    _notify();
    try {
      if (await _ensurePermissions()) {
        networks = await _source.scan();
        lastScan = DateTime.now();
      } else {
        scanError = 'Permissão de localização necessária para varrer redes Wi-Fi.';
      }
    } catch (e) {
      scanError = 'Falha na varredura: $e';
    }
    scanning = false;
    _notify();
  }

  void _push<T>(List<T> list, T value) {
    list.add(value);
    if (list.length > kMaxSamples) list.removeAt(0);
  }

  Future<void> _pollSignal() async {
    if (_signalBusy) return;
    _signalBusy = true;
    try {
      if (!await _ensurePermissions()) {
        signalError = 'Permissão de localização necessária para ler o sinal.';
        return;
      }
      final info = await _source.linkInfo();
      if (info != null && info.connected) {
        link = info;
        if (info.gateway.isNotEmpty) gatewayIp = info.gateway;
        _push(rssiSamples, info.rssi.toDouble());
        signalError = null;
      } else {
        signalError = 'Sem conexão Wi-Fi ativa.';
      }
    } catch (e) {
      signalError = 'Falha ao ler o sinal: $e';
    } finally {
      _signalBusy = false;
      _notify();
    }
  }

  Future<void> _pollPing() async {
    if (_pingBusy) return;
    _pingBusy = true;
    try {
      if (link == null || _pingTick % 5 == 0) {
        final info = await _source.linkInfo();
        if (info != null && info.connected) {
          link = info;
          if (info.gateway.isNotEmpty) gatewayIp = info.gateway;
        }
      }
      _pingTick++;
      final hasGateway = gatewayIp.isNotEmpty;
      final results = await Future.wait<double?>([
        hasGateway ? _source.ping(gatewayIp) : Future<double?>.value(null),
        _source.ping(kDnsHost),
      ]);
      if (hasGateway) {
        gwSent++;
        if (results[0] == null) gwLost++;
        _push<double?>(gwSamples, results[0]);
      }
      dnsSent++;
      if (results[1] == null) dnsLost++;
      _push<double?>(dnsSamples, results[1]);
      pingError = null;
    } catch (e) {
      pingError = 'Falha no teste de ping: $e';
    } finally {
      _pingBusy = false;
      _notify();
    }
  }

  /// Medição instantânea de campo: lê RSSI/PHY e dispara [samples] pares de
  /// ping (gateway + Internet), devolvendo médias e perda de pacotes. Marca a
  /// origem (real ou simulada) para o laudo não confundir os dois.
  Future<Measurement> captureSnapshot({int samples = 5}) async {
    _refreshSource();
    if (!await _ensurePermissions()) {
      throw StateError('Permissão de localização necessária para ler o sinal.');
    }
    final info = await _source.linkInfo();
    if (info == null || !info.connected) throw StateError('Sem conexão Wi-Fi ativa.');
    final gw = info.gateway.isNotEmpty ? info.gateway : gatewayIp;
    final gwMs = <double>[];
    final netMs = <double>[];
    var gwSent = 0, netSent = 0;
    for (var i = 0; i < samples; i++) {
      final results = await Future.wait<double?>([
        gw.isNotEmpty ? _source.ping(gw) : Future<double?>.value(null),
        _source.ping(kDnsHost),
      ]);
      if (gw.isNotEmpty) {
        gwSent++;
        if (results[0] != null) gwMs.add(results[0]!);
      }
      netSent++;
      if (results[1] != null) netMs.add(results[1]!);
    }
    double? avg(List<double> l) => l.isEmpty ? null : l.reduce((a, b) => a + b) / l.length;
    double loss(int sent, int ok) => sent == 0 ? 0 : (sent - ok) * 100 / sent;
    return Measurement(
      time: DateTime.now(),
      native: _source.isNative,
      ssid: info.ssid.startsWith('<') ? '' : info.ssid,
      bssid: info.bssid,
      bandLabel: info.bandLabel,
      channel: info.channel,
      rssi: info.rssi,
      linkMbps: info.linkSpeedMbps,
      gateway: gw,
      gwAvgMs: avg(gwMs),
      gwLossPct: loss(gwSent, gwMs.length),
      gwSent: gwSent,
      netAvgMs: avg(netMs),
      netLossPct: loss(netSent, netMs.length),
      netSent: netSent,
    );
  }

  void toggleWalk() {
    walkRunning = !walkRunning;
    _sync();
    _notify();
  }

  void resetSignal() {
    rssiSamples.clear();
    _notify();
  }

  void togglePing() {
    pingRunning = !pingRunning;
    _sync();
    _notify();
  }

  void resetPing() {
    gwSamples.clear();
    dnsSamples.clear();
    gwSent = gwLost = dnsSent = dnsLost = 0;
    _notify();
  }
}

// ---------------------------------------------------------------------------
// Tela do diagnóstico (3 abas)
// ---------------------------------------------------------------------------

class DiagnosticPage extends StatefulWidget {
  final DiagnosticsController controller;
  final bool active;
  final NetworkModel model; // recebe as medições registradas (histórico e pontos do laudo)
  const DiagnosticPage({super.key, required this.controller, required this.active, required this.model});

  @override
  State<DiagnosticPage> createState() => _DiagnosticPageState();
}

class _DiagnosticPageState extends State<DiagnosticPage> with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this)..addListener(_onTabChanged);
    Future.microtask(() => widget.controller.setActive(widget.active));
  }

  void _onTabChanged() {
    if (!_tabs.indexIsChanging) widget.controller.setTab(_tabs.index);
  }

  @override
  void didUpdateWidget(covariant DiagnosticPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) {
      Future.microtask(() => widget.controller.setActive(widget.active));
    }
  }

  @override
  void dispose() {
    _tabs.removeListener(_onTabChanged);
    _tabs.dispose();
    super.dispose();
  }

  /// Registra uma medição de campo no histórico do projeto, opcionalmente
  /// vinculada a um ponto de medição marcado no simulador.
  Future<void> _recordMeasurement() async {
    final points = widget.model.points;
    MeasurePoint? target;
    if (points.isNotEmpty) {
      final choice = await showModalBottomSheet<Object>(
        context: context,
        builder: (ctx) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Text('Vincular a qual ponto?', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ),
              ListTile(
                leading: const Icon(Icons.speed),
                title: const Text('Apenas registrar (sem ponto)'),
                onTap: () => Navigator.pop(ctx, 'none'),
              ),
              for (final p in points)
                ListTile(
                  leading: const Icon(Icons.location_on_outlined),
                  title: Text(p.name),
                  subtitle: Text('${widget.model.floors[p.floor].label}${p.measured == null ? '' : ' · já medido'}'),
                  onTap: () => Navigator.pop(ctx, p),
                ),
            ],
          ),
        ),
      );
      if (choice == null) return;
      if (choice is MeasurePoint) target = choice;
    }
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const BusyDialog('Medindo sinal, ping e perda de pacotes…'),
    );
    String message;
    try {
      final m = await widget.controller.captureSnapshot();
      widget.model.recordMeasurement(m, point: target);
      message = 'Medição registrada${target == null ? '' : ' em ${target.name}'}: ${m.rssi} dBm'
          '${m.native ? '' : ' (dados simulados)'}';
    } catch (e) {
      message = 'Falha na medição: $e';
    }
    if (mounted) {
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.network_check),
            SizedBox(width: 8),
            Text('$kAppName Diagnostic'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_location_alt_outlined),
            tooltip: 'Registrar medição (RSSI + ping + perda)',
            onPressed: _recordMeasurement,
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(icon: Icon(Icons.graphic_eq), text: 'Espectro'),
            Tab(icon: Icon(Icons.show_chart), text: 'Sinal'),
            Tab(icon: Icon(Icons.speed), text: 'Latência'),
          ],
        ),
      ),
      body: AnimatedBuilder(
        animation: c,
        builder: (context, _) {
          return Column(
            children: [
              _SourceBanner(native: c.isNative),
              Expanded(
                child: TabBarView(
                  controller: _tabs,
                  children: [
                    SpectrumTab(c: c),
                    SignalTab(c: c),
                    LatencyTab(c: c),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SourceBanner extends StatelessWidget {
  final bool native;
  const _SourceBanner({required this.native});

  @override
  Widget build(BuildContext context) {
    final color = native ? Colors.green.shade50 : Colors.amber.shade100;
    return Container(
      width: double.infinity,
      color: color,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Icon(native ? Icons.verified_outlined : Icons.science_outlined, size: 18, color: Colors.black87),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              native
                  ? 'Dados reais do aparelho Android.'
                  : 'Modo simulação: dados fictícios. Abra o WaveLens no app Android (WaveLens Shell 3.0+) para a varredura real.',
              style: const TextStyle(fontSize: 12, color: Colors.black87),
            ),
          ),
        ],
      ),
    );
  }
}

class _PermissionCard extends StatelessWidget {
  final DiagnosticsController c;
  const _PermissionCard({required this.c});

  @override
  Widget build(BuildContext context) {
    final p = c.permissions;
    if (!c.isNative || p == null) return const SizedBox.shrink();
    if (p.granted && p.locationServicesEnabled) return const SizedBox.shrink();
    final message = !p.granted
        ? 'O Android exige a permissão de Localização para varrer redes Wi-Fi e ler o sinal.'
        : 'Ative a Localização (GPS) do aparelho: sem ela o Android não retorna as redes Wi-Fi.';
    return Card(
      color: Colors.orange.shade50,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Icon(Icons.location_off_outlined, color: Colors.deepOrange),
            const SizedBox(width: 12),
            Expanded(child: Text(message, style: const TextStyle(fontSize: 13, color: Colors.black87))),
            const SizedBox(width: 8),
            FilledButton(onPressed: c.requestPermissions, child: const Text('Conceder')),
          ],
        ),
      ),
    );
  }
}

String _two(int v) => v.toString().padLeft(2, '0');
String _clock(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

// ---------------------------------------------------------------------------
// Aba 1 — Espectro de canais & saúde do canal
// ---------------------------------------------------------------------------

const Color kConnectedColor = Color(0xFF00E676);
const Color kNeighborColor = Color(0xFF94A3B8);

class SpectrumTab extends StatelessWidget {
  final DiagnosticsController c;
  const SpectrumTab({super.key, required this.c});

  @override
  Widget build(BuildContext context) {
    final nets = c.networks.where((n) => n.band == c.band).toList();
    final mySsid = c.connectedSsid;
    final health = computeChannelHealth(c.band, c.networks, connectedSsid: mySsid);
    final hasSibling = mySsid.isNotEmpty && nets.any((n) => !n.connected && n.ssid == mySsid);
    final best = ([...health]..sort((a, b) => a.score != b.score ? a.score.compareTo(b.score) : a.channel.compareTo(b.channel)))
        .take(3)
        .toList();

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _PermissionCard(c: c),
        SegmentedButton<WifiBand>(
          segments: const [
            ButtonSegment(value: WifiBand.ghz24, label: Text('2.4 GHz'), icon: Icon(Icons.wifi)),
            ButtonSegment(value: WifiBand.ghz5, label: Text('5 GHz'), icon: Icon(Icons.wifi_channel)),
          ],
          selected: {c.band},
          onSelectionChanged: (s) => c.setBand(s.first),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 16,
          runSpacing: 4,
          children: [
            _LegendDot(
              color: kConnectedColor,
              label: hasSibling ? 'Sua rede "$mySsid" (conectada em outra banda)' : 'Rede conectada',
            ),
            const _LegendDot(color: kNeighborColor, label: 'Redes vizinhas'),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          height: 280,
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
          decoration: BoxDecoration(color: const Color(0xFF0F172A), borderRadius: BorderRadius.circular(12)),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = c.band == WifiBand.ghz5;
              final width = wide ? max(constraints.maxWidth, 980.0) : constraints.maxWidth;
              final chart = CustomPaint(
                size: Size(width, constraints.maxHeight),
                painter: SpectrumPainter(band: c.band, networks: nets, connectedSsid: mySsid),
              );
              return wide ? SingleChildScrollView(scrollDirection: Axis.horizontal, child: chart) : chart;
            },
          ),
        ),
        _ConnectedApCard(c: c),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                c.lastScan == null
                    ? (c.scanning ? 'Varrendo…' : 'Sem varredura ainda')
                    : 'Última varredura: ${_clock(c.lastScan!)} · ${nets.length} redes em ${c.band == WifiBand.ghz24 ? '2.4' : '5'} GHz',
                style: TextStyle(fontSize: 12, color: _muted(context)),
              ),
            ),
            if (c.scanning)
              const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            else
              TextButton.icon(onPressed: c.scanNow, icon: const Icon(Icons.refresh, size: 18), label: const Text('Escanear')),
          ],
        ),
        if (c.scanError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(c.scanError!, style: TextStyle(fontSize: 12, color: Colors.red.shade700)),
          ),
        if (c.isNative && c.lastScan != null && c.networks.isEmpty && c.scanError == null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'Nenhuma rede retornada. Confirme que a Localização (GPS) está ativada; o Android também limita a frequência das varreduras.',
              style: TextStyle(fontSize: 12, color: _muted(context)),
            ),
          ),
        _ChannelHealthCard(band: c.band, health: health, best: best),
      ],
    );
  }
}

/// Detalhes da rede conectada: SSID, BSSID, banda/canal, largura e dBm reais.
class _ConnectedApCard extends StatelessWidget {
  final DiagnosticsController c;
  const _ConnectedApCard({required this.c});

  @override
  Widget build(BuildContext context) {
    WifiNetwork? ap;
    for (final n in c.networks) {
      if (n.connected) {
        ap = n;
        break;
      }
    }
    final link = c.link;
    if (ap == null && (link == null || !link.connected)) return const SizedBox.shrink();

    final ssid = ap != null ? ap.displayName : (link!.ssid.isEmpty ? '(rede oculta)' : link.ssid);
    final rawBssid = ap?.bssid ?? link!.bssid;
    final bssid = rawBssid.isEmpty || rawBssid == '02:00:00:00:00:00' ? 'oculto pelo Android' : rawBssid;
    final bandChannel = ap != null
        ? '${ap.band == WifiBand.ghz24 ? '2.4' : '5'} GHz · canal ${ap.channel}'
        : '${link!.bandLabel} · canal ${link.channel}';
    final width = ap != null ? '${ap.widthMhz} MHz' : '--';
    final level = ap != null ? '${ap.level} dBm' : '${link!.rssi} dBm';

    Widget kv(String label, String value) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: TextStyle(fontSize: 11, color: _muted(context))),
            Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
          ],
        );

    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(width: 10, height: 10, decoration: const BoxDecoration(color: kConnectedColor, shape: BoxShape.circle)),
                const SizedBox(width: 8),
                const Text('Rede conectada', style: TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 24,
              runSpacing: 10,
              children: [
                kv('SSID', ssid),
                kv('BSSID', bssid),
                kv('Banda · canal', bandChannel),
                kv('Largura', width),
                kv('Sinal', level),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  const _LegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 12, height: 12, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}

class _ChannelHealthCard extends StatelessWidget {
  final WifiBand band;
  final List<ChannelHealth> health;
  final List<ChannelHealth> best;
  const _ChannelHealthCard({required this.band, required this.health, required this.best});

  @override
  Widget build(BuildContext context) {
    final head = TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _muted(context));
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Saúde do canal', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            const SizedBox(height: 2),
            Text(
              'Interferência estimada por canal de 20 MHz, contando só as redes vizinhas (a sua rede fica de fora).',
              style: TextStyle(fontSize: 12, color: _muted(context)),
            ),
            const SizedBox(height: 10),
            Text('Recomendados', style: head),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final h in best)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    avatar: CircleAvatar(backgroundColor: h.rating.color, radius: 5),
                    label: Text('Canal ${h.channel} · ${h.rating.label}', style: const TextStyle(fontSize: 12)),
                  ),
              ],
            ),
            const Divider(height: 20),
            Row(
              children: [
                SizedBox(width: 62, child: Text('Canal', style: head)),
                SizedBox(width: 70, child: Text('Freq.', style: head)),
                Expanded(child: Text('Interferência', style: head)),
                SizedBox(width: 44, child: Text('Redes', style: head, textAlign: TextAlign.center)),
                SizedBox(width: 84, child: Text('Saúde', style: head, textAlign: TextAlign.end)),
              ],
            ),
            const SizedBox(height: 4),
            for (final h in health)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    SizedBox(width: 62, child: Text('${h.channel}', style: const TextStyle(fontWeight: FontWeight.w600))),
                    SizedBox(width: 70, child: Text('${h.freq}', style: TextStyle(fontSize: 12, color: _muted(context)))),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: (h.score / 2.5).clamp(0.0, 1.0).toDouble(),
                          minHeight: 8,
                          color: h.rating.color,
                          backgroundColor: Colors.grey.shade200,
                        ),
                      ),
                    ),
                    SizedBox(width: 44, child: Text('${h.overlapping}', textAlign: TextAlign.center)),
                    SizedBox(
                      width: 84,
                      child: Text(
                        h.rating.label,
                        textAlign: TextAlign.end,
                        style: TextStyle(fontWeight: FontWeight.w600, color: h.rating.color),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Gráfico de espectro: um trapézio por rede (largura = 20/40/80/160 MHz,
/// altura = intensidade). A rede conectada — e a de mesmo nome em outra banda,
/// como o 2.4 GHz do roteador em que você está no 5 GHz — fica em cor acesa e
/// sublinhada; vizinhas em cinza.
class SpectrumPainter extends CustomPainter {
  final WifiBand band;
  final List<WifiNetwork> networks;
  final String connectedSsid;
  SpectrumPainter({required this.band, required this.networks, this.connectedSsid = ''});

  bool _isMine(WifiNetwork n) => n.connected || (connectedSsid.isNotEmpty && n.ssid == connectedSsid);

  static const double _left = 36, _right = 10, _top = 16, _bottom = 30;
  static const double _minDbm = -100, _maxDbm = -30;

  double get _xMin => band == WifiBand.ghz24 ? 2396 : 5160;
  double get _xMax => band == WifiBand.ghz24 ? 2498 : 5840;

  double _text(
    Canvas canvas,
    String text,
    Offset pos, {
    double size = 10,
    Color color = Colors.white70,
    FontWeight weight = FontWeight.normal,
    double maxWidth = double.infinity,
    bool centerX = false,
    bool anchorBottom = false,
    bool rightAlign = false,
    bool underline = false,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: size,
          color: color,
          fontWeight: weight,
          decoration: underline ? TextDecoration.underline : TextDecoration.none,
          decorationColor: color,
          decorationThickness: 2,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth);
    var dx = pos.dx;
    if (centerX) dx -= tp.width / 2;
    if (rightAlign) dx -= tp.width;
    tp.paint(canvas, Offset(dx, anchorBottom ? pos.dy - tp.height : pos.dy));
    return tp.width;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTRB(_left, _top, size.width - _right, size.height - _bottom);
    double xOf(double mhz) => plot.left + (mhz - _xMin) / (_xMax - _xMin) * plot.width;
    double yOf(double dbm) =>
        plot.bottom - ((dbm.clamp(_minDbm, _maxDbm) - _minDbm) / (_maxDbm - _minDbm)) * plot.height;

    final grid = Paint()
      ..color = Colors.white12
      ..strokeWidth = 1;
    for (var dbm = -90; dbm <= -40; dbm += 10) {
      final y = yOf(dbm.toDouble());
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
      _text(canvas, '$dbm', Offset(plot.left - 4, y - 6), size: 9, rightAlign: true);
    }
    canvas.drawLine(Offset(plot.left, plot.bottom), Offset(plot.right, plot.bottom), Paint()..color = Colors.white38);

    final channels = band == WifiBand.ghz24 ? [for (var c = 1; c <= 14; c++) c] : kChannels5Ghz;
    for (final ch in channels) {
      final x = xOf(channelToMhz(band, ch).toDouble());
      canvas.drawLine(Offset(x, plot.bottom), Offset(x, plot.bottom + 4), Paint()..color = Colors.white38);
      _text(canvas, '$ch', Offset(x, plot.bottom + 6), size: 9, centerX: true);
    }
    _text(canvas, 'Canal', Offset(plot.center.dx, size.height - 2), size: 9, color: Colors.white54, centerX: true, anchorBottom: true);

    canvas.save();
    canvas.clipRect(plot.inflate(2));

    Path trapezoid(WifiNetwork n) {
      final half = n.widthMhz / 2;
      final inset = n.widthMhz * 0.10;
      final yTop = yOf(n.level.toDouble());
      return Path()
        ..moveTo(xOf(n.centerFreq - half), plot.bottom)
        ..lineTo(xOf(n.centerFreq - half + inset), yTop)
        ..lineTo(xOf(n.centerFreq + half - inset), yTop)
        ..lineTo(xOf(n.centerFreq + half), plot.bottom)
        ..close();
    }

    final neighbors = networks.where((n) => !_isMine(n)).toList()..sort((a, b) => a.level.compareTo(b.level));
    final connected = networks.where(_isMine).toList();

    for (final n in neighbors) {
      final path = trapezoid(n);
      canvas.drawPath(path, Paint()..color = kNeighborColor.withOpacity(0.16));
      canvas.drawPath(
        path,
        Paint()
          ..color = kNeighborColor.withOpacity(0.75)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
    }
    for (final n in connected) {
      final path = trapezoid(n);
      canvas.drawPath(
        path,
        Paint()
          ..color = kConnectedColor.withOpacity(0.55)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 7
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );
      canvas.drawPath(path, Paint()..color = kConnectedColor.withOpacity(0.38));
      canvas.drawPath(
        path,
        Paint()
          ..color = kConnectedColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5,
      );
      // Sublinhado: barra grossa no eixo, cobrindo a largura do canal da rede.
      canvas.drawLine(
        Offset(xOf(n.centerFreq - n.widthMhz / 2), plot.bottom - 1.5),
        Offset(xOf(n.centerFreq + n.widthMhz / 2), plot.bottom - 1.5),
        Paint()
          ..color = kConnectedColor
          ..strokeWidth = 4
          ..strokeCap = StrokeCap.round,
      );
    }

    // Rótulos: rede conectada + as 4 vizinhas mais fortes.
    final strongest = ([...neighbors]..sort((a, b) => b.level.compareTo(a.level))).take(4);
    for (final n in strongest) {
      _text(canvas, n.displayName, Offset(xOf(n.centerFreq.toDouble()), yOf(n.level.toDouble()) - 2),
          size: 9, color: Colors.white70, centerX: true, anchorBottom: true, maxWidth: 90);
    }
    for (final n in connected) {
      final sibling = !n.connected;
      _text(
        canvas,
        '${n.displayName} (${n.level} dBm)${sibling ? ' · sua rede' : ''}',
        Offset(xOf(n.centerFreq.toDouble()), yOf(n.level.toDouble()) - 2),
        size: 11,
        color: kConnectedColor,
        weight: FontWeight.bold,
        centerX: true,
        anchorBottom: true,
        maxWidth: 170,
        underline: true,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant SpectrumPainter oldDelegate) => true;
}

// ---------------------------------------------------------------------------
// Aba 2 — Monitoramento contínuo de sinal (walk-through)
// ---------------------------------------------------------------------------

({String label, Color color}) signalQuality(double dbm) {
  if (dbm >= -50) return (label: 'Excelente', color: const Color(0xFF16A34A));
  if (dbm >= -60) return (label: 'Muito bom', color: const Color(0xFF65A30D));
  if (dbm >= -70) return (label: 'Bom', color: const Color(0xFFD97706));
  if (dbm >= -80) return (label: 'Fraco', color: const Color(0xFFEA580C));
  return (label: 'Muito fraco', color: const Color(0xFFDC2626));
}

class SignalTab extends StatelessWidget {
  final DiagnosticsController c;
  const SignalTab({super.key, required this.c});

  @override
  Widget build(BuildContext context) {
    final s = c.rssiSamples;
    final last = s.isEmpty ? null : s.last;
    final q = last == null ? null : signalQuality(last);
    final link = c.link;
    final minV = s.isEmpty ? null : s.reduce(min);
    final maxV = s.isEmpty ? null : s.reduce(max);
    final avg = s.isEmpty ? null : s.reduce((a, b) => a + b) / s.length;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _PermissionCard(c: c),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        last == null ? '-- dBm' : '${last.round()} dBm',
                        style: TextStyle(fontSize: 40, fontWeight: FontWeight.bold, color: q?.color),
                      ),
                      Text(
                        link == null
                            ? 'Aguardando leitura…'
                            : '${link.ssid.isEmpty ? '(rede)' : link.ssid} · ${link.bandLabel} · canal ${link.channel}',
                        style: TextStyle(fontSize: 12, color: _muted(context)),
                      ),
                    ],
                  ),
                ),
                if (q != null)
                  Chip(
                    label: Text(q.label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                    backgroundColor: q.color,
                    side: BorderSide.none,
                  ),
              ],
            ),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 16, 16, 8),
            child: SizedBox(
              height: 240,
              child: s.isEmpty
                  ? Center(child: Text('Sem amostras ainda', style: TextStyle(color: _muted(context))))
                  : LineChart(_rssiChart(s, q!.color), duration: Duration.zero),
            ),
          ),
        ),
        Row(
          children: [
            Expanded(child: _MiniStat(label: 'Mínimo', value: minV == null ? '--' : '${minV.round()} dBm')),
            const SizedBox(width: 8),
            Expanded(child: _MiniStat(label: 'Média', value: avg == null ? '--' : '${avg.round()} dBm')),
            const SizedBox(width: 8),
            Expanded(child: _MiniStat(label: 'Máximo', value: maxV == null ? '--' : '${maxV.round()} dBm')),
          ],
        ),
        if (c.signalError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(c.signalError!, style: TextStyle(fontSize: 12, color: Colors.red.shade700)),
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: c.toggleWalk,
                icon: Icon(c.walkRunning ? Icons.pause : Icons.play_arrow),
                label: Text(c.walkRunning ? 'Pausar' : 'Retomar'),
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(onPressed: c.resetSignal, icon: const Icon(Icons.delete_outline), label: const Text('Limpar')),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Caminhe pelo ambiente com o celular: as quedas no gráfico mostram onde o sinal enfraquece.',
          style: TextStyle(fontSize: 12, color: _muted(context)),
        ),
      ],
    );
  }
}

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;
  const _MiniStat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(fontSize: 11, color: _muted(context))),
            const SizedBox(height: 2),
            Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

LineChartData _rssiChart(List<double> samples, Color color) {
  final spots = <FlSpot>[
    for (var i = 0; i < samples.length; i++) FlSpot((kMaxSamples - samples.length + i).toDouble(), samples[i]),
  ];
  const noTitles = AxisTitles(sideTitles: SideTitles(showTitles: false));
  return LineChartData(
    minX: 0,
    maxX: (kMaxSamples - 1).toDouble(),
    minY: -100,
    maxY: -20,
    clipData: const FlClipData.all(),
    gridData: const FlGridData(show: true, drawVerticalLine: false, horizontalInterval: 10),
    borderData: FlBorderData(show: false),
    lineTouchData: const LineTouchData(enabled: false),
    titlesData: FlTitlesData(
      topTitles: noTitles,
      rightTitles: noTitles,
      bottomTitles: noTitles,
      leftTitles: AxisTitles(
        sideTitles: SideTitles(
          showTitles: true,
          reservedSize: 38,
          interval: 20,
          getTitlesWidget: (v, meta) => Text('${v.toInt()}', style: const TextStyle(fontSize: 10)),
        ),
      ),
    ),
    extraLinesData: ExtraLinesData(
      horizontalLines: [
        HorizontalLine(y: -60, color: Colors.green.withOpacity(0.6), strokeWidth: 1, dashArray: [6, 4]),
        HorizontalLine(y: -70, color: Colors.orange.withOpacity(0.7), strokeWidth: 1, dashArray: [6, 4]),
      ],
    ),
    lineBarsData: [
      LineChartBarData(
        spots: spots,
        isCurved: true,
        curveSmoothness: 0.2,
        color: color,
        barWidth: 3,
        dotData: const FlDotData(show: false),
        belowBarData: BarAreaData(show: true, color: color.withOpacity(0.15)),
      ),
    ],
  );
}

// ---------------------------------------------------------------------------
// Aba 3 — Latência & rede (double-ping: gateway vs DNS da Internet)
// ---------------------------------------------------------------------------

class LatencyTab extends StatelessWidget {
  final DiagnosticsController c;
  const LatencyTab({super.key, required this.c});

  static const Color _gwColor = Color(0xFF0D9488);
  static const Color _dnsColor = Color(0xFFEA580C);

  double? _last(List<double?> s) {
    for (var i = s.length - 1; i >= 0; i--) {
      if (s[i] != null) return s[i];
    }
    return null;
  }

  double? _avg(List<double?> s) {
    final v = s.whereType<double>().toList();
    return v.isEmpty ? null : v.reduce((a, b) => a + b) / v.length;
  }

  String _ms(double? v) => v == null ? '--' : '${v.toStringAsFixed(v < 10 ? 1 : 0)} ms';
  String _loss(int lost, int sent) => sent == 0 ? '--' : '${(lost * 100 / sent).toStringAsFixed(lost == 0 ? 0 : 1)}%';

  @override
  Widget build(BuildContext context) {
    final gwLast = _last(c.gwSamples);
    final dnsLast = _last(c.dnsSamples);
    final phy = c.link?.linkSpeedMbps;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final w = (constraints.maxWidth - 8) / 2;
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _StatTile(
                  width: w,
                  icon: Icons.report_gmailerrorred_outlined,
                  title: 'Perda de pacotes',
                  value: 'DNS ${_loss(c.dnsLost, c.dnsSent)}',
                  subtitle: c.gatewayIp.isEmpty ? 'Gateway indisponível' : 'Gateway ${_loss(c.gwLost, c.gwSent)}',
                  color: LatencyTab._dnsColor,
                ),
                _StatTile(
                  width: w,
                  icon: Icons.dns_outlined,
                  title: 'Latência DNS ($kDnsHost)',
                  value: _ms(dnsLast),
                  subtitle: 'Média ${_ms(_avg(c.dnsSamples))}',
                  color: LatencyTab._dnsColor,
                ),
                _StatTile(
                  width: w,
                  icon: Icons.router_outlined,
                  title: 'Latência Gateway',
                  value: _ms(gwLast),
                  subtitle: c.gatewayIp.isEmpty ? 'IP não detectado' : '${c.gatewayIp} · média ${_ms(_avg(c.gwSamples))}',
                  color: LatencyTab._gwColor,
                ),
                _StatTile(
                  width: w,
                  icon: Icons.speed,
                  title: 'Velocidade PHY',
                  value: phy == null || phy == 0 ? '-- Mbps' : '$phy Mbps',
                  subtitle: 'Taxa negociada com o roteador',
                  color: Colors.indigo,
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 12, 16, 8),
            child: Column(
              children: [
                const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _LegendDot(color: _gwColor, label: 'Gateway (roteador)'),
                    SizedBox(width: 16),
                    _LegendDot(color: _dnsColor, label: 'DNS Internet'),
                  ],
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 220,
                  child: c.gwSamples.isEmpty && c.dnsSamples.isEmpty
                      ? Center(child: Text('Sem amostras ainda', style: TextStyle(color: _muted(context))))
                      : LineChart(_latencyChart(c.gwSamples, c.dnsSamples), duration: Duration.zero),
                ),
              ],
            ),
          ),
        ),
        if (c.pingError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(c.pingError!, style: TextStyle(fontSize: 12, color: Colors.red.shade700)),
          ),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: c.togglePing,
                icon: Icon(c.pingRunning ? Icons.pause : Icons.play_arrow),
                label: Text(c.pingRunning ? 'Pausar' : 'Retomar'),
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(onPressed: c.resetPing, icon: const Icon(Icons.delete_outline), label: const Text('Zerar')),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Compara a latência até o roteador (rede local) com a do DNS público: se só o DNS piora, o problema está fora de casa.',
          style: TextStyle(fontSize: 12, color: _muted(context)),
        ),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  final double width;
  final IconData icon;
  final String title;
  final String value;
  final String subtitle;
  final Color color;
  const _StatTile({
    required this.width,
    required this.icon,
    required this.title,
    required this.value,
    required this.subtitle,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 16, color: color),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(title, style: TextStyle(fontSize: 11, color: _muted(context)), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: color)),
              const SizedBox(height: 2),
              Text(subtitle, style: TextStyle(fontSize: 11, color: _muted(context)), maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      ),
    );
  }
}

LineChartData _latencyChart(List<double?> gw, List<double?> dns) {
  List<FlSpot> spots(List<double?> s) => [
        for (var i = 0; i < s.length; i++)
          s[i] == null ? FlSpot.nullSpot : FlSpot((kMaxSamples - s.length + i).toDouble(), s[i]!),
      ];
  final values = [...gw, ...dns].whereType<double>();
  final peak = values.isEmpty ? 40.0 : values.reduce(max);
  final maxY = max(40.0, (peak * 1.25 / 10).ceil() * 10.0);
  const noTitles = AxisTitles(sideTitles: SideTitles(showTitles: false));

  LineChartBarData bar(List<double?> s, Color color) => LineChartBarData(
        spots: spots(s),
        isCurved: false,
        color: color,
        barWidth: 2.5,
        dotData: const FlDotData(show: false),
      );

  return LineChartData(
    minX: 0,
    maxX: (kMaxSamples - 1).toDouble(),
    minY: 0,
    maxY: maxY,
    clipData: const FlClipData.all(),
    gridData: const FlGridData(show: true, drawVerticalLine: false),
    borderData: FlBorderData(show: false),
    lineTouchData: const LineTouchData(enabled: false),
    titlesData: FlTitlesData(
      topTitles: noTitles,
      rightTitles: noTitles,
      bottomTitles: noTitles,
      leftTitles: AxisTitles(
        sideTitles: SideTitles(
          showTitles: true,
          reservedSize: 34,
          getTitlesWidget: (v, meta) => Text('${v.toInt()}', style: const TextStyle(fontSize: 10)),
        ),
      ),
    ),
    lineBarsData: [
      if (gw.isNotEmpty) bar(gw, LatencyTab._gwColor),
      if (dns.isNotEmpty) bar(dns, LatencyTab._dnsColor),
    ],
  );
}

// ===========================================================================
// PARTE 3 — NETFLOOR ENTERPRISE (v8.0): temas, armazenamento local, arquivos,
// assinatura digital e laudo de vistoria em PDF
// ===========================================================================

// ---------------------------------------------------------------------------
// Modos de visualização
//   - Apresentação: escuro/moderno, para mostrar ao cliente.
//   - Diagnóstico: alto contraste (preto/branco/amarelo), legível sob sol forte.
// ---------------------------------------------------------------------------

enum ViewMode { presentation, diagnostic }

final ValueNotifier<ViewMode> kViewMode = ValueNotifier<ViewMode>(ViewMode.presentation);

void setViewMode(ViewMode mode, AppStore store) {
  kViewMode.value = mode;
  unawaited(store.setSetting('viewMode', mode.name));
}

ThemeData buildTheme(ViewMode mode) {
  if (mode == ViewMode.diagnostic) {
    const yellow = Color(0xFFFFD400);
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF0033A0)).copyWith(
      primary: const Color(0xFF0033A0),
      onPrimary: Colors.white,
      surface: Colors.white,
      onSurface: Colors.black,
      onSurfaceVariant: const Color(0xFF1F1F1F),
      outline: Colors.black,
      outlineVariant: const Color(0xFF444444),
      surfaceContainerHighest: const Color(0xFFE9E9E9),
      primaryContainer: yellow,
      onPrimaryContainer: Colors.black,
    );
    final base = ThemeData(useMaterial3: true, colorScheme: scheme);
    return base.copyWith(
      scaffoldBackgroundColor: Colors.white,
      textTheme: base.textTheme.apply(bodyColor: Colors.black, displayColor: Colors.black),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        titleTextStyle: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700),
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Colors.black, width: 1.4)),
      ),
      chipTheme: ChipThemeData(
        side: const BorderSide(color: Colors.black, width: 1.3),
        selectedColor: yellow,
        backgroundColor: Colors.white,
        labelStyle: const TextStyle(color: Colors.black, fontWeight: FontWeight.w700),
        checkmarkColor: Colors.black,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.white,
        indicatorColor: yellow,
        labelTextStyle: WidgetStateProperty.all(const TextStyle(fontWeight: FontWeight.w700, color: Colors.black, fontSize: 12)),
        iconTheme: WidgetStateProperty.all(const IconThemeData(color: Colors.black)),
      ),
      dividerTheme: const DividerThemeData(color: Colors.black, thickness: 1),
      tabBarTheme: const TabBarThemeData(
        labelColor: Colors.white,
        unselectedLabelColor: Color(0xFFCCCCCC),
        indicatorColor: yellow,
        labelStyle: TextStyle(fontWeight: FontWeight.w700),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(backgroundColor: Colors.black, foregroundColor: Colors.white),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(foregroundColor: Colors.black, side: const BorderSide(color: Colors.black, width: 1.5)),
      ),
    );
  }

  const bg = Color(0xFF0B1020);
  const card = Color(0xFF141B31);
  final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF6366F1), brightness: Brightness.dark).copyWith(
    surface: bg,
    surfaceContainerHighest: const Color(0xFF1B2440),
    primary: const Color(0xFF8B93FF),
    onPrimary: const Color(0xFF0B1020),
    primaryContainer: const Color(0xFF2A3266),
    onPrimaryContainer: Colors.white,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, brightness: Brightness.dark);
  return base.copyWith(
    scaffoldBackgroundColor: bg,
    appBarTheme: const AppBarTheme(backgroundColor: bg, foregroundColor: Colors.white, elevation: 0, scrolledUnderElevation: 0),
    cardTheme: CardThemeData(
      color: card,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: const Color(0xFF0F1526),
      indicatorColor: const Color(0xFF2A3266),
    ),
    bottomSheetTheme: const BottomSheetThemeData(backgroundColor: Color(0xFF10172B)),
    dialogTheme: DialogThemeData(backgroundColor: const Color(0xFF10172B), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
  );
}

// ---------------------------------------------------------------------------
// Diálogos utilitários
// ---------------------------------------------------------------------------

class BusyDialog extends StatelessWidget {
  final String message;
  const BusyDialog(this.message, {super.key});

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3)),
            const SizedBox(width: 16),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
  }
}

Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirmar',
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(confirmLabel)),
      ],
    ),
  );
  return ok ?? false;
}

/// Nome de arquivo seguro (sem acentos, espaços ou símbolos).
String safeFileName(String input) {
  const from = 'áàâãäéèêëíìîïóòôõöúùûüçñÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑ';
  const to = 'aaaaaeeeeiiiiooooouuuucnAAAAAEEEEIIIIOOOOOUUUUCN';
  final sb = StringBuffer();
  for (final ch in input.trim().split('')) {
    final i = from.indexOf(ch);
    sb.write(i >= 0 ? to[i] : ch);
  }
  final cleaned = sb.toString().replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_').replaceAll(RegExp(r'_+'), '_');
  final trimmed = cleaned.replaceAll(RegExp(r'^_+|_+$'), '');
  return trimmed.isEmpty ? 'netfloor' : trimmed;
}

// ---------------------------------------------------------------------------
// Armazenamento local offline-first (IndexedDB via sembast_web)
//
//   workspaces  -> um documento JSON por projeto (sem os bytes das imagens)
//   images      -> plantas personalizadas (base64), por id da planta
//   settings    -> preferências (modo de visualização, último projeto)
//
// O salvamento é automático (com atraso de ~0,8 s após a última alteração) e
// imediato ao esconder a página. Sem IndexedDB (aba privada, por exemplo) o app
// segue funcionando, apenas sem persistir.
// ---------------------------------------------------------------------------

class WorkspaceSummary {
  final String id;
  final String name;
  final DateTime updatedAt;
  final int floors;
  final int routers;
  final int points;
  const WorkspaceSummary({
    required this.id,
    required this.name,
    required this.updatedAt,
    required this.floors,
    required this.routers,
    required this.points,
  });
}

class AppStore {
  Database? _db;
  bool available = false;
  final ValueNotifier<String> status = ValueNotifier<String>('');

  final StoreRef<String, Map<String, Object?>> _ws = stringMapStoreFactory.store('workspaces');
  final StoreRef<String, String> _images = StoreRef<String, String>('images');
  final StoreRef<String, String> _settings = StoreRef<String, String>('settings');
  final Set<String> _savedImages = {};

  Timer? _timer;
  NetworkModel? _attached;
  bool _saving = false;

  Future<void> init() async {
    try {
      _db = await databaseFactoryWeb.openDatabase('netfloor_v8');
      available = true;
      status.value = '';
    } catch (_) {
      available = false;
      status.value = 'sem armazenamento local';
    }
  }

  Future<String?> getSetting(String key) async {
    final db = _db;
    if (db == null) return null;
    try {
      return await _settings.record(key).get(db);
    } catch (_) {
      return null;
    }
  }

  Future<void> setSetting(String key, String value) async {
    final db = _db;
    if (db == null) return;
    try {
      await _settings.record(key).put(db, value);
    } catch (_) {}
  }

  /// Liga o autosave ao modelo.
  void attach(NetworkModel model) {
    _attached = model;
    model.addListener(_scheduleSave);
    try {
      web.document.addEventListener(
        'visibilitychange',
        ((web.Event _) {
          if (web.document.visibilityState == 'hidden') unawaited(saveNow(model));
        }).toJS,
      );
    } catch (_) {}
  }

  void _scheduleSave() {
    if (_db == null) return;
    _timer?.cancel();
    status.value = 'salvando…';
    _timer = Timer(const Duration(milliseconds: 800), () {
      final m = _attached;
      if (m != null) unawaited(saveNow(m));
    });
  }

  Future<void> saveNow(NetworkModel m) async {
    final db = _db;
    if (db == null || _saving) return;
    _timer?.cancel();
    _saving = true;
    try {
      for (final f in m.floors) {
        if (f.plan.isCustom && !_savedImages.contains(f.plan.id)) {
          await _images.record(f.plan.id).put(db, base64Encode(f.plan.memoryBytes!));
          _savedImages.add(f.plan.id);
        }
      }
      m.updatedAt = DateTime.now();
      final doc = jsonDecode(jsonEncode(m.toJson(embedImages: false))) as Map<String, Object?>;
      await _ws.record(m.workspaceId).put(db, doc);
      await setSetting('lastWorkspace', m.workspaceId);
      status.value = 'salvo ${_two(m.updatedAt.hour)}:${_two(m.updatedAt.minute)}';
    } catch (e) {
      status.value = 'erro ao salvar';
    } finally {
      _saving = false;
    }
  }

  Future<List<WorkspaceSummary>> list() async {
    final db = _db;
    if (db == null) return const [];
    try {
      final recs = await _ws.find(db);
      final out = <WorkspaceSummary>[
        for (final r in recs)
          WorkspaceSummary(
            id: r.key,
            name: (r.value['name'] as String?) ?? r.key,
            updatedAt: DateTime.tryParse('${r.value['updatedAt']}') ?? DateTime.fromMillisecondsSinceEpoch(0),
            floors: (r.value['floors'] as List?)?.length ?? 0,
            routers: (r.value['routers'] as List?)?.length ?? 0,
            points: (r.value['points'] as List?)?.length ?? 0,
          ),
      ];
      out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return out;
    } catch (_) {
      return const [];
    }
  }

  Future<void> open(String id, NetworkModel model) async {
    final db = _db;
    if (db == null) throw StateError('Armazenamento local indisponível.');
    final rec = await _ws.record(id).get(db);
    if (rec == null) throw StateError('Projeto não encontrado.');
    final j = jsonDecode(jsonEncode(rec)) as Map<String, dynamic>;
    final images = <String, Uint8List>{};
    for (final imageId in NetworkModel.customImageIds(j)) {
      final b64 = await _images.record(imageId).get(db);
      if (b64 != null) {
        images[imageId] = base64Decode(b64);
        _savedImages.add(imageId);
      }
    }
    model.applyJson(j, images);
  }

  /// Restaura o último projeto aberto (se houver). Retorna true se restaurou.
  Future<bool> restoreLast(NetworkModel model) async {
    final id = await getSetting('lastWorkspace');
    if (id == null) return false;
    try {
      await open(id, model);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> delete(String id) async {
    final db = _db;
    if (db == null) return;
    try {
      final rec = await _ws.record(id).get(db);
      if (rec != null) {
        final j = jsonDecode(jsonEncode(rec)) as Map<String, dynamic>;
        for (final imageId in NetworkModel.customImageIds(j)) {
          await _images.record(imageId).delete(db);
          _savedImages.remove(imageId);
        }
      }
      await _ws.record(id).delete(db);
    } catch (_) {}
  }
}

// ---------------------------------------------------------------------------
// Entrega de arquivos (PDF e .json): download do navegador ou, dentro do
// WaveLens Shell (Android 3.2+), gravação em Downloads / folha de compartilhar.
// ---------------------------------------------------------------------------

class FileIO {
  static String? _shellVersion;

  static bool _atLeast(String version, List<int> min) {
    final parts = version.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    for (var i = 0; i < min.length; i++) {
      final v = i < parts.length ? parts[i] : 0;
      if (v != min[i]) return v > min[i];
    }
    return true;
  }

  /// Versão do Shell que hospeda o app (null fora do Shell).
  static Future<String?> shellVersion() async {
    if (!NativeBridge.available) return null;
    if (_shellVersion != null) return _shellVersion;
    try {
      final d = await NativeBridge.call('hello');
      _shellVersion = '${d['shellVersion'] ?? '0.0.0'}';
    } catch (_) {
      _shellVersion = '0.0.0';
    }
    return _shellVersion;
  }

  static Future<bool> nativeFilesSupported() async {
    final v = await shellVersion();
    return v != null && _atLeast(v, const [3, 2, 0]);
  }

  /// Entrega [bytes] ao usuário. Retorna uma mensagem curta para mostrar.
  static Future<String> deliver(String name, String mime, Uint8List bytes, {bool share = false}) async {
    if (NativeBridge.available) {
      if (!await nativeFilesSupported()) {
        throw StateError('Atualize o app WaveLens Shell (3.2 ou superior) para salvar/compartilhar arquivos.');
      }
      const chunkChars = 262144; // 256 KB de base64 por mensagem (múltiplo de 4)
      final b64 = base64Encode(bytes);
      final chunks = max(1, (b64.length / chunkChars).ceil());
      Map<String, dynamic> last = const {};
      for (var i = 0; i < chunks; i++) {
        last = await NativeBridge.call(
          'saveFile',
          args: {
            'name': name,
            'mime': mime,
            'share': share,
            'chunk': i,
            'chunks': chunks,
            'data': b64.substring(i * chunkChars, min(b64.length, (i + 1) * chunkChars)),
          },
          timeout: const Duration(seconds: 60),
        );
      }
      return share ? 'Compartilhando "$name"…' : '${last['location'] ?? 'Salvo em Downloads'}';
    }
    _browserDownload(name, mime, bytes);
    return 'Arquivo "$name" baixado.';
  }

  static void _browserDownload(String name, String mime, Uint8List bytes) {
    final blob = web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: mime));
    final url = web.URL.createObjectURL(blob);
    final a = web.document.createElement('a') as web.HTMLAnchorElement
      ..href = url
      ..download = name
      ..style.display = 'none';
    web.document.body!.append(a);
    a.click();
    a.remove();
    Timer(const Duration(seconds: 60), () => web.URL.revokeObjectURL(url));
  }
}

// ---------------------------------------------------------------------------
// Assinatura digital: quadro de captura (dedo/mouse) e exportação em PNG
// ---------------------------------------------------------------------------

class SignaturePadPage extends StatefulWidget {
  final String signerName;
  const SignaturePadPage({super.key, this.signerName = ''});

  @override
  State<SignaturePadPage> createState() => _SignaturePadPageState();
}

class _SignaturePadPageState extends State<SignaturePadPage> {
  final List<List<Offset>> _strokes = [];
  Size _size = const Size(300, 200);

  Future<Uint8List?> _export() async {
    final pts = [for (final s in _strokes) ...s];
    if (pts.isEmpty) return null;
    var minX = pts.first.dx, maxX = pts.first.dx, minY = pts.first.dy, maxY = pts.first.dy;
    for (final p in pts) {
      minX = min(minX, p.dx);
      maxX = max(maxX, p.dx);
      minY = min(minY, p.dy);
      maxY = max(maxY, p.dy);
    }
    const pad = 14.0, scale = 2.5;
    final box = Rect.fromLTRB(minX - pad, minY - pad, maxX + pad, maxY + pad);
    final w = (box.width * scale).ceil().clamp(60, 4000);
    final h = (box.height * scale).ceil().clamp(40, 4000);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = Colors.white);
    canvas.scale(scale);
    canvas.translate(-box.left, -box.top);
    SignaturePainter(_strokes, Colors.black).paint(canvas, _size);
    final image = await recorder.endRecording().toImage(w, h);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data?.buffer.asUint8List();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Assinatura do cliente'),
        actions: [
          TextButton(
            onPressed: _strokes.isEmpty ? null : () => setState(_strokes.clear),
            child: const Text('Limpar'),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.signerName.isEmpty
                    ? 'Peça ao cliente para assinar com o dedo no quadro abaixo.'
                    : '${widget.signerName}: assine com o dedo no quadro abaixo.',
              ),
              const SizedBox(height: 12),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, c) {
                    _size = Size(c.maxWidth, c.maxHeight);
                    return Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: _muted(context), width: 1.5),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(11),
                        child: Listener(
                          behavior: HitTestBehavior.opaque,
                          onPointerDown: (e) => setState(() => _strokes.add([e.localPosition])),
                          onPointerMove: (e) {
                            if (_strokes.isNotEmpty) setState(() => _strokes.last.add(e.localPosition));
                          },
                          child: Stack(
                            children: [
                              Positioned(
                                left: 16,
                                right: 16,
                                bottom: 36,
                                child: Container(height: 1.5, color: Colors.black26),
                              ),
                              const Positioned(
                                left: 18,
                                bottom: 14,
                                child: Text('assine acima da linha', style: TextStyle(color: Colors.black38, fontSize: 12)),
                              ),
                              Positioned.fill(child: CustomPaint(painter: SignaturePainter(_strokes, Colors.black))),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _strokes.isEmpty
                          ? null
                          : () async {
                              final png = await _export();
                              if (context.mounted) Navigator.pop(context, png);
                            },
                      icon: const Icon(Icons.check),
                      label: const Text('Confirmar'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SignaturePainter extends CustomPainter {
  final List<List<Offset>> strokes;
  final Color color;
  const SignaturePainter(this.strokes, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final dot = Paint()..color = color;
    for (final s in strokes) {
      if (s.length == 1) {
        canvas.drawCircle(s.first, 1.6, dot);
        continue;
      }
      final path = Path()..moveTo(s.first.dx, s.first.dy);
      for (var i = 1; i < s.length - 1; i++) {
        final mid = (s[i] + s[i + 1]) / 2; // curva suave passando pelos pontos médios
        path.quadraticBezierTo(s[i].dx, s[i].dy, mid.dx, mid.dy);
      }
      path.lineTo(s.last.dx, s.last.dy);
      canvas.drawPath(path, line);
    }
  }

  @override
  bool shouldRepaint(covariant SignaturePainter old) => true;
}

// ---------------------------------------------------------------------------
// Tela do laudo de vistoria
// ---------------------------------------------------------------------------

class ReportPage extends StatefulWidget {
  final NetworkModel model;
  final DiagnosticsController diag;
  final AppStore store;
  const ReportPage({super.key, required this.model, required this.diag, required this.store});

  @override
  State<ReportPage> createState() => _ReportPageState();
}

class _ReportPageState extends State<ReportPage> {
  NetworkModel get _m => widget.model;
  ReportInfo get _r => _m.report;

  late final TextEditingController _technician = TextEditingController(text: _r.technician);
  late final TextEditingController _company = TextEditingController(text: _r.company);
  late final TextEditingController _client = TextEditingController(text: _r.client);
  late final TextEditingController _address = TextEditingController(text: _r.address);
  late final TextEditingController _notes = TextEditingController(text: _r.notes);
  late final TextEditingController _signer = TextEditingController(text: _r.signerName);
  late final Set<RfBand> _bands = {_m.band};

  @override
  void dispose() {
    for (final c in [_technician, _company, _client, _address, _notes, _signer]) {
      c.dispose();
    }
    super.dispose();
  }

  void _snack(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _pickLogo() async {
    try {
      final file = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp']);
      if (file == null) return;
      final bytes = await file.readAsBytes();
      // valida que a imagem decodifica
      final codec = await ui.instantiateImageCodec(bytes);
      codec.dispose();
      setState(() => _r.logo = bytes);
      _m.touch();
    } catch (e) {
      if (mounted) _snack('Não foi possível carregar o logo: $e');
    }
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _r.date ?? now,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d != null) {
      setState(() => _r.date = d);
      _m.touch();
    }
  }

  Future<void> _collectSignature() async {
    final png = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(builder: (_) => SignaturePadPage(signerName: _signer.text.trim().isEmpty ? _client.text.trim() : _signer.text.trim())),
    );
    if (png == null) return;
    setState(() {
      _r.signature = png;
      _r.signedAt = DateTime.now();
      if (_r.signerName.isEmpty && _client.text.trim().isNotEmpty) {
        _r.signerName = _client.text.trim();
        _signer.text = _r.signerName;
      }
    });
    _m.touch();
  }

  Future<void> _generate({required bool share}) async {
    if (_m.routers.isEmpty) {
      _snack('Adicione ao menos um roteador no simulador para gerar o mapa de calor do laudo.');
      return;
    }
    if (_bands.isEmpty) {
      _snack('Selecione ao menos uma banda para o laudo.');
      return;
    }
    showDialog<void>(context: context, barrierDismissible: false, builder: (_) => const BusyDialog('Gerando o laudo em PDF…'));
    String message;
    try {
      final bytes = await LaudoPdf.build(_m, bands: RfBand.values.where(_bands.contains).toList());
      final date = _r.date ?? DateTime.now();
      final who = _r.client.trim().isEmpty ? _m.workspaceName : _r.client;
      final name = 'Laudo_${safeFileName(who)}_${date.year}${_two(date.month)}${_two(date.day)}.pdf';
      message = await FileIO.deliver(name, 'application/pdf', bytes, share: share);
    } catch (e) {
      message = 'Não foi possível gerar/salvar o laudo: $e';
    } finally {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }
    if (mounted) _snack(message);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Laudo de vistoria')),
      body: SafeArea(
        child: AnimatedBuilder(
          animation: _m,
          builder: (context, _) {
            final measured = _m.logs.length;
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _section('Dados do laudo'),
                TextField(
                  controller: _technician,
                  decoration: const InputDecoration(labelText: 'Técnico responsável', border: OutlineInputBorder()),
                  onChanged: (v) {
                    _r.technician = v;
                    _m.touch();
                  },
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _company,
                  decoration: const InputDecoration(labelText: 'Empresa / Provedor (ISP)', border: OutlineInputBorder()),
                  onChanged: (v) {
                    _r.company = v;
                    _m.touch();
                  },
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                        borderRadius: BorderRadius.circular(10),
                        color: Colors.white,
                      ),
                      alignment: Alignment.center,
                      child: _r.logo == null
                          ? const Icon(Icons.image_outlined, color: Colors.black38)
                          : Padding(padding: const EdgeInsets.all(4), child: Image.memory(_r.logo!, fit: BoxFit.contain)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          OutlinedButton.icon(
                            onPressed: _pickLogo,
                            icon: const Icon(Icons.upload_file),
                            label: Text(_r.logo == null ? 'Enviar logo da empresa' : 'Trocar logo'),
                          ),
                          if (_r.logo != null)
                            TextButton(
                              onPressed: () {
                                setState(() => _r.logo = null);
                                _m.touch();
                              },
                              child: const Text('Remover'),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _client,
                  decoration: const InputDecoration(labelText: 'Cliente', border: OutlineInputBorder()),
                  onChanged: (v) {
                    _r.client = v;
                    _m.touch();
                  },
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _address,
                  decoration: const InputDecoration(labelText: 'Endereço da vistoria', border: OutlineInputBorder()),
                  onChanged: (v) {
                    _r.address = v;
                    _m.touch();
                  },
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: _pickDate,
                  icon: const Icon(Icons.event),
                  label: Text('Data da vistoria: ${_fmtDate(_r.date ?? DateTime.now())}${_r.date == null ? ' (hoje)' : ''}'),
                ),
                _section('Conteúdo do laudo'),
                Text(
                  'Projeto "${_m.workspaceName}": ${_m.floors.length} pavimento(s), ${_m.routers.length} roteador(es), '
                  '${_m.points.length} ponto(s) de medição, $measured medição(ões) de campo.',
                ),
                const SizedBox(height: 8),
                const Text('Bandas com mapa de calor no laudo:', style: TextStyle(fontWeight: FontWeight.w600)),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final b in kRfBands)
                      FilterChip(
                        label: Text(b.label),
                        selected: _bands.contains(b.band),
                        onSelected: (v) => setState(() => v ? _bands.add(b.band) : _bands.remove(b.band)),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                if (!_m.floors.every((f) => f.calibrated))
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.straighten, size: 18, color: Colors.amber),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Há pavimento(s) com escala estimada. Use a Régua no simulador para calibrar as distâncias reais.',
                          style: TextStyle(fontSize: 12, color: _muted(context)),
                        ),
                      ),
                    ],
                  ),
                _section('Observações do técnico'),
                TextField(
                  controller: _notes,
                  minLines: 4,
                  maxLines: 10,
                  decoration: const InputDecoration(
                    hintText: 'Recomendações, pontos de atenção, equipamentos sugeridos…',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) {
                    _r.notes = v;
                    _m.touch();
                  },
                ),
                _section('Assinatura do cliente'),
                TextField(
                  controller: _signer,
                  decoration: const InputDecoration(labelText: 'Nome de quem assina', border: OutlineInputBorder()),
                  onChanged: (v) {
                    _r.signerName = v;
                    _m.touch();
                  },
                ),
                const SizedBox(height: 10),
                if (_r.signature != null)
                  Container(
                    height: 110,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                    ),
                    child: Image.memory(_r.signature!, fit: BoxFit.contain),
                  ),
                if (_r.signedAt != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('Assinado em ${_fmtDateTime(_r.signedAt!)}', style: TextStyle(fontSize: 12, color: _muted(context))),
                  ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: _collectSignature,
                      icon: const Icon(Icons.draw_outlined),
                      label: Text(_r.signature == null ? 'Coletar assinatura' : 'Refazer assinatura'),
                    ),
                    if (_r.signature != null)
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _r.signature = null;
                            _r.signedAt = null;
                          });
                          _m.touch();
                        },
                        child: const Text('Remover'),
                      ),
                  ],
                ),
                _section('Registro de diagnósticos ($measured)'),
                if (measured == 0)
                  Text(
                    'Nenhuma medição de campo registrada. Marque pontos no simulador (ferramenta Ponto → Medir agora) '
                    'ou use "Registrar medição" na aba Diagnóstico.',
                    style: TextStyle(fontSize: 13, color: _muted(context)),
                  )
                else ...[
                  for (final l in _m.logs.reversed.take(8))
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(l.native ? Icons.verified_outlined : Icons.science_outlined, size: 20),
                      title: Text('${l.pointName ?? 'Sem ponto'} · ${l.rssi} dBm · PHY ${l.linkMbps} Mbps'),
                      subtitle: Text(
                        '${_fmtDateTime(l.time)} · ${l.native ? 'real' : 'simulado'} · '
                        'GW ${l.gwAvgMs?.toStringAsFixed(1) ?? '—'} ms · Internet ${l.netAvgMs?.toStringAsFixed(0) ?? '—'} ms · '
                        'perda ${l.netLossPct.toStringAsFixed(0)}%',
                      ),
                    ),
                  if (measured > 8) Text('… e mais ${measured - 8} registro(s) (todos entram no PDF).', style: const TextStyle(fontSize: 12)),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () async {
                        final ok = await confirmDialog(
                          context,
                          title: 'Apagar registros?',
                          message: 'Todas as medições de campo deste projeto serão removidas.',
                          confirmLabel: 'Apagar',
                        );
                        if (ok) _m.clearLogs();
                      },
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Apagar registros'),
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: () => _generate(share: false),
                  icon: const Icon(Icons.picture_as_pdf_outlined),
                  label: const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Text('Gerar laudo em PDF')),
                ),
                if (NativeBridge.available) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () => _generate(share: true),
                    icon: const Icon(Icons.share_outlined),
                    label: const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Text('Gerar e compartilhar')),
                  ),
                ],
                const SizedBox(height: 24),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(top: 22, bottom: 10),
        child: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      );
}

// ---------------------------------------------------------------------------
// Gerador do laudo em PDF (biblioteca `pdf`, 100% Dart — roda no navegador e
// no WebView). O mapa de calor é renderizado fora da tela (PictureRecorder) com
// o mesmo motor do simulador e incorporado como imagem.
// ---------------------------------------------------------------------------

/// Mapa renderizado fora da tela, já codificado em JPEG (o PDF o incorpora sem
/// recompressão, mantendo o arquivo leve).
class FloorRaster {
  final Uint8List jpeg;
  final int width;
  final int height;
  const FloorRaster(this.jpeg, this.width, this.height);
}

Future<ui.Image?> _loadPlanImage(FloorPlanDef plan) async {
  try {
    Uint8List? bytes = plan.memoryBytes;
    if (bytes == null && plan.assetPath != null) {
      bytes = (await rootBundle.load(plan.assetPath!)).buffer.asUint8List();
    }
    if (bytes == null) return null;
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  } catch (_) {
    return null; // sem imagem (ex.: PNG ainda não enviado) -> desenho vetorial
  }
}

/// Renderiza o pavimento [floor] na banda [band]: planta + mapa de calor +
/// paredes desenhadas + roteadores (R1, R2…) + pontos de medição + barra de escala.
Future<FloorRaster> renderFloorRaster(NetworkModel m, int floor, RfBand band, {int width = 1000}) async {
  final f = m.floors[floor];
  final size = Size(width.toDouble(), width / f.plan.aspectRatio);
  final rect = Offset.zero & size;
  final k = width / 350.0; // proporção em relação ao tamanho típico do mapa na tela
  final image = await _loadPlanImage(f.plan);

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(rect, Paint()..color = Colors.white);
  if (image != null) {
    paintImage(canvas: canvas, rect: rect, image: image, fit: BoxFit.fill, filterQuality: FilterQuality.high);
  } else if (f.plan.rooms.isNotEmpty) {
    FloorPlanPainter(f.plan.rooms).paint(canvas, size);
  } else {
    canvas.drawRect(rect, Paint()..color = const Color(0xFFEEEEEE));
  }

  final field = m.fieldFor(floor, band: band);
  canvas.saveLayer(rect, Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: 9 * k, sigmaY: 9 * k, tileMode: TileMode.decal));
  HeatmapPainter(field, max(m.heatOpacity, 0.55), cell: 6 * k).paint(canvas, size);
  canvas.restore();

  for (final w in f.userWalls) {
    canvas.drawLine(
      Offset(w.a.dx * size.width, w.a.dy * size.height),
      Offset(w.b.dx * size.width, w.b.dy * size.height),
      Paint()
        ..color = w.color
        ..strokeWidth = 2.6 * k
        ..strokeCap = StrokeCap.round,
    );
  }

  // Roteadores numerados (a numeração é a mesma da tabela do laudo).
  for (var i = 0; i < m.routers.length; i++) {
    final r = m.routers[i];
    if (r.floor != floor) continue;
    final pos = Offset(r.frac.dx * size.width, r.frac.dy * size.height);
    final radius = 18 * k;
    canvas.save();
    canvas.translate(pos.dx - radius, pos.dy - radius);
    RouterDevicePainter(r.model).paint(canvas, Size(radius * 2, radius * 2));
    canvas.restore();
    final tp = TextPainter(
      text: TextSpan(
        text: 'R${i + 1}',
        style: TextStyle(color: Colors.white, fontSize: 11 * k, fontWeight: FontWeight.w800, backgroundColor: const Color(0xCC000000)),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(pos.dx - tp.width / 2, pos.dy + radius + 2 * k));
  }

  for (final p in m.points.where((p) => p.floor == floor)) {
    final v = field.at(p.frac);
    final pos = Offset(p.frac.dx * size.width, p.frac.dy * size.height);
    final r = 9 * k;
    canvas.save();
    canvas.translate(pos.dx - r, pos.dy - r);
    PointMarkerPainter(
      label: '${p.name} · ${v.round()} dBm',
      color: _signalClassColor(v),
      measured: p.measured != null,
      zoom: 1 / k,
    ).paint(canvas, Size(r * 2, r * 2));
    canvas.restore();
  }

  // Barra de escala (usa a largura real calibrada).
  const nice = [1.0, 2.0, 5.0, 10.0, 20.0, 50.0, 100.0];
  var len = nice.first;
  for (final n in nice) {
    if (n <= f.widthM * 0.3) len = n;
  }
  final barPx = len / f.widthM * size.width;
  final bx = 14 * k, by = size.height - 22 * k;
  canvas.drawRect(Rect.fromLTWH(bx - 4 * k, by - 16 * k, barPx + 8 * k, 30 * k), Paint()..color = const Color(0xCCFFFFFF));
  canvas.drawRect(Rect.fromLTWH(bx, by, barPx, 4 * k), Paint()..color = Colors.black);
  final st = TextPainter(
    text: TextSpan(
      text: '${len.toStringAsFixed(len % 1 == 0 ? 0 : 1)} m',
      style: TextStyle(color: Colors.black, fontSize: 10 * k, fontWeight: FontWeight.w700),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  st.paint(canvas, Offset(bx, by - st.height - 1 * k));

  final raster = await recorder.endRecording().toImage(size.width.round(), size.height.round());
  final data = await raster.toByteData(format: ui.ImageByteFormat.rawRgba);
  final rgba = data!.buffer.asUint8List();
  final encoded = im.encodeJpg(
    im.Image.fromBytes(width: raster.width, height: raster.height, bytes: rgba.buffer, numChannels: 4, order: im.ChannelOrder.rgba),
    quality: 88,
  );
  final out = FloorRaster(Uint8List.fromList(encoded), raster.width, raster.height);
  raster.dispose();
  image?.dispose();
  return out;
}

class LaudoPdf {
  static const PdfColor _primary = PdfColor.fromInt(0xFF1E3A8A);
  static const PdfColor _muted = PdfColor.fromInt(0xFF475569);
  static const PdfColor _line = PdfColor.fromInt(0xFFCBD5E1);
  static const PdfColor _headBg = PdfColor.fromInt(0xFFE2E8F0);

  static PdfColor _pdfColor(Color c) => PdfColor(c.r, c.g, c.b);

  static Future<Uint8List> build(NetworkModel m, {required List<RfBand> bands}) async {
    final regular = pw.Font.ttf(await rootBundle.load('assets/fonts/Roboto-Regular.ttf'));
    final bold = pw.Font.ttf(await rootBundle.load('assets/fonts/Roboto-Bold.ttf'));
    final italic = pw.Font.ttf(await rootBundle.load('assets/fonts/Roboto-Italic.ttf'));
    final r = m.report;
    final date = r.date ?? DateTime.now();

    pw.MemoryImage? logo;
    if (r.logo != null) {
      try {
        logo = pw.MemoryImage(r.logo!);
      } catch (_) {}
    }
    pw.MemoryImage? signature;
    if (r.signature != null) {
      try {
        signature = pw.MemoryImage(r.signature!);
      } catch (_) {}
    }

    // Mapas de calor: um por pavimento e banda.
    final maps = <({int floor, RfBand band, pw.MemoryImage image, CoverageStats stats})>[];
    for (final b in bands) {
      for (var i = 0; i < m.floors.length; i++) {
        final raster = await renderFloorRaster(m, i, b);
        maps.add((
          floor: i,
          band: b,
          image: pw.MemoryImage(raster.jpeg),
          stats: computeCoverage(m.fieldFor(i, band: b)),
        ));
      }
    }

    final doc = pw.Document(
      title: 'Laudo de Vistoria Wi-Fi — ${r.client.isEmpty ? m.workspaceName : r.client}',
      author: r.technician.isEmpty ? (r.company.isEmpty ? kAppName : r.company) : r.technician,
      creator: '$kAppName $kAppVersion',
      subject: 'Laudo de vistoria de cobertura Wi-Fi',
    );
    final theme = pw.ThemeData.withFont(base: regular, bold: bold, italic: italic);

    pw.TextStyle st({double size = 10, bool b = false, PdfColor? color, bool i = false}) => pw.TextStyle(
          fontSize: size,
          fontWeight: b ? pw.FontWeight.bold : pw.FontWeight.normal,
          fontStyle: i ? pw.FontStyle.italic : pw.FontStyle.normal,
          color: color ?? PdfColors.black,
        );

    pw.Widget h2(String t) => pw.Padding(
          padding: const pw.EdgeInsets.only(top: 14, bottom: 6),
          child: pw.Text(t, style: st(size: 13, b: true, color: _primary)),
        );

    pw.Widget kv(String k, String v) => pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 3),
          child: pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.SizedBox(width: 92, child: pw.Text(k, style: st(size: 9.5, color: _muted))),
              pw.Expanded(child: pw.Text(v.isEmpty ? '—' : v, style: st(size: 10.5, b: true))),
            ],
          ),
        );

    pw.Widget table(List<String> headers, List<List<String>> rows, {List<double>? widths}) {
      return pw.TableHelper.fromTextArray(
        headers: headers,
        data: rows,
        headerStyle: st(size: 8.5, b: true),
        cellStyle: st(size: 8.5),
        headerDecoration: const pw.BoxDecoration(color: _headBg),
        border: const pw.TableBorder(
          horizontalInside: pw.BorderSide(color: _line, width: 0.5),
          bottom: pw.BorderSide(color: _line, width: 0.5),
          top: pw.BorderSide(color: _line, width: 0.5),
        ),
        cellPadding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        columnWidths: widths == null ? null : {for (var i = 0; i < widths.length; i++) i: pw.FlexColumnWidth(widths[i])},
        cellAlignment: pw.Alignment.centerLeft,
        headerAlignment: pw.Alignment.centerLeft,
      );
    }

    String db(double v) => v < -500 ? '—' : v.toStringAsFixed(1);
    String ms(double? v, {int d = 1}) => v == null ? '—' : v.toStringAsFixed(d);

    // Legenda detalhada de dBm: faixa contínua + classes.
    pw.Widget legend() {
      final ticks = [-30.0, -20.0, -10.0, 0.0, 10.0, 20.0, 26.0];
      const steps = 56;
      return pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text('Legenda — nível de sinal simulado (dBm)', style: st(size: 9, b: true)),
          pw.SizedBox(height: 4),
          pw.Row(
            children: [
              for (var i = 0; i < steps; i++)
                pw.Expanded(child: pw.Container(height: 10, color: _pdfColor(_jetColor(i / (steps - 1))))),
            ],
          ),
          pw.SizedBox(height: 2),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [for (final t in ticks) pw.Text(t.toStringAsFixed(0), style: st(size: 7.5, color: _muted))],
          ),
          pw.SizedBox(height: 6),
          pw.Row(
            children: [
              for (final c in [
                (const Color(0xFFEF4444), 'Forte: ≥ ${kStrongDbm.round()} dBm'),
                (const Color(0xFFFACC15), 'Intermediário: ${kWeakDbm.round()} a ${kStrongDbm.round()} dBm'),
                (const Color(0xFF2563EB), 'Ruim: < ${kWeakDbm.round()} dBm'),
              ]) ...[
                pw.Container(width: 9, height: 9, color: _pdfColor(c.$1)),
                pw.SizedBox(width: 4),
                pw.Text(c.$2, style: st(size: 8)),
                pw.SizedBox(width: 12),
              ],
            ],
          ),
        ],
      );
    }

    String floorName(int i) => m.floors[i].label;

    final anySimulated = m.logs.any((l) => !l.native);
    final allCalibrated = m.floors.every((f) => f.calibrated);

    // Linhas da tabela de pontos: previsão (banda atual do projeto) + medição.
    String status(double predicted, Measurement? me) {
      var critical = predicted > -500 && predicted < kWeakDbm;
      var attention = predicted > -500 && predicted < kStrongDbm;
      if (me != null) {
        if (me.rssi <= -75 || me.netLossPct >= 5 || (me.gwAvgMs ?? 0) > 30) critical = true;
        if (me.rssi <= -67 || me.netLossPct > 0 || (me.gwAvgMs ?? 0) > 15) attention = true;
      }
      return critical ? 'CRÍTICO' : (attention ? 'Atenção' : 'OK');
    }

    final pointRows = <List<String>>[];
    var criticalCount = 0;
    for (final p in m.points) {
      final v = m.fieldFor(p.floor).at(p.frac);
      final me = p.measured;
      final s = status(v, me);
      if (s == 'CRÍTICO') criticalCount++;
      pointRows.add([
        p.name,
        floorName(p.floor),
        db(v),
        v < -500 ? '—' : signalClassLabel(v),
        me == null ? '—' : '${me.rssi}',
        me == null ? '—' : '${me.linkMbps}',
        me == null ? '—' : ms(me.gwAvgMs),
        me == null ? '—' : ms(me.netAvgMs, d: 0),
        me == null ? '—' : '${me.netLossPct.toStringAsFixed(0)}%',
        s,
      ]);
    }

    // ---- Página 1 (+): capa e resumo ----
    doc.addPage(
      pw.MultiPage(
        pageTheme: pw.PageTheme(pageFormat: PdfPageFormat.a4, margin: const pw.EdgeInsets.fromLTRB(36, 34, 36, 40), theme: theme),
        footer: (ctx) => pw.Container(
          alignment: pw.Alignment.centerRight,
          padding: const pw.EdgeInsets.only(top: 6),
          decoration: const pw.BoxDecoration(border: pw.Border(top: pw.BorderSide(color: _line, width: 0.5))),
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text('Laudo de vistoria Wi-Fi · gerado pelo $kAppName $kAppVersion', style: st(size: 8, color: _muted)),
              pw.Text('Página ${ctx.pageNumber} de ${ctx.pagesCount}', style: st(size: 8, color: _muted)),
            ],
          ),
        ),
        build: (ctx) => [
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: [
              if (logo != null)
                pw.Container(
                  width: 110,
                  height: 56,
                  alignment: pw.Alignment.centerLeft,
                  child: pw.Image(logo, fit: pw.BoxFit.contain),
                ),
              pw.Expanded(
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.end,
                  children: [
                    pw.Text(r.company.isEmpty ? 'Vistoria técnica de rede' : r.company, style: st(size: 13, b: true)),
                    if (r.technician.isNotEmpty) pw.Text('Técnico: ${r.technician}', style: st(size: 9.5, color: _muted)),
                    pw.Text(_fmtDate(date), style: st(size: 9.5, color: _muted)),
                  ],
                ),
              ),
            ],
          ),
          pw.SizedBox(height: 18),
          pw.Container(
            width: double.infinity,
            padding: const pw.EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            decoration: const pw.BoxDecoration(color: _primary, borderRadius: pw.BorderRadius.all(pw.Radius.circular(6))),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text('LAUDO DE VISTORIA', style: st(size: 20, b: true, color: PdfColors.white)),
                pw.SizedBox(height: 2),
                pw.Text('Cobertura e desempenho Wi-Fi', style: st(size: 11, color: PdfColors.white)),
              ],
            ),
          ),
          h2('Identificação'),
          kv('Cliente', r.client),
          kv('Endereço', r.address),
          kv('Data da vistoria', _fmtDate(date)),
          kv('Responsável', r.technician),
          kv('Empresa', r.company),
          kv('Projeto', m.workspaceName),
          h2('Resumo da simulação'),
          kv('Pavimentos', '${m.floors.length} (${[for (var i = 0; i < m.floors.length; i++) floorName(i)].join(', ')})'),
          kv('Roteadores', '${m.routers.length}'),
          kv('Bandas simuladas', bands.map((b) => rfBandSpec(b).label).join(', ')),
          kv('Escala', allCalibrated ? 'Calibrada com régua em todos os pavimentos' : 'Parcialmente estimada (não calibrada em todos os pavimentos)'),
          kv('Pontos de medição', '${m.points.length}  (críticos: $criticalCount)'),
          kv('Medições de campo', '${m.logs.length}'),
          h2('Roteadores / pontos de acesso'),
          m.routers.isEmpty
              ? pw.Text('Nenhum roteador posicionado.', style: st())
              : table(
                  ['#', 'Modelo', 'Pavimento', 'Potência (dBm)', 'Posição na planta (m)'],
                  [
                    for (var i = 0; i < m.routers.length; i++)
                      [
                        'R${i + 1}',
                        _specFor(m.routers[i].model).name,
                        floorName(m.routers[i].floor),
                        _specFor(m.routers[i].model).txPowerDbm.toStringAsFixed(0),
                        () {
                          final f = m.floors[m.routers[i].floor];
                          return 'x ${(m.routers[i].frac.dx * f.widthM).toStringAsFixed(1)} · y ${(m.routers[i].frac.dy * f.heightM).toStringAsFixed(1)}';
                        }(),
                      ],
                  ],
                  widths: [0.6, 3.2, 1.6, 1.4, 2.2],
                ),
        ],
      ),
    );

    // ---- Mapas de calor (uma página por pavimento e banda) ----
    for (final mp in maps) {
      final spec = rfBandSpec(mp.band);
      final f = m.floors[mp.floor];
      doc.addPage(
        pw.Page(
          pageTheme: pw.PageTheme(pageFormat: PdfPageFormat.a4, margin: const pw.EdgeInsets.fromLTRB(36, 34, 36, 40), theme: theme),
          build: (ctx) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text('Mapa de calor — ${floorName(mp.floor)} · ${spec.label}', style: st(size: 15, b: true, color: _primary)),
              pw.SizedBox(height: 2),
              pw.Text(
                'Planta: ${f.plan.name} · largura ${f.widthM.toStringAsFixed(1)} m${f.calibrated ? ' (calibrada)' : ' (estimada)'}'
                '${mp.band == RfBand.ghz24 ? '' : ' · 5/6 GHz: paredes ×${spec.wallFactor.toStringAsFixed(2)} e alcance menor'}',
                style: st(size: 9, color: _muted),
              ),
              pw.SizedBox(height: 8),
              pw.Expanded(
                child: pw.Container(
                  decoration: pw.BoxDecoration(border: pw.Border.all(color: _line, width: 0.8)),
                  child: pw.Center(child: pw.Image(mp.image, fit: pw.BoxFit.contain)),
                ),
              ),
              pw.SizedBox(height: 8),
              legend(),
              pw.SizedBox(height: 6),
              pw.Text(
                'Cobertura do pavimento: Forte ${mp.stats.strongPct.toStringAsFixed(0)}% · '
                'Intermediária ${mp.stats.midPct.toStringAsFixed(0)}% · Ruim ${mp.stats.weakPct.toStringAsFixed(0)}% · '
                'pior ponto ${mp.stats.worstDbm.toStringAsFixed(1)} dBm '
                '(x ${(mp.stats.worstFrac.dx * f.widthM).toStringAsFixed(1)} m, y ${(mp.stats.worstFrac.dy * f.heightM).toStringAsFixed(1)} m).',
                style: st(size: 9, b: true),
              ),
            ],
          ),
        ),
      );
    }

    // ---- Diagnóstico: pontos críticos, cobertura e medições ----
    doc.addPage(
      pw.MultiPage(
        pageTheme: pw.PageTheme(pageFormat: PdfPageFormat.a4, margin: const pw.EdgeInsets.fromLTRB(36, 34, 36, 40), theme: theme),
        footer: (ctx) => pw.Container(
          alignment: pw.Alignment.centerRight,
          padding: const pw.EdgeInsets.only(top: 6),
          decoration: const pw.BoxDecoration(border: pw.Border(top: pw.BorderSide(color: _line, width: 0.5))),
          child: pw.Text('Laudo de vistoria Wi-Fi · $kAppName $kAppVersion', style: st(size: 8, color: _muted)),
        ),
        build: (ctx) => [
          pw.Text('Diagnóstico e pontos críticos', style: st(size: 15, b: true, color: _primary)),
          h2('Cobertura por pavimento e banda (simulada)'),
          table(
            ['Pavimento', 'Banda', 'Forte', 'Interm.', 'Ruim', 'Pior ponto (dBm)'],
            [
              for (final mp in maps)
                [
                  floorName(mp.floor),
                  rfBandSpec(mp.band).label,
                  '${mp.stats.strongPct.toStringAsFixed(0)}%',
                  '${mp.stats.midPct.toStringAsFixed(0)}%',
                  '${mp.stats.weakPct.toStringAsFixed(0)}%',
                  '${mp.stats.worstDbm.toStringAsFixed(1)} @ (${(mp.stats.worstFrac.dx * m.floors[mp.floor].widthM).toStringAsFixed(1)} m, '
                      '${(mp.stats.worstFrac.dy * m.floors[mp.floor].heightM).toStringAsFixed(1)} m)',
                ],
            ],
            widths: [1.6, 1.0, 0.9, 0.9, 0.9, 3.0],
          ),
          h2('Pontos de medição — previsto × medido'),
          pointRows.isEmpty
              ? pw.Text('Nenhum ponto de medição foi marcado neste projeto.', style: st())
              : table(
                  ['Ponto', 'Pav.', 'Simul. (dBm)', 'Classe', 'RSSI (dBm)', 'PHY (Mbps)', 'Ping GW (ms)', 'Ping Net (ms)', 'Perda', 'Status'],
                  pointRows,
                  widths: [1.5, 1.2, 1.1, 1.3, 1.0, 1.0, 1.1, 1.1, 0.9, 1.1],
                ),
          pw.SizedBox(height: 6),
          pw.Text(
            'Nota: "Simul. (dBm)" é o nível estimado pelo simulador na banda do projeto (${rfBandSpec(m.band).label}), em escala relativa '
            '(potência de transmissão menos perdas). "RSSI" é o nível efetivamente recebido pelo aparelho de medição. '
            'Os dois valores não devem ser comparados numericamente. Status: CRÍTICO = classe Ruim, RSSI ≤ −75 dBm, perda ≥ 5% ou ping ao gateway > 30 ms; '
            'Atenção = classe Intermediária, RSSI ≤ −67 dBm, alguma perda ou ping ao gateway > 15 ms.',
            style: st(size: 8, i: true, color: _muted),
          ),
          if (anySimulated)
            pw.Padding(
              padding: const pw.EdgeInsets.only(top: 6),
              child: pw.Text(
                'ATENÇÃO: há medições marcadas como simuladas (coletadas fora do aplicativo Android WaveLens Shell). '
                'Elas não representam a rede real do cliente.',
                style: st(size: 8.5, b: true, color: const PdfColor.fromInt(0xFFB91C1C)),
              ),
            ),
          if (m.logs.isNotEmpty) ...[
            h2('Registro de diagnósticos de campo (${m.logs.length})'),
            table(
              ['Data/hora', 'Ponto', 'Origem', 'Rede', 'Banda/canal', 'RSSI', 'PHY', 'GW ms', 'Net ms', 'Perda'],
              [
                for (final l in m.logs)
                  [
                    _fmtDateTime(l.time),
                    l.pointName ?? '—',
                    l.native ? 'real' : 'simulado',
                    l.ssid.isEmpty ? '—' : l.ssid,
                    '${l.bandLabel} · c${l.channel}',
                    '${l.rssi}',
                    '${l.linkMbps}',
                    ms(l.gwAvgMs),
                    ms(l.netAvgMs, d: 0),
                    '${l.netLossPct.toStringAsFixed(0)}%',
                  ],
              ],
              widths: [1.7, 1.2, 0.9, 1.5, 1.4, 0.8, 0.8, 0.8, 0.8, 0.8],
            ),
          ],
          h2('Observações do técnico'),
          pw.Container(
            width: double.infinity,
            padding: const pw.EdgeInsets.all(8),
            decoration: pw.BoxDecoration(border: pw.Border.all(color: _line, width: 0.8)),
            child: pw.Text(r.notes.trim().isEmpty ? 'Sem observações.' : r.notes.trim(), style: st(size: 10)),
          ),
          pw.SizedBox(height: 26),
          pw.Wrap(
            children: [
              pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  pw.Expanded(
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.SizedBox(height: 62),
                        pw.Container(height: 0.8, color: PdfColors.black),
                        pw.SizedBox(height: 3),
                        pw.Text(r.technician.isEmpty ? 'Técnico responsável' : r.technician, style: st(size: 9.5, b: true)),
                        pw.Text(
                          r.technician.isEmpty ? 'Assinatura do técnico' : (r.company.isEmpty ? 'Técnico responsável' : r.company),
                          style: st(size: 8.5, color: _muted),
                        ),
                      ],
                    ),
                  ),
                  pw.SizedBox(width: 30),
                  pw.Expanded(
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Container(
                          height: 62,
                          alignment: pw.Alignment.bottomLeft,
                          child: signature == null ? pw.SizedBox() : pw.Image(signature, fit: pw.BoxFit.contain),
                        ),
                        pw.Container(height: 0.8, color: PdfColors.black),
                        pw.SizedBox(height: 3),
                        pw.Text(
                          r.signerName.trim().isEmpty ? (r.client.isEmpty ? 'Cliente' : r.client) : r.signerName.trim(),
                          style: st(size: 9.5, b: true),
                        ),
                        pw.Text(
                          r.signedAt == null ? 'Assinatura do cliente' : 'Assinado digitalmente em ${_fmtDateTime(r.signedAt!)}',
                          style: st(size: 8.5, color: _muted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );

    return doc.save();
  }
}
