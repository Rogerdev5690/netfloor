// ============================================================================
// ETAPA 7 — Plantas, paredes, materiais e bandas de frequência
// ============================================================================
// O QUE É:       Os tipos que descrevem uma planta: cômodos (RoomDef), paredes (WallSegment) e
//                seus materiais (drywall, cerâmico, vidro, concreto), bandas 2.4/5/6 GHz (RfBand),
//                planta (FloorPlanDef), pavimento (FloorDef), projeto (ProjectDef) e o
//                FloorState (pavimento em uso: escala calibrada + paredes desenhadas).
// COMO FUNCIONA: São só dados (sem tela). Paredes e posições usam frações 0..1 da planta; a escala
//                real em metros vem do FloorState.widthM (calibrada pela régua).
// USADO POR:     biblioteca_plantas, network_model, fisica_sinal, tela_simulador.
// ONDE MEXER:    Perda dos materiais (kWallMaterials) e fatores por banda (kRfBands).
// ============================================================================
part of '../../main.dart';

// ---------------------------------------------------------------------------
// Projetos, pavimentos e plantas baixas.
//
// Um PROJETO tem um ou mais PAVIMENTOS (térreo, 1º andar...) e cada pavimento
// usa uma planta (FloorPlanDef) com `wallSegments` (paredes vetorizadas em
// coordenadas fracionárias) para o ray-casting de atenuação.
//
// Cada planta pode vir de: imagem remota (imageUrl) -> asset embutido
// (assetPath) -> desenho vetorial (rooms). Se o PNG ainda não existe em
// assets/floorplans/, o app cai sozinho no desenho vetorial; basta soltar o
// arquivo com o nome esperado na pasta (e ajustar o aspectRatio, se mudar).
// Plantas enviadas pelo usuário vivem só em memória (Uint8List + Image.memory),
// sem dart:io, e não têm paredes mapeadas.
// ---------------------------------------------------------------------------

class RoomDef {
  final String label;
  final Rect rectFrac; // coordenadas fracionárias (0..1) relativas à planta
  const RoomDef(this.label, this.rectFrac);
}

/// Materiais de parede (presets do desenhista de paredes). Os valores são a
/// perda típica, em dB, na banda de 2.4 GHz; em 5/6 GHz a perda é multiplicada
/// pelo fator da banda (ver [kRfBands]).
enum WallMaterial { drywall, ceramico, vidro, concreto }

class WallMaterialSpec {
  final WallMaterial material;
  final String label;
  final String shortLabel;
  final double minDb;
  final double maxDb;
  final double defaultDb;
  final Color color;
  const WallMaterialSpec(this.material, this.label, this.shortLabel, this.minDb, this.maxDb, this.defaultDb, this.color);

  bool get adjustable => maxDb > minDb;
}

const List<WallMaterialSpec> kWallMaterials = [
  WallMaterialSpec(WallMaterial.drywall, 'Gesso / Drywall', 'Gesso', 2, 2, 2, Color(0xFF22C55E)),
  WallMaterialSpec(WallMaterial.ceramico, 'Tijolo cerâmico', 'Cerâmico', 4, 4, 4, Color(0xFFF59E0B)),
  WallMaterialSpec(WallMaterial.vidro, 'Vidro / Espelho', 'Vidro', 5, 5, 5, Color(0xFF06B6D4)),
  WallMaterialSpec(WallMaterial.concreto, 'Concreto armado / Laje', 'Concreto', 12, 15, 13.5, Color(0xFFEF4444)),
];

WallMaterialSpec wallMaterialSpec(WallMaterial m) => kWallMaterials.firstWhere((s) => s.material == m);

class WallSegment {
  final Offset a; // coordenadas fracionárias (0..1)
  final Offset b;
  final double attenuationDb; // perda de sinal ao atravessar esta parede (em 2.4 GHz)
  final WallMaterial? material; // null = parede aproximada da planta (não desenhada pelo usuário)
  const WallSegment(this.a, this.b, {this.attenuationDb = 6.0, this.material});

  bool get isUser => material != null;
  Color get color => material == null ? const Color(0xFF64748B) : wallMaterialSpec(material!).color;
}

/// Banda de operação usada na simulação. A referência é 2.4 GHz; 5 e 6 GHz
/// têm perda de referência (a 1 m) maior, expoente de propagação maior e
/// paredes mais "opacas" — logo, alcance menor.
enum RfBand { ghz24, ghz5, ghz6 }

class RfBandSpec {
  final RfBand band;
  final String label;
  final double refOffsetDb; // deslocamento do nível a 1 m em relação a 2.4 GHz
  final double pathLossExp; // multiplicador de 10*log10(d): 22 = expoente n≈2.2
  final double wallFactor; // multiplicador da atenuação das paredes
  const RfBandSpec(this.band, this.label, this.refOffsetDb, this.pathLossExp, this.wallFactor);
}

const List<RfBandSpec> kRfBands = [
  RfBandSpec(RfBand.ghz24, '2.4 GHz', 0.0, 22.0, 1.0),
  RfBandSpec(RfBand.ghz5, '5 GHz', -6.4, 24.0, 1.35),
  RfBandSpec(RfBand.ghz6, '6 GHz', -7.9, 25.0, 1.5),
];

RfBandSpec rfBandSpec(RfBand b) => kRfBands.firstWhere((s) => s.band == b);

class FloorPlanDef {
  final String id;
  final String name;
  final String subtitle;
  final String? imageUrl; // imagem remota (Image.network), se disponível
  final String? assetPath; // asset local: fallback da imagem remota, ou única fonte
  final Uint8List? memoryBytes; // planta enviada pelo usuário (Image.memory)
  final double aspectRatio;
  final double defaultWidthM; // largura real estimada da planta (m), até o usuário calibrar a régua
  final List<RoomDef> rooms; // desenho vetorial (usado quando não há imagem)
  final List<WallSegment> wallSegments;
  const FloorPlanDef({
    required this.id,
    required this.name,
    required this.subtitle,
    this.imageUrl,
    this.assetPath,
    this.memoryBytes,
    required this.aspectRatio,
    this.defaultWidthM = 8.0,
    this.rooms = const [],
    this.wallSegments = const [],
  });

  bool get isCustom => memoryBytes != null;
}

class FloorDef {
  final String label;
  final FloorPlanDef plan;
  const FloorDef(this.label, this.plan);
}

class ProjectDef {
  final String id;
  final String name;
  final String subtitle;
  final List<FloorDef> floors;
  final bool isCustom;
  const ProjectDef({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.floors,
    this.isCustom = false,
  });
}

String floorLabel(int index) => index == 0 ? 'Térreo' : '${index}º Andar';


/// Estado mutável de um pavimento: a planta (imutável) + escala real + paredes
/// desenhadas pelo usuário.
class FloorState {
  final String label;
  final FloorPlanDef plan;
  double widthM; // largura real da planta, em metros (calibrada pela régua)
  bool calibrated;
  final List<WallSegment> userWalls;
  FloorState(this.label, this.plan, {double? widthM, this.calibrated = false, List<WallSegment>? userWalls})
      : widthM = widthM ?? plan.defaultWidthM,
        userWalls = userWalls ?? [];

  double get heightM => widthM / plan.aspectRatio;
  List<WallSegment> get allWalls => [...plan.wallSegments, ...userWalls];
}
