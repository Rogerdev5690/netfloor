// ============================================================================
// ETAPA 27 — Entrega de arquivos (PDF e .json)
// ============================================================================
// O QUE É:       FileIO.deliver: baixa o arquivo no navegador ou, no app Android, salva em
//                Downloads/WaveLens / abre a folha de compartilhar.
// COMO FUNCIONA: No Android o arquivo vai pela ponte em pedaços de 256 KB (base64); no navegador
//                usa Blob + link de download.
// USADO POR:     tela_laudo e tela_simulador (exportar projeto).
// ONDE MEXER:    Tamanho dos pedaços e mensagens de retorno.
// ============================================================================
part of '../main.dart';

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
