// NetFloor v7.0 — simulador de mapa de calor Wi-Fi 2.5D (vários pavimentos) + NetFloor Diagnostic.
//
// pubspec.yaml (dependências necessárias):
//
//   dependencies:
//     flutter:
//       sdk: flutter
//     file_picker: ^13.1.0   # upload de plantas em memória (bytes), sem dart:io
//     fl_chart: ^1.2.0       # gráficos de linha (sinal e latência)
//
//   flutter:
//     uses-material-design: true
//     assets:
//       - assets/floorplans/  # casa_2q.png, sobrado_1andar.png (+ sobrado_terreo.png e edificio_corporativo.png quando existirem)
//
// Este arquivo compila para Flutter Web/PWA (usa dart:js_interop). Os recursos
// nativos do Android (varredura Wi-Fi, RSSI, ping) chegam pela ponte JS
// `NetFloorNative`, exposta pelo app NetFloor Shell (WebView). Fora do Shell
// (navegador comum / PWA), a aba Diagnóstico roda em modo simulação.

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

void main() => runApp(const NetFloorApp());

class NetFloorApp extends StatelessWidget {
  const NetFloorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NetFloor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const NetFloorShell(),
    );
  }
}

/// Navegação principal: Simulador (mapa de calor) e Diagnóstico (Wi-Fi).
class NetFloorShell extends StatefulWidget {
  const NetFloorShell({super.key});

  @override
  State<NetFloorShell> createState() => _NetFloorShellState();
}

class _NetFloorShellState extends State<NetFloorShell> {
  final DiagnosticsController _diag = DiagnosticsController();
  int _index = 0;

  @override
  void dispose() {
    _diag.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          TickerMode(enabled: _index == 0, child: const SimulatorPage()),
          TickerMode(enabled: _index == 1, child: DiagnosticPage(controller: _diag, active: _index == 1)),
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

enum RouterModelType { huaweiAx3, tplinkDeco, unifiAp }

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

class WallSegment {
  final Offset a; // coordenadas fracionárias (0..1)
  final Offset b;
  final double attenuationDb; // perda de sinal ao atravessar esta parede
  const WallSegment(this.a, this.b, {this.attenuationDb = 6.0});
}

class FloorPlanDef {
  final String id;
  final String name;
  final String subtitle;
  final String? imageUrl; // imagem remota (Image.network), se disponível
  final String? assetPath; // asset local: fallback da imagem remota, ou única fonte
  final Uint8List? memoryBytes; // planta enviada pelo usuário (Image.memory)
  final double aspectRatio;
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

// Térreo do sobrado: sem imagem ainda (assets/floorplans/sobrado_terreo.png).
// Enquanto o PNG não existir, o app desenha esta versão vetorial.
const FloorPlanDef kPlanSobradoTerreo = FloorPlanDef(
  id: 'sobrado_terreo',
  name: 'Sobrado — Térreo',
  subtitle: 'Garagem · Salas · Cozinha · Varanda',
  assetPath: 'assets/floorplans/sobrado_terreo.png',
  aspectRatio: 940 / 1496,
  rooms: [
    RoomDef('Varanda', Rect.fromLTWH(0.00, 0.00, 1.00, 0.16)),
    RoomDef('Sala de Jantar', Rect.fromLTWH(0.00, 0.16, 0.50, 0.28)),
    RoomDef('Cozinha', Rect.fromLTWH(0.50, 0.16, 0.50, 0.28)),
    RoomDef('Sala de TV', Rect.fromLTWH(0.00, 0.44, 0.48, 0.32)),
    RoomDef('Lavabo', Rect.fromLTWH(0.48, 0.44, 0.20, 0.14)),
    RoomDef('Despensa', Rect.fromLTWH(0.68, 0.44, 0.32, 0.14)),
    RoomDef('Garagem', Rect.fromLTWH(0.48, 0.58, 0.52, 0.42)),
    RoomDef('Hall', Rect.fromLTWH(0.00, 0.76, 0.48, 0.24)),
  ],
  wallSegments: [
    WallSegment(Offset(0.00, 0.16), Offset(1.00, 0.16)),
    WallSegment(Offset(0.48, 0.44), Offset(0.48, 1.00)),
    WallSegment(Offset(0.48, 0.58), Offset(1.00, 0.58)),
    WallSegment(Offset(0.68, 0.44), Offset(0.68, 0.58)),
    WallSegment(Offset(0.00, 0.76), Offset(0.48, 0.76)),
  ],
);

const FloorPlanDef kPlanSobrado1Andar = FloorPlanDef(
  id: 'sobrado_1andar',
  name: 'Sobrado — 1º Andar',
  subtitle: 'Área íntima · 3 Quartos · Banheiro',
  imageUrl: '$kGitHubRawBase/sobrado_1andar.png',
  assetPath: 'assets/floorplans/sobrado_1andar.png',
  aspectRatio: 940 / 1496,
  // Imagem em perspectiva 3D: as paredes abaixo são só uma aproximação.
  wallSegments: [
    WallSegment(Offset(0.595, 0.23), Offset(0.595, 0.555)),
    WallSegment(Offset(0.60, 0.39), Offset(0.95, 0.39)),
    WallSegment(Offset(0.60, 0.555), Offset(0.95, 0.555)),
    WallSegment(Offset(0.52, 0.555), Offset(0.52, 0.70)),
    WallSegment(Offset(0.44, 0.23), Offset(0.44, 0.41)),
  ],
);

// Prédio/escritório: sem imagem ainda (assets/floorplans/edificio_corporativo.png).
const FloorPlanDef kPlanEscritorio = FloorPlanDef(
  id: 'edificio_corporativo',
  name: 'Edifício Corporativo',
  subtitle: 'Open Space · Sala de Reunião · Diretoria · Copa',
  assetPath: 'assets/floorplans/edificio_corporativo.png',
  aspectRatio: 1.6,
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
    id: 'sobrado',
    name: 'Sobrado (2 pavimentos)',
    subtitle: 'Térreo: garagem e salas · 1º Andar: área íntima',
    floors: [FloorDef('Térreo', kPlanSobradoTerreo), FloorDef('1º Andar', kPlanSobrado1Andar)],
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

/// Estado do simulador (projeto, pavimentos e roteadores). Usa ChangeNotifier
/// para que só o CustomPainter do mapa de calor seja re-renderizado durante o
/// arraste, sem reconstruir toda a árvore de widgets.
class NetworkModel extends ChangeNotifier {
  final List<ProjectDef> customProjects = [];
  ProjectDef currentProject = kProjectLibrary[0];
  List<FloorDef> floors = [...kProjectLibrary[0].floors];
  int floorIndex = 0;
  RouterModelType selectedModel = RouterModelType.huaweiAx3;
  double heatOpacity = kDefaultHeatOpacity;
  final List<RouterNode> routers = [];
  int _counter = 0;

  List<ProjectDef> get library => [...kProjectLibrary, ...customProjects];
  FloorPlanDef get currentPlan => floors[floorIndex].plan;
  List<RouterNode> get routersOnFloor => routers.where((r) => r.floor == floorIndex).toList();

  void setProject(ProjectDef project) {
    currentProject = project;
    floors = [...project.floors];
    floorIndex = 0;
    routers.clear();
    notifyListeners();
  }

  void addCustomProject(ProjectDef project) {
    customProjects.add(project);
    setProject(project);
  }

  void setFloor(int index) {
    if (index < 0 || index >= floors.length || index == floorIndex) return;
    floorIndex = index;
    notifyListeners();
  }

  /// Acrescenta pavimentos ao projeto atual e passa a mostrar o primeiro deles.
  void addFloors(List<FloorDef> extra) {
    if (extra.isEmpty) return;
    floors = [...floors, ...extra];
    floorIndex = floors.length - extra.length;
    notifyListeners();
  }

  void setHeatOpacity(double value) {
    heatOpacity = value;
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

  void clear() {
    if (routers.isEmpty) return;
    routers.clear();
    notifyListeners();
  }
}

// ---------------------------------------------------------------------------
// Modelo de propagação de sinal (2.5D)
//
//   Sinal(x,y) = max_i ( Ptx_i - 22*log10(d3D_i) - perda de paredes - perda de lajes )
//   d3D = sqrt(dx² + dy² + (Δandares · altura do piso)²)
//   perda de lajes = 15 dB por andar atravessado
//
// Os pavimentos são empilhados sobre a mesma pegada (mesma posição fracionária
// x,y em cada andar). As paredes usadas são as do pavimento exibido.
// ---------------------------------------------------------------------------

const double kPixelsPerMeter = 45.0; // escala visual da planta
const double kFloorHeightM = 3.0; // altura entre pisos
const double kSlabLossDb = 15.0; // laje de concreto, por andar

/// Teste de interseção entre dois segmentos de reta (caso geral).
bool _segmentsIntersect(Offset p1, Offset p2, Offset p3, Offset p4) {
  double orient(Offset a, Offset b, Offset c) => (b.dx - a.dx) * (c.dy - a.dy) - (b.dy - a.dy) * (c.dx - a.dx);
  final o1 = orient(p1, p2, p3);
  final o2 = orient(p1, p2, p4);
  final o3 = orient(p3, p4, p1);
  final o4 = orient(p3, p4, p2);
  return ((o1 > 0) != (o2 > 0)) && ((o3 > 0) != (o4 > 0));
}

/// Uma parede já convertida para coordenadas de pixel do canvas atual.
class _PixelWall {
  final Offset a;
  final Offset b;
  final double attenuationDb;
  const _PixelWall(this.a, this.b, this.attenuationDb);
}

/// Soma a atenuação (em dB) de todas as paredes cruzadas pelo raio entre
/// dois pontos — o "ray-casting" da física de sinal.
double _wallAttenuationBetween(Offset from, Offset to, List<_PixelWall> wallsPx) {
  double total = 0;
  for (final w in wallsPx) {
    if (_segmentsIntersect(from, to, w.a, w.b)) {
      total += w.attenuationDb;
    }
  }
  return total;
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

double _dbmAtT(double t) => _kDbmFloor + t * (_kDbmCeil - _kDbmFloor);

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
    return l.contains('banheiro') || l.contains('lavabo') || l.contains('cozinha') || l.contains('copa');
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
  final List<RouterNode> routers;
  final List<WallSegment> walls;
  final double maxAlpha;
  final int floorIndex; // pavimento exibido
  HeatmapPainter(this.routers, this.walls, this.maxAlpha, this.floorIndex);

  // Amostragem em grade: equilíbrio entre qualidade visual e performance.
  // A grade é depois suavizada com um blur (ver ImageFiltered no build).
  static const double _cell = 8.0;

  final Paint _cellPaint = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    if (routers.isEmpty) return;

    final wallsPx = walls
        .map((w) => _PixelWall(
              Offset(w.a.dx * size.width, w.a.dy * size.height),
              Offset(w.b.dx * size.width, w.b.dy * size.height),
              w.attenuationDb,
            ))
        .toList(growable: false);

    // Pré-calcula, por roteador: posição em pixels, potência e andares de distância.
    final positions = [for (final r in routers) Offset(r.frac.dx * size.width, r.frac.dy * size.height)];
    final powers = [for (final r in routers) _specFor(r.model).txPowerDbm];
    final floorGaps = [for (final r in routers) (r.floor - floorIndex).abs()];

    for (double y = 0; y < size.height; y += _cell) {
      final h = min(_cell, size.height - y);
      for (double x = 0; x < size.width; x += _cell) {
        final w = min(_cell, size.width - x);
        final center = Offset(x + w / 2, y + h / 2);

        double best = -1000.0;
        for (var i = 0; i < positions.length; i++) {
          final dxy = (center - positions[i]).distance;
          final dz = floorGaps[i] * kFloorHeightM * kPixelsPerMeter;
          final distM = max(sqrt(dxy * dxy + dz * dz) / kPixelsPerMeter, 1.0);
          final v = powers[i] -
              22 * (log(distM) / ln10) -
              _wallAttenuationBetween(center, positions[i], wallsPx) -
              floorGaps[i] * kSlabLossDb;
          if (v > best) best = v;
        }

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
// Pintura: pulso de frequência saindo do roteador (efeito "radar")
// ---------------------------------------------------------------------------

class RadarPingPainter extends CustomPainter {
  final List<RouterNode> routers; // só os do pavimento exibido
  final double t; // progresso da animação, 0..1, em loop
  RadarPingPainter(this.routers, this.t);

  static const double _minRadius = 15.0;
  static const double _maxRadius = 48.0;

  void _ring(Canvas canvas, Offset center, double localT) {
    final radius = _minRadius + (_maxRadius - _minRadius) * localT;
    final opacity = (1 - localT).clamp(0.0, 1.0) * 0.55;
    if (opacity <= 0.01) return;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = Colors.white.withOpacity(opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
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
    }
  }

  @override
  bool shouldRepaint(covariant RouterDevicePainter oldDelegate) => oldDelegate.model != model;
}

// ---------------------------------------------------------------------------
// Tela do simulador
// ---------------------------------------------------------------------------

class SimulatorPage extends StatefulWidget {
  const SimulatorPage({super.key});

  @override
  State<SimulatorPage> createState() => _SimulatorPageState();
}

class _SimulatorPageState extends State<SimulatorPage> with SingleTickerProviderStateMixin {
  final NetworkModel _model = NetworkModel();
  late final AnimationController _pingController;
  static const double _markerRadius = 20.0;
  static const String _uploadSentinel = 'upload';
  Size _lastCanvasSize = const Size(320, 320 / (736 / 1105));

  @override
  void initState() {
    super.initState();
    _pingController = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400))..repeat();
  }

  @override
  void dispose() {
    _pingController.dispose();
    _model.dispose();
    super.dispose();
  }

  // Posições dos roteadores são frações (0..1) do pavimento; aqui convertemos
  // de/para pixels do canvas atual.
  Offset _toPx(Offset frac, Size b) => Offset(frac.dx * b.width, frac.dy * b.height);

  Offset _clampFrac(Offset frac, Size b) {
    if (b.width <= 0 || b.height <= 0) return frac;
    final mx = _markerRadius / b.width;
    final my = _markerRadius / b.height;
    return Offset(
      frac.dx.clamp(mx, max(mx, 1 - mx)).toDouble(),
      frac.dy.clamp(my, max(my, 1 - my)).toDouble(),
    );
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

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
                trailing: _model.selectedModel == spec.type ? const Icon(Icons.check, color: Colors.indigo) : null,
                onTap: () => Navigator.pop(ctx, spec.type),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _showProjectLibrary() async {
    final selected = await showModalBottomSheet<Object>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Biblioteca de Plantas', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 12),
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                color: Theme.of(ctx).colorScheme.primaryContainer,
                child: ListTile(
                  leading: const Icon(Icons.upload_file, color: Colors.indigo),
                  title: const Text('Carregar plantas do dispositivo'),
                  subtitle: const Text('Uma ou várias imagens (PNG, JPG, WEBP): cada uma vira um pavimento'),
                  onTap: () => Navigator.pop(ctx, _uploadSentinel),
                ),
              ),
              for (final project in _model.library)
                Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: Icon(
                      project.isCustom
                          ? Icons.photo_library_outlined
                          : project.floors.length > 1
                              ? Icons.apartment
                              : Icons.house_outlined,
                      color: Colors.indigo,
                    ),
                    title: Text(project.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(project.subtitle),
                    trailing: _model.currentProject.id == project.id ? const Icon(Icons.check_circle, color: Colors.indigo) : null,
                    onTap: () => Navigator.pop(ctx, project),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (selected == _uploadSentinel) {
      await _uploadProject();
    } else if (selected is ProjectDef) {
      setState(() => _model.setProject(selected));
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
        subtitle: '${floors.length} pavimento(s) · enviado do dispositivo · sem paredes mapeadas',
        floors: floors,
        isCustom: true,
      );
      setState(() => _model.addCustomProject(project));
    } catch (e) {
      if (mounted) _snack('Não foi possível carregar a imagem: $e');
    }
  }

  Future<void> _addFloorsFromDevice() async {
    try {
      final floors = await _pickFloorsFromDevice(firstIndex: _model.floors.length);
      if (floors.isEmpty || !mounted) return;
      setState(() => _model.addFloors(floors));
    } catch (e) {
      if (mounted) _snack('Não foi possível carregar a imagem: $e');
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
                  const Text(
                    'Menos opacidade deixa a planta mais visível por baixo do sinal.',
                    style: TextStyle(fontSize: 12, color: Colors.black54),
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
    setState(() => _model.setSelectedModel(selected));
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wifi_tethering),
            SizedBox(width: 8),
            Text('NetFloor'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.opacity),
            tooltip: 'Opacidade do mapa de calor',
            onPressed: _showOpacitySheet,
          ),
          IconButton(
            icon: const Icon(Icons.layers_outlined),
            tooltip: 'Biblioteca de Plantas',
            onPressed: _showProjectLibrary,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _buildLegend(),
            AnimatedBuilder(animation: _model, builder: (context, _) => _buildFloorBar()),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Center(
                  child: AnimatedBuilder(
                    animation: _model,
                    builder: (context, _) {
                      return AspectRatio(
                        aspectRatio: _model.currentPlan.aspectRatio,
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            _lastCanvasSize = Size(constraints.maxWidth, constraints.maxHeight);
                            return ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: Container(
                                color: Colors.grey.shade100,
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTapUp: (details) {
                                    final size = _lastCanvasSize;
                                    final frac = Offset(
                                      details.localPosition.dx / size.width,
                                      details.localPosition.dy / size.height,
                                    );
                                    _model.addRouter(_clampFrac(frac, size));
                                  },
                                  child: Stack(
                                    children: [
                                      Positioned.fill(
                                        child: RepaintBoundary(
                                          child: _buildFloorPlanBackground(_model.currentPlan),
                                        ),
                                      ),
                                      Positioned.fill(
                                        child: ImageFiltered(
                                          imageFilter: ui.ImageFilter.blur(
                                            sigmaX: 9,
                                            sigmaY: 9,
                                            tileMode: TileMode.decal,
                                          ),
                                          child: CustomPaint(
                                            painter: HeatmapPainter(
                                              List.of(_model.routers),
                                              _model.currentPlan.wallSegments,
                                              _model.heatOpacity,
                                              _model.floorIndex,
                                            ),
                                          ),
                                        ),
                                      ),
                                      Positioned.fill(
                                        child: AnimatedBuilder(
                                          animation: _pingController,
                                          builder: (context, _) {
                                            return CustomPaint(
                                              painter: RadarPingPainter(_model.routersOnFloor, _pingController.value),
                                            );
                                          },
                                        ),
                                      ),
                                      for (final r in _model.routers.where((r) => r.floor != _model.floorIndex))
                                        _buildGhostMarker(r, _lastCanvasSize),
                                      for (final r in _model.routersOnFloor) _buildRouterMarker(r, _lastCanvasSize),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
            _buildActionBar(),
          ],
        ),
      ),
    );
  }

  /// Seletor de pavimento (térreo, 1º andar...) + botão para adicionar mais.
  Widget _buildFloorBar() {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (var i = 0; i < _model.floors.length; i++)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                label: Text(() {
                  final n = _model.routers.where((r) => r.floor == i).length;
                  return n == 0 ? _model.floors[i].label : '${_model.floors[i].label} · $n';
                }()),
                selected: i == _model.floorIndex,
                onSelected: (_) => _model.setFloor(i),
              ),
            ),
          ActionChip(
            avatar: const Icon(Icons.add, size: 18),
            label: const Text('Pavimento'),
            tooltip: 'Adicionar pavimento(s) a partir de imagens do dispositivo',
            onPressed: _addFloorsFromDevice,
          ),
        ],
      ),
    );
  }

  Widget _buildRouterMarker(RouterNode router, Size bounds) {
    final p = _toPx(router.frac, bounds);
    return Positioned(
      left: p.dx - _markerRadius,
      top: p.dy - _markerRadius,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {}, // absorve o toque para não "vazar" para o fundo e criar um roteador duplicado
        onPanUpdate: (details) {
          final delta = Offset(details.delta.dx / bounds.width, details.delta.dy / bounds.height);
          _model.moveRouter(router.id, _clampFrac(router.frac + delta, bounds));
        },
        child: SizedBox(
          width: _markerRadius * 2,
          height: _markerRadius * 2,
          child: CustomPaint(painter: RouterDevicePainter(router.model)),
        ),
      ),
    );
  }

  /// Roteador instalado em outro pavimento: aparece esmaecido, sem interação.
  Widget _buildGhostMarker(RouterNode router, Size bounds) {
    final p = _toPx(router.frac, bounds);
    return Positioned(
      left: p.dx - _markerRadius,
      top: p.dy - _markerRadius,
      child: IgnorePointer(
        child: Opacity(
          opacity: 0.55,
          child: SizedBox(
            width: _markerRadius * 2,
            height: _markerRadius * 2,
            child: CustomPaint(painter: RouterDevicePainter(router.model)),
          ),
        ),
      ),
    );
  }

  Widget _buildLegend() {
    Widget dot(Color c) => Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: c, shape: BoxShape.circle),
        );
    Widget item(Color c, String label) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [dot(c), const SizedBox(width: 6), Text(label, style: const TextStyle(fontSize: 12))],
        );

    final forte = _dbmAtT(0.75).round();
    final ruim = _dbmAtT(0.35).round();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Wrap(
        spacing: 16,
        runSpacing: 4,
        children: [
          item(_jetColor(1.0), 'Forte (≥ $forte dBm)'),
          item(_jetColor(0.55), 'Intermediário ($ruim a $forte dBm)'),
          item(_jetColor(0.15), 'Ruim (< $ruim dBm)'),
        ],
      ),
    );
  }

  Widget _buildActionBar() {
    final spec = _specFor(_model.selectedModel);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Column(
        children: [
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () async {
                final selected = await _pickModel();
                if (selected != null) setState(() => _model.setSelectedModel(selected));
              },
              icon: SizedBox(width: 20, height: 20, child: CustomPaint(painter: RouterDevicePainter(spec.type))),
              label: Text(
                'Modelo atual: ${spec.shortName} (${spec.txPowerDbm.toStringAsFixed(0)} dBm)',
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _handleAddViaButton,
                  icon: const Icon(Icons.add),
                  label: const Text('Adicionar Roteador'),
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: () => setState(() => _model.clear()),
                icon: const Icon(Icons.delete_outline),
                label: const Text('Limpar'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}


// ===========================================================================
// PARTE 2 — NETFLOOR DIAGNOSTIC (varredura de espectro, sinal e latência)
// ===========================================================================

// ---------------------------------------------------------------------------
// Ponte nativa (Android): disponível apenas dentro do NetFloor Shell, que
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

  int get channel => frequency >= 5000 ? (frequency - 5000) ~/ 5 : (frequency == 2484 ? 14 : (frequency - 2407) ~/ 5);
  String get bandLabel => frequency >= 5000 ? '5 GHz' : '2.4 GHz';
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
  const DiagnosticPage({super.key, required this.controller, required this.active});

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
            Text('NetFloor Diagnostic'),
          ],
        ),
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
                  : 'Modo simulação: dados fictícios. Abra o NetFloor no app Android (NetFloor Shell 3.0+) para a varredura real.',
              style: const TextStyle(fontSize: 12),
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
            Expanded(child: Text(message, style: const TextStyle(fontSize: 13))),
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
                style: const TextStyle(fontSize: 12, color: Colors.black54),
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
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(
              'Nenhuma rede retornada. Confirme que a Localização (GPS) está ativada; o Android também limita a frequência das varreduras.',
              style: TextStyle(fontSize: 12, color: Colors.black54),
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
            Text(label, style: const TextStyle(fontSize: 11, color: Colors.black54)),
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
    const head = TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.black54);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Saúde do canal', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            const SizedBox(height: 2),
            const Text(
              'Interferência estimada por canal de 20 MHz, contando só as redes vizinhas (a sua rede fica de fora).',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 10),
            const Text('Recomendados', style: head),
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
            const Row(
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
                    SizedBox(width: 70, child: Text('${h.freq}', style: const TextStyle(fontSize: 12, color: Colors.black54))),
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
                        style: const TextStyle(fontSize: 12, color: Colors.black54),
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
                  ? const Center(child: Text('Sem amostras ainda', style: TextStyle(color: Colors.black54)))
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
        const Text(
          'Caminhe pelo ambiente com o celular: as quedas no gráfico mostram onde o sinal enfraquece.',
          style: TextStyle(fontSize: 12, color: Colors.black54),
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
            Text(label, style: const TextStyle(fontSize: 11, color: Colors.black54)),
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
                      ? const Center(child: Text('Sem amostras ainda', style: TextStyle(color: Colors.black54)))
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
        const Text(
          'Compara a latência até o roteador (rede local) com a do DNS público: se só o DNS piora, o problema está fora de casa.',
          style: TextStyle(fontSize: 12, color: Colors.black54),
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
                    child: Text(title, style: const TextStyle(fontSize: 11, color: Colors.black54), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: color)),
              const SizedBox(height: 2),
              Text(subtitle, style: const TextStyle(fontSize: 11, color: Colors.black54), maxLines: 1, overflow: TextOverflow.ellipsis),
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
