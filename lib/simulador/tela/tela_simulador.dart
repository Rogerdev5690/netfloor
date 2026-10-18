// ============================================================================
// ETAPA 17 — Tela do Simulador (a tela principal)
// ============================================================================
// O QUE É:       SimulatorPage: mapa com zoom, barras (pavimento, banda, ferramenta), botões e
//                todos os diálogos (calibrar escala, paredes, pontos, projetos, opacidade).
// COMO FUNCIONA: Toques no mapa usam ponteiros "crus" (Listener) para conviver com o pinch-zoom do
//                InteractiveViewer. A ferramenta ativa (roteador/parede/régua/ponto) decide o que
//                cada toque faz. As camadas (planta, calor, paredes, anéis, marcadores) ficam num Stack.
// USADO POR:     app.dart (aba "Simulador").
// ONDE MEXER:    Textos/botões da tela, comportamento dos gestos (_onPointerDown/Move/Up), menus.
// ============================================================================
part of '../../main.dart';

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
      final name = '${safeFileName(_model.workspaceName)}.wavelens.json';
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
