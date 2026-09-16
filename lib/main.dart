import 'dart:math';
import 'dart:ui' as ui;
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
      home: const NetFloorHomePage(),
    );
  }
}

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
// Biblioteca de plantas baixas. A "Apartamento Compacto" usa a foto real
// enviada pelo usuário; as demais são desenhadas proceduralmente (sem foto
// de referência disponível).
// ---------------------------------------------------------------------------

enum FloorPlanRenderMode { image, drawn }

class RoomDef {
  final String label;
  final Rect rectFrac; // coordenadas fracionárias (0..1) relativas à planta
  const RoomDef(this.label, this.rectFrac);
}

class FloorPlanDef {
  final String id;
  final String name;
  final String subtitle;
  final FloorPlanRenderMode mode;
  final String? assetPath;
  final double aspectRatio;
  final List<RoomDef> rooms;
  const FloorPlanDef({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.mode,
    this.assetPath,
    required this.aspectRatio,
    this.rooms = const [],
  });
}

const String kApartmentAsset = 'assets/planta_casa.webp';

const List<FloorPlanDef> kFloorPlanLibrary = [
  FloorPlanDef(
    id: 'casa_standard',
    name: 'Casa Standard',
    subtitle: '2 Quartos · Sala · Cozinha · Banheiro',
    mode: FloorPlanRenderMode.drawn,
    aspectRatio: 1.35,
    rooms: [
      RoomDef('Quarto 1', Rect.fromLTWH(0.00, 0.00, 0.33, 0.50)),
      RoomDef('Quarto 2', Rect.fromLTWH(0.33, 0.00, 0.33, 0.50)),
      RoomDef('Banheiro', Rect.fromLTWH(0.66, 0.00, 0.34, 0.50)),
      RoomDef('Sala', Rect.fromLTWH(0.00, 0.50, 0.60, 0.50)),
      RoomDef('Cozinha', Rect.fromLTWH(0.60, 0.50, 0.40, 0.50)),
    ],
  ),
  FloorPlanDef(
    id: 'casa_sobrado',
    name: 'Casa Sobrado / Ampla',
    subtitle: '3 Quartos · Suíte · Sala Integrada · Varanda',
    mode: FloorPlanRenderMode.drawn,
    aspectRatio: 1.6,
    rooms: [
      RoomDef('Quarto 1', Rect.fromLTWH(0.00, 0.00, 0.25, 0.35)),
      RoomDef('Quarto 2', Rect.fromLTWH(0.25, 0.00, 0.25, 0.35)),
      RoomDef('Quarto 3', Rect.fromLTWH(0.50, 0.00, 0.25, 0.35)),
      RoomDef('Suíte', Rect.fromLTWH(0.75, 0.00, 0.25, 0.35)),
      RoomDef('Sala Integrada', Rect.fromLTWH(0.00, 0.35, 0.65, 0.65)),
      RoomDef('Varanda', Rect.fromLTWH(0.65, 0.35, 0.35, 0.65)),
    ],
  ),
  FloorPlanDef(
    id: 'apartamento_compacto',
    name: 'Apartamento Compacto',
    subtitle: '2 Quartos · Cozinha Americana · Varanda',
    mode: FloorPlanRenderMode.image,
    assetPath: kApartmentAsset,
    aspectRatio: 1200 / 800,
  ),
  FloorPlanDef(
    id: 'escritorio',
    name: 'Escritório / Comercial',
    subtitle: 'Open Space · Sala de Reunião · Diretoria · Copa',
    mode: FloorPlanRenderMode.drawn,
    aspectRatio: 1.6,
    rooms: [
      RoomDef('Open Space', Rect.fromLTWH(0.00, 0.00, 0.60, 1.00)),
      RoomDef('Sala de Reunião', Rect.fromLTWH(0.60, 0.00, 0.40, 0.40)),
      RoomDef('Diretoria', Rect.fromLTWH(0.60, 0.40, 0.40, 0.30)),
      RoomDef('Copa', Rect.fromLTWH(0.60, 0.70, 0.40, 0.30)),
    ],
  ),
];

// ---------------------------------------------------------------------------
// Modelo de dados
// ---------------------------------------------------------------------------

class RouterNode {
  final String id;
  Offset position;
  RouterModelType model;
  RouterNode({required this.id, required this.position, required this.model});
}

/// Estado da rede Mesh. Usa ChangeNotifier para permitir que apenas o
/// CustomPainter do mapa de calor seja re-renderizado durante o arraste,
/// sem reconstruir toda a árvore de widgets.
class NetworkModel extends ChangeNotifier {
  FloorPlanDef currentPlan = kFloorPlanLibrary[2]; // Apartamento Compacto (planta real)
  RouterModelType selectedModel = RouterModelType.huaweiAx3;
  final List<RouterNode> routers = [];
  int _counter = 0;

  void setFloorPlan(FloorPlanDef plan) {
    if (currentPlan.id == plan.id) return;
    currentPlan = plan;
    routers.clear();
    notifyListeners();
  }

  void setSelectedModel(RouterModelType type) {
    if (selectedModel == type) return;
    selectedModel = type;
    notifyListeners();
  }

  void addRouter(Offset position, {RouterModelType? model}) {
    routers.add(RouterNode(id: 'r${_counter++}', position: position, model: model ?? selectedModel));
    notifyListeners();
  }

  void moveRouter(String id, Offset position) {
    final router = routers.firstWhere((r) => r.id == id);
    router.position = position;
    notifyListeners();
  }

  void clear() {
    if (routers.isEmpty) return;
    routers.clear();
    notifyListeners();
  }
}

// ---------------------------------------------------------------------------
// Modelo de propagação de sinal
// Sinal(x,y) = max_i ( Ptx_i - 22 * log10(d_i) ), Ptx_i conforme o modelo
// de hardware de cada roteador.
// ---------------------------------------------------------------------------

const double kPixelsPerMeter = 45.0; // escala visual da planta

double _singleRouterSignal(Offset point, RouterNode router) {
  final distancePx = (point - router.position).distance;
  final distanceM = max(distancePx / kPixelsPerMeter, 1.0);
  final ptx = _specFor(router.model).txPowerDbm;
  return ptx - 22 * (log(distanceM) / ln10);
}

/// Sinal combinado da rede Mesh em um ponto: o MÁXIMO entre todos os
/// roteadores ativos (união da cobertura).
double _meshSignalAt(Offset point, List<RouterNode> routers) {
  double best = -1000.0;
  for (final r in routers) {
    final v = _singleRouterSignal(point, r);
    if (v > best) best = v;
  }
  return best;
}

// ---------------------------------------------------------------------------
// Paleta de calor estilo "jet", com desvanecimento (alpha) nas áreas de
// sinal fraco para deixar a planta visível por baixo.
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

/// Suaviza a transição para transparente nas áreas de sinal muito fraco,
/// formando o "halo" gradual visto em mapas de calor reais.
double _alphaForT(double t) {
  const lo = 0.04, hi = 0.55, maxAlpha = 0.82;
  final x = ((t - lo) / (hi - lo)).clamp(0.0, 1.0);
  final smooth = x * x * (3 - 2 * x);
  return smooth * maxAlpha;
}

// ---------------------------------------------------------------------------
// Pintura: planta baixa desenhada (usada quando não há foto real disponível)
// ---------------------------------------------------------------------------

class FloorPlanPainter extends CustomPainter {
  final List<RoomDef> rooms;
  const FloorPlanPainter(this.rooms);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);

    final wallPaint = Paint()
      ..color = Colors.black87
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;

    for (final room in rooms) {
      final rect = Rect.fromLTWH(
        room.rectFrac.left * size.width,
        room.rectFrac.top * size.height,
        room.rectFrac.width * size.width,
        room.rectFrac.height * size.height,
      );
      canvas.drawRect(rect, wallPaint);

      final tp = TextPainter(
        text: TextSpan(
          text: room.label,
          style: const TextStyle(color: Colors.black87, fontSize: 12, fontWeight: FontWeight.w600),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: rect.width - 8);
      tp.paint(canvas, Offset(rect.left + 6, rect.top + 6));
    }

    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = Colors.black
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4,
    );
  }

  @override
  bool shouldRepaint(covariant FloorPlanPainter oldDelegate) => oldDelegate.rooms != rooms;
}

// ---------------------------------------------------------------------------
// Pintura: mapa de calor
// ---------------------------------------------------------------------------

class HeatmapPainter extends CustomPainter {
  final List<RouterNode> routers;
  HeatmapPainter(this.routers);

  // Amostragem em grade: equilíbrio entre qualidade visual e performance.
  // A grade é depois suavizada com um blur (ver ImageFiltered no build).
  static const double _cell = 8.0;

  final Paint _cellPaint = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    if (routers.isEmpty) return;

    for (double y = 0; y < size.height; y += _cell) {
      final h = min(_cell, size.height - y);
      for (double x = 0; x < size.width; x += _cell) {
        final w = min(_cell, size.width - x);
        final center = Offset(x + w / 2, y + h / 2);
        final dbm = _meshSignalAt(center, routers);
        final t = _signalToT(dbm);
        final alpha = _alphaForT(t);
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
  final List<RouterNode> routers;
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
      _ring(canvas, r.position, t);
      _ring(canvas, r.position, (t + 0.5) % 1.0);
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
// Tela principal
// ---------------------------------------------------------------------------

class NetFloorHomePage extends StatefulWidget {
  const NetFloorHomePage({super.key});

  @override
  State<NetFloorHomePage> createState() => _NetFloorHomePageState();
}

class _NetFloorHomePageState extends State<NetFloorHomePage> with SingleTickerProviderStateMixin {
  final NetworkModel _model = NetworkModel();
  late final AnimationController _pingController;
  static const double _markerRadius = 20.0;
  Size _lastCanvasSize = const Size(320, 320 / (1200 / 800));

  @override
  void initState() {
    super.initState();
    _pingController = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400))..repeat();
  }

  @override
  void dispose() {
    _pingController.dispose();
    super.dispose();
  }

  Offset _clampToBounds(Offset pos, Size bounds) {
    if (bounds.width <= 0 || bounds.height <= 0) return pos;
    return Offset(
      pos.dx.clamp(_markerRadius, max(_markerRadius, bounds.width - _markerRadius)).toDouble(),
      pos.dy.clamp(_markerRadius, max(_markerRadius, bounds.height - _markerRadius)).toDouble(),
    );
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

  Future<void> _showFloorPlanLibrary() async {
    final selected = await showModalBottomSheet<FloorPlanDef>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Biblioteca de Plantas', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 12),
              for (final plan in kFloorPlanLibrary)
                Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: Icon(
                      plan.mode == FloorPlanRenderMode.image ? Icons.image_outlined : Icons.grid_on_outlined,
                      color: Colors.indigo,
                    ),
                    title: Text(plan.name),
                    subtitle: Text(plan.subtitle),
                    trailing: _model.currentPlan.id == plan.id ? const Icon(Icons.check_circle, color: Colors.indigo) : null,
                    onTap: () => Navigator.pop(ctx, plan),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (selected != null) {
      setState(() => _model.setFloorPlan(selected));
    }
  }

  Future<void> _handleAddViaButton() async {
    final selected = await _pickModel();
    if (selected == null) return;
    final size = _lastCanvasSize;
    final offset = Offset(24.0 * (_model.routers.length % 5), 24.0 * (_model.routers.length % 3));
    final pos = _clampToBounds(Offset(size.width / 2, size.height / 2) + offset, size);
    setState(() => _model.setSelectedModel(selected));
    _model.addRouter(pos, model: selected);
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
            icon: const Icon(Icons.layers_outlined),
            tooltip: 'Biblioteca de Plantas',
            onPressed: _showFloorPlanLibrary,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _buildLegend(),
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
                                    final pos = _clampToBounds(details.localPosition, _lastCanvasSize);
                                    _model.addRouter(pos);
                                  },
                                  child: Stack(
                                    children: [
                                      Positioned.fill(
                                        child: RepaintBoundary(
                                          child: _model.currentPlan.mode == FloorPlanRenderMode.image
                                              ? Image(
                                                  image: AssetImage(_model.currentPlan.assetPath!),
                                                  fit: BoxFit.fill,
                                                )
                                              : CustomPaint(painter: FloorPlanPainter(_model.currentPlan.rooms)),
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
                                            painter: HeatmapPainter(List.of(_model.routers)),
                                          ),
                                        ),
                                      ),
                                      Positioned.fill(
                                        child: AnimatedBuilder(
                                          animation: _pingController,
                                          builder: (context, _) {
                                            return CustomPaint(
                                              painter: RadarPingPainter(_model.routers, _pingController.value),
                                            );
                                          },
                                        ),
                                      ),
                                      for (final r in _model.routers)
                                        _buildRouterMarker(r, _lastCanvasSize),
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

  Widget _buildRouterMarker(RouterNode router, Size bounds) {
    return Positioned(
      left: router.position.dx - _markerRadius,
      top: router.position.dy - _markerRadius,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {}, // absorve o toque para não "vazar" para o fundo e criar um roteador duplicado
        onPanUpdate: (details) {
          final newPos = _clampToBounds(router.position + details.delta, bounds);
          _model.moveRouter(router.id, newPos);
        },
        child: SizedBox(
          width: _markerRadius * 2,
          height: _markerRadius * 2,
          child: CustomPaint(painter: RouterDevicePainter(router.model)),
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
