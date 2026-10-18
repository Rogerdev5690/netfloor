// ============================================================================
// ETAPA 9 — Medições de campo, pontos de medição e dados do laudo
// ============================================================================
// O QUE É:       Measurement (RSSI, PHY, ping, perda), MeasurePoint (ponto marcado na planta) e
//                ReportInfo (técnico, cliente, logo, assinatura, observações).
// COMO FUNCIONA: Tudo tem toJson/fromJson, porque é salvo no projeto e vai no arquivo .json exportado.
// USADO POR:     network_model, tela_diagnostico, tela_laudo, gerador_pdf.
// ONDE MEXER:    Campos novos do laudo/medição: adicione aqui e em toJson/fromJson.
// ============================================================================
part of '../../main.dart';

// ---------------------------------------------------------------------------
// Pontos de medição, medições de campo e dados do laudo
// ---------------------------------------------------------------------------

/// Resultado de uma medição de campo (RSSI + PHY + ping gateway/Internet).
class Measurement {
  final DateTime time;
  final bool native; // false = dados simulados (fora do WaveLens Shell)
  final String ssid;
  final String bssid;
  final String bandLabel;
  final int channel;
  final int rssi;
  final int linkMbps;
  final String gateway;
  final double? gwAvgMs;
  final double gwLossPct;
  final int gwSent;
  final double? netAvgMs;
  final double netLossPct;
  final int netSent;
  final String? pointId;
  final String? pointName;
  final int? floor;

  const Measurement({
    required this.time,
    required this.native,
    this.ssid = '',
    this.bssid = '',
    this.bandLabel = '',
    this.channel = 0,
    this.rssi = -100,
    this.linkMbps = 0,
    this.gateway = '',
    this.gwAvgMs,
    this.gwLossPct = 0,
    this.gwSent = 0,
    this.netAvgMs,
    this.netLossPct = 0,
    this.netSent = 0,
    this.pointId,
    this.pointName,
    this.floor,
  });

  Measurement linkedTo(String? id, String? name, int? floorIndex) => Measurement(
        time: time,
        native: native,
        ssid: ssid,
        bssid: bssid,
        bandLabel: bandLabel,
        channel: channel,
        rssi: rssi,
        linkMbps: linkMbps,
        gateway: gateway,
        gwAvgMs: gwAvgMs,
        gwLossPct: gwLossPct,
        gwSent: gwSent,
        netAvgMs: netAvgMs,
        netLossPct: netLossPct,
        netSent: netSent,
        pointId: id,
        pointName: name,
        floor: floorIndex,
      );

  Map<String, dynamic> toJson() => {
        'time': time.toIso8601String(),
        'native': native,
        'ssid': ssid,
        'bssid': bssid,
        'band': bandLabel,
        'channel': channel,
        'rssi': rssi,
        'linkMbps': linkMbps,
        'gateway': gateway,
        'gwAvgMs': gwAvgMs,
        'gwLossPct': gwLossPct,
        'gwSent': gwSent,
        'netAvgMs': netAvgMs,
        'netLossPct': netLossPct,
        'netSent': netSent,
        'pointId': pointId,
        'pointName': pointName,
        'floor': floor,
      };

  factory Measurement.fromJson(Map<String, dynamic> j) => Measurement(
        time: DateTime.tryParse('${j['time']}') ?? DateTime.now(),
        native: j['native'] == true,
        ssid: (j['ssid'] as String?) ?? '',
        bssid: (j['bssid'] as String?) ?? '',
        bandLabel: (j['band'] as String?) ?? '',
        channel: (j['channel'] as num?)?.toInt() ?? 0,
        rssi: (j['rssi'] as num?)?.toInt() ?? -100,
        linkMbps: (j['linkMbps'] as num?)?.toInt() ?? 0,
        gateway: (j['gateway'] as String?) ?? '',
        gwAvgMs: (j['gwAvgMs'] as num?)?.toDouble(),
        gwLossPct: (j['gwLossPct'] as num?)?.toDouble() ?? 0,
        gwSent: (j['gwSent'] as num?)?.toInt() ?? 0,
        netAvgMs: (j['netAvgMs'] as num?)?.toDouble(),
        netLossPct: (j['netLossPct'] as num?)?.toDouble() ?? 0,
        netSent: (j['netSent'] as num?)?.toInt() ?? 0,
        pointId: j['pointId'] as String?,
        pointName: j['pointName'] as String?,
        floor: (j['floor'] as num?)?.toInt(),
      );
}

/// Ponto de medição marcado na planta (ex.: "Quarto 2"): recebe a previsão do
/// simulador e, opcionalmente, uma medição real.
class MeasurePoint {
  final String id;
  String name;
  Offset frac;
  int floor;
  Measurement? measured;
  MeasurePoint({required this.id, required this.name, required this.frac, required this.floor, this.measured});
}

/// Dados do laudo de vistoria (persistidos junto com o projeto).
class ReportInfo {
  String technician;
  String company;
  String client;
  String address;
  String notes;
  String signerName;
  DateTime? date;
  Uint8List? logo;
  Uint8List? signature;
  DateTime? signedAt;

  ReportInfo({
    this.technician = '',
    this.company = '',
    this.client = '',
    this.address = '',
    this.notes = '',
    this.signerName = '',
    this.date,
    this.logo,
    this.signature,
    this.signedAt,
  });

  Map<String, dynamic> toJson() => {
        'technician': technician,
        'company': company,
        'client': client,
        'address': address,
        'notes': notes,
        'signerName': signerName,
        'date': date?.toIso8601String(),
        'logo': logo == null ? null : base64Encode(logo!),
        'signature': signature == null ? null : base64Encode(signature!),
        'signedAt': signedAt?.toIso8601String(),
      };

  factory ReportInfo.fromJson(Map<String, dynamic> j) => ReportInfo(
        technician: (j['technician'] as String?) ?? '',
        company: (j['company'] as String?) ?? '',
        client: (j['client'] as String?) ?? '',
        address: (j['address'] as String?) ?? '',
        notes: (j['notes'] as String?) ?? '',
        signerName: (j['signerName'] as String?) ?? '',
        date: DateTime.tryParse('${j['date']}'),
        logo: j['logo'] is String ? base64Decode(j['logo'] as String) : null,
        signature: j['signature'] is String ? base64Decode(j['signature'] as String) : null,
        signedAt: DateTime.tryParse('${j['signedAt']}'),
      );
}
