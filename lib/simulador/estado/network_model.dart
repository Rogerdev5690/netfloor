// ============================================================================
// ETAPA 10 — Estado do projeto (NetworkModel)
// ============================================================================
// O QUE É:       O "cérebro" do simulador: projeto atual, pavimentos, roteadores, pontos, paredes,
//                banda, ferramenta ativa, registros de medição e dados do laudo.
// COMO FUNCIONA: É um ChangeNotifier: quando algo muda (notifyListeners) as telas se redesenham.
//                toJson/applyJson convertem o projeto inteiro para/de .json (exportar, importar e
//                salvar no banco local). calibrate() ajusta a escala pela régua.
// USADO POR:     quase todas as telas; o AppStore observa para salvar sozinho.
// ONDE MEXER:    Qualquer regra de negócio do projeto (adicionar/mover roteador, calibrar, medir).
// ============================================================================
part of '../../main.dart';

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
