// ============================================================================
// ETAPA 20 — Fontes de dados do diagnóstico (real × simulada)
// ============================================================================
// O QUE É:       DiagnosticsSource (o contrato), NativeBridgeDiagnostics (dados reais do Android)
//                e SimulatedDiagnostics (dados fictícios para demonstrar no navegador).
// COMO FUNCIONA: O controlador escolhe a fonte: se a ponte existir usa a real; senão a simulada.
//                Assim o app inteiro funciona em qualquer lugar, com o aviso "modo simulação".
// USADO POR:     controlador_diagnostico.
// ONDE MEXER:    Redes/valores fictícios da simulação; chamadas ao Android da fonte real.
// ============================================================================
part of '../main.dart';

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
