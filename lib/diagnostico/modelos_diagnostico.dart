// ============================================================================
// ETAPA 19 — Modelos do diagnóstico Wi-Fi
// ============================================================================
// O QUE É:       WifiNetwork (rede vista na varredura), LinkInfo (conexão atual), permissões e a
//                "saúde do canal" (quanto cada canal está congestionado).
// COMO FUNCIONA: computeChannelHealth soma a interferência de cada rede vizinha por canal e dá a
//                nota Excelente / Bom / Ruim; a rede em que você está conectado não conta.
// USADO POR:     fontes_dados, controlador_diagnostico e as abas.
// ONDE MEXER:    Classificação dos canais (limiares) e campos lidos do Android.
// ============================================================================
part of '../main.dart';

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
