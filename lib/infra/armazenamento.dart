// ============================================================================
// ETAPA 26 — Armazenamento local offline (AppStore)
// ============================================================================
// O QUE É:       Salva os projetos no próprio aparelho (IndexedDB via sembast_web).
// COMO FUNCIONA: Autosave 0,8 s depois da última alteração (e ao esconder a página). Guarda o
//                projeto em "workspaces", as imagens de plantas enviadas em "images" e preferências
//                em "settings". Sem IndexedDB (aba anônima) o app funciona, só não salva.
// USADO POR:     app.dart (boot), tela_simulador (lista "Meus projetos").
// ONDE MEXER:    Tempo do autosave e o que é guardado.
// ============================================================================
part of '../main.dart';

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
