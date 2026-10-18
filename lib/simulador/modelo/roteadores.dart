// ============================================================================
// ETAPA 6 — Roteadores: catálogo e roteador posicionado
// ============================================================================
// O QUE É:       O catálogo de modelos (Huawei, TP-Link, UniFi, ZTE) com a potência de cada um
//                em dBm, e o RouterNode (um roteador colocado na planta, em fração 0..1).
// COMO FUNCIONA: A potência (txPowerDbm) entra direto na fórmula de sinal. A posição é guardada
//                como fração da planta, para não depender do tamanho da tela.
// USADO POR:     fisica_sinal (potência), icones_roteador (desenho), tela_simulador (escolha do modelo).
// ONDE MEXER:    Para adicionar um roteador: enum RouterModelType + kRouterCatalog + icone_roteador.
// ============================================================================
part of '../../main.dart';

// ---------------------------------------------------------------------------
// Catálogo de roteadores: cada modelo tem uma potência de transmissão (dBm)
// diferente, usada diretamente no cálculo de propagação do sinal.
// ---------------------------------------------------------------------------

enum RouterModelType { huaweiAx3, tplinkDeco, unifiAp, zteE2320 }

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
  // Ganho/potência configurados acima do Huawei AX3 (18 dBm): CPE Wi-Fi 6 com
  // maior EIRP por antena externa e beamforming — cobertura e alcance maiores
  // na simulação de propagação.
  RouterModelSpec(
    type: RouterModelType.zteE2320,
    name: 'ZTE E2320 / E2620 (ZXHN, Wi-Fi 6)',
    shortName: 'ZTE E2320',
    txPowerDbm: 20,
  ),
];

RouterModelSpec _specFor(RouterModelType type) => kRouterCatalog.firstWhere((s) => s.type == type);


// ---------------------------------------------------------------------------
// Modelo de dados
// ---------------------------------------------------------------------------

class RouterNode {
  final String id;
  Offset frac; // posição normalizada (0..1) dentro do pavimento
  int floor; // índice do pavimento onde o roteador está instalado
  RouterModelType model;
  RouterNode({required this.id, required this.frac, required this.floor, required this.model});
}

const double kDefaultHeatOpacity = 0.48;
