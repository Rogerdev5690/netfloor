// ============================================================================
// ETAPA 18 — Ponte com o app Android (NativeBridge)
// ============================================================================
// O QUE É:       A ligação entre o site e o app Android (Shell): o site pede, o Android executa.
// COMO FUNCIONA: Cada chamada vira uma mensagem JSON com id; a resposta chega por uma função global
//                e completa o Completer certo. Sem o Shell (navegador comum) a ponte não existe.
// USADO POR:     fontes_dados, arquivos (salvar/compartilhar) e controlador_diagnostico.
// ONDE MEXER:    Nome do canal (@JS) e tempo limite das chamadas. O canal mantém o nome antigo por compatibilidade.
// ============================================================================
part of '../main.dart';

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
