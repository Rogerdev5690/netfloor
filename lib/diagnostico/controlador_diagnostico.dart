// ============================================================================
// ETAPA 21 — Controlador do diagnóstico (DiagnosticsController)
// ============================================================================
// O QUE É:       Guarda as redes, as amostras de sinal e de ping e roda os temporizadores.
// COMO FUNCIONA: Só a aba visível trabalha: Espectro varre a cada 30 s; Sinal lê o RSSI a cada 1 s;
//                Latência faz ping duplo (roteador × Internet) a cada 1 s. captureSnapshot() faz uma
//                medição completa (RSSI + PHY + ping + perda) para o laudo.
// USADO POR:     app.dart (criação), tela_diagnostico, tela_simulador ("Medir agora").
// ONDE MEXER:    Intervalos, número de amostras (kMaxSamples) e a lógica de medição.
// ============================================================================
part of '../main.dart';

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
