// ============================================================================
// ETAPA 8 — Biblioteca de plantas do app
// ============================================================================
// O QUE É:       As plantas prontas (Casa 2 Quartos, Casa 2 Pavimentos, Plantas 01–04, Edifício)
//                e a lista de projetos (kProjectLibrary) mostrada em "Projetos e plantas".
// COMO FUNCIONA: Cada planta pode ter imagem (assets/floorplans) ou, sem ela, um desenho vetorial
//                provisório (rooms). kBuiltInPlans permite reabrir projetos salvos/importados.
// USADO POR:     network_model (projeto inicial), tela_simulador (lista), armazenamento (reabrir).
// ONDE MEXER:    Para adicionar uma planta: crie o FloorPlanDef, ponha em kBuiltInPlans e em kProjectLibrary.
// ============================================================================
part of '../../main.dart';

const String kGitHubRawBase = 'https://raw.githubusercontent.com/Rogerdev5690/netfloor/main/assets/floorplans';

const FloorPlanDef kPlanCasa2q = FloorPlanDef(
  id: 'casa_2q',
  name: 'Casa Térrea 2 Quartos',
  subtitle: '2 Quartos · Cozinha · Sala · Banheiro',
  imageUrl: '$kGitHubRawBase/casa_2q.png',
  assetPath: 'assets/floorplans/casa_2q.png',
  aspectRatio: 736 / 1105,
  // Aproximação das paredes internas visíveis na planta (não medidas a laser).
  wallSegments: [
    WallSegment(Offset(0.50, 0.24), Offset(0.50, 0.52)),
    WallSegment(Offset(0.50, 0.24), Offset(0.91, 0.24)),
    WallSegment(Offset(0.62, 0.49), Offset(0.92, 0.49)),
    WallSegment(Offset(0.62, 0.49), Offset(0.62, 0.625)),
    WallSegment(Offset(0.62, 0.625), Offset(0.92, 0.625)),
    WallSegment(Offset(0.52, 0.62), Offset(0.52, 0.90)),
  ],
);

// Casa 2 Pavimentos: modelo de referência para simulações em casas de dois
// andares — desenho vetorial próprio (corte esquemático), sem depender de
// foto de terceiros. Térreo: sala de leitura + escada + sala de TV. Andar
// superior: sala de estar com varanda + quarto.
const FloorPlanDef kPlanCasa2pTerreo = FloorPlanDef(
  id: 'casa_2p_terreo',
  name: 'Casa 2 Pavimentos — Térreo',
  subtitle: 'Sala de Leitura · Escada · Sala de TV',
  aspectRatio: 1.45,
  defaultWidthM: 9,
  rooms: [
    RoomDef('Sala de Estar', Rect.fromLTWH(0.00, 0.00, 0.42, 1.00)),
    RoomDef('Escada', Rect.fromLTWH(0.42, 0.00, 0.16, 1.00)),
    RoomDef('Sala de TV', Rect.fromLTWH(0.58, 0.00, 0.42, 1.00)),
  ],
  wallSegments: [
    WallSegment(Offset(0.42, 0.00), Offset(0.42, 1.00)),
    WallSegment(Offset(0.58, 0.00), Offset(0.58, 1.00)),
  ],
);

const FloorPlanDef kPlanCasa2pAndar = FloorPlanDef(
  id: 'casa_2p_andar',
  name: 'Casa 2 Pavimentos — 1º Andar',
  subtitle: 'Sala de Estar com Varanda · Quarto',
  aspectRatio: 1.45,
  defaultWidthM: 9,
  rooms: [
    RoomDef('Sala de Estar', Rect.fromLTWH(0.00, 0.00, 0.50, 0.84)),
    RoomDef('Varanda', Rect.fromLTWH(0.00, 0.84, 0.50, 0.16)),
    RoomDef('Quarto', Rect.fromLTWH(0.50, 0.00, 0.50, 1.00)),
  ],
  wallSegments: [
    WallSegment(Offset(0.50, 0.00), Offset(0.50, 1.00)),
    WallSegment(Offset(0.00, 0.84), Offset(0.50, 0.84), attenuationDb: 3.5),
  ],
);

// Plantas 01-03: espaço reservado para o lote de imagens limpas (sem marca
// d'água) da biblioteca: assets/floorplans/planta_01.png ... planta_03.png.
// Enquanto os PNGs não existirem, o app mostra estes desenhos provisórios.
const FloorPlanDef kPlanta01 = FloorPlanDef(
  id: 'planta_01',
  name: 'Planta 01 — Apartamento 3 Quartos',
  subtitle: 'Desenho provisório · aguardando planta_01.png',
  assetPath: 'assets/floorplans/planta_01.png',
  aspectRatio: 1.5,
  defaultWidthM: 12,
  rooms: [
    RoomDef('Cozinha', Rect.fromLTWH(0.00, 0.00, 0.32, 0.34)),
    RoomDef('Banheiro', Rect.fromLTWH(0.32, 0.00, 0.16, 0.34)),
    RoomDef('Lavanderia', Rect.fromLTWH(0.48, 0.00, 0.14, 0.34)),
    RoomDef('Quarto 3', Rect.fromLTWH(0.62, 0.00, 0.38, 0.34)),
    RoomDef('Sala de Estar', Rect.fromLTWH(0.00, 0.34, 0.38, 0.46)),
    RoomDef('Varanda', Rect.fromLTWH(0.00, 0.80, 0.38, 0.20)),
    RoomDef('Quarto 1', Rect.fromLTWH(0.38, 0.34, 0.31, 0.66)),
    RoomDef('Quarto 2', Rect.fromLTWH(0.69, 0.34, 0.31, 0.66)),
  ],
  wallSegments: [
    WallSegment(Offset(0.00, 0.34), Offset(1.00, 0.34)),
    WallSegment(Offset(0.32, 0.00), Offset(0.32, 0.34)),
    WallSegment(Offset(0.48, 0.00), Offset(0.48, 0.34)),
    WallSegment(Offset(0.62, 0.00), Offset(0.62, 0.34)),
    WallSegment(Offset(0.38, 0.34), Offset(0.38, 1.00)),
    WallSegment(Offset(0.69, 0.34), Offset(0.69, 1.00)),
    WallSegment(Offset(0.00, 0.80), Offset(0.38, 0.80), attenuationDb: 3.5),
  ],
);

const FloorPlanDef kPlanta02 = FloorPlanDef(
  id: 'planta_02',
  name: 'Planta 02 — Apartamento Open Space',
  subtitle: 'Desenho provisório · aguardando planta_02.png',
  assetPath: 'assets/floorplans/planta_02.png',
  aspectRatio: 1.5,
  defaultWidthM: 12,
  rooms: [
    RoomDef('Sala de Estar', Rect.fromLTWH(0.00, 0.00, 0.46, 0.58)),
    RoomDef('Cozinha', Rect.fromLTWH(0.00, 0.58, 0.46, 0.42)),
    RoomDef('Quarto 1', Rect.fromLTWH(0.46, 0.00, 0.27, 0.34)),
    RoomDef('Suíte', Rect.fromLTWH(0.73, 0.00, 0.27, 0.34)),
    RoomDef('Banheiro', Rect.fromLTWH(0.46, 0.34, 0.20, 0.26)),
    RoomDef('Banheiro', Rect.fromLTWH(0.66, 0.34, 0.20, 0.26)),
    RoomDef('Quarto 3', Rect.fromLTWH(0.46, 0.60, 0.40, 0.40)),
    RoomDef('Varanda', Rect.fromLTWH(0.86, 0.34, 0.14, 0.66)),
  ],
  wallSegments: [
    WallSegment(Offset(0.46, 0.00), Offset(0.46, 1.00)),
    WallSegment(Offset(0.46, 0.34), Offset(1.00, 0.34)),
    WallSegment(Offset(0.73, 0.00), Offset(0.73, 0.34)),
    WallSegment(Offset(0.46, 0.60), Offset(0.86, 0.60)),
    WallSegment(Offset(0.66, 0.34), Offset(0.66, 0.60)),
    WallSegment(Offset(0.86, 0.34), Offset(0.86, 1.00), attenuationDb: 3.5),
  ],
);

const FloorPlanDef kPlanta03 = FloorPlanDef(
  id: 'planta_03',
  name: 'Planta 03 — Apartamento com Terraço',
  subtitle: 'Desenho provisório · aguardando planta_03.png',
  assetPath: 'assets/floorplans/planta_03.png',
  aspectRatio: 1.0,
  defaultWidthM: 10,
  rooms: [
    RoomDef('Varanda', Rect.fromLTWH(0.00, 0.00, 1.00, 0.22)),
    RoomDef('Quarto 1', Rect.fromLTWH(0.00, 0.22, 0.30, 0.40)),
    RoomDef('Sala de Estar', Rect.fromLTWH(0.30, 0.22, 0.40, 0.54)),
    RoomDef('Quarto 2', Rect.fromLTWH(0.70, 0.22, 0.30, 0.40)),
    RoomDef('Banheiro', Rect.fromLTWH(0.00, 0.62, 0.30, 0.14)),
    RoomDef('Banheiro', Rect.fromLTWH(0.70, 0.62, 0.30, 0.14)),
    RoomDef('Quarto 3', Rect.fromLTWH(0.00, 0.76, 0.30, 0.24)),
    RoomDef('Cozinha', Rect.fromLTWH(0.30, 0.76, 0.70, 0.24)),
  ],
  wallSegments: [
    WallSegment(Offset(0.00, 0.22), Offset(1.00, 0.22), attenuationDb: 3.5),
    WallSegment(Offset(0.30, 0.22), Offset(0.30, 1.00)),
    WallSegment(Offset(0.70, 0.22), Offset(0.70, 0.76)),
    WallSegment(Offset(0.00, 0.62), Offset(0.30, 0.62)),
    WallSegment(Offset(0.70, 0.62), Offset(1.00, 0.62)),
    WallSegment(Offset(0.00, 0.76), Offset(1.00, 0.76)),
  ],
);

// Planta 04: mais um modelo residencial padrão (apartamento de 3 suítes),
// para ampliar as opções da biblioteca — desenho vetorial próprio.
const FloorPlanDef kPlanta04 = FloorPlanDef(
  id: 'planta_04',
  name: 'Planta 04 — Apartamento 3 Suítes',
  subtitle: 'Desenho provisório · aguardando planta_04.png',
  assetPath: 'assets/floorplans/planta_04.png',
  aspectRatio: 1.6,
  defaultWidthM: 15,
  rooms: [
    RoomDef('Cozinha', Rect.fromLTWH(0.00, 0.00, 0.28, 0.40)),
    RoomDef('Sala de Jantar', Rect.fromLTWH(0.28, 0.00, 0.30, 0.40)),
    RoomDef('Sala de Estar', Rect.fromLTWH(0.58, 0.00, 0.42, 0.40)),
    RoomDef('Quarto 1 (Suíte)', Rect.fromLTWH(0.00, 0.40, 0.34, 0.46)),
    RoomDef('Banheiro', Rect.fromLTWH(0.00, 0.86, 0.34, 0.14)),
    RoomDef('Quarto 2', Rect.fromLTWH(0.34, 0.40, 0.33, 0.60)),
    RoomDef('Quarto 3', Rect.fromLTWH(0.67, 0.40, 0.33, 0.60)),
  ],
  wallSegments: [
    WallSegment(Offset(0.28, 0.00), Offset(0.28, 0.40)),
    WallSegment(Offset(0.58, 0.00), Offset(0.58, 0.40)),
    WallSegment(Offset(0.00, 0.40), Offset(1.00, 0.40)),
    WallSegment(Offset(0.34, 0.40), Offset(0.34, 1.00)),
    WallSegment(Offset(0.67, 0.40), Offset(0.67, 1.00)),
    WallSegment(Offset(0.00, 0.86), Offset(0.34, 0.86), attenuationDb: 3.5),
  ],
);

// Prédio/escritório: sem imagem ainda (assets/floorplans/edificio_corporativo.png).
const FloorPlanDef kPlanEscritorio = FloorPlanDef(
  id: 'edificio_corporativo',
  name: 'Edifício Corporativo',
  subtitle: 'Open Space · Sala de Reunião · Diretoria · Copa',
  assetPath: 'assets/floorplans/edificio_corporativo.png',
  aspectRatio: 1.6,
  defaultWidthM: 20,
  rooms: [
    RoomDef('Open Space', Rect.fromLTWH(0.00, 0.00, 0.60, 1.00)),
    RoomDef('Sala de Reunião', Rect.fromLTWH(0.60, 0.00, 0.40, 0.40)),
    RoomDef('Diretoria', Rect.fromLTWH(0.60, 0.40, 0.40, 0.30)),
    RoomDef('Copa', Rect.fromLTWH(0.60, 0.70, 0.40, 0.30)),
  ],
  wallSegments: [
    WallSegment(Offset(0.60, 0.00), Offset(0.60, 1.00), attenuationDb: 10.0),
    WallSegment(Offset(0.60, 0.40), Offset(1.00, 0.40)),
    WallSegment(Offset(0.60, 0.70), Offset(1.00, 0.70)),
  ],
);

const List<ProjectDef> kProjectLibrary = [
  ProjectDef(
    id: 'casa_2q',
    name: 'Casa Térrea 2 Quartos',
    subtitle: '1 pavimento · 2 Quartos · Cozinha · Sala · Banheiro',
    floors: [FloorDef('Térreo', kPlanCasa2q)],
  ),
  ProjectDef(
    id: 'casa_2_pavimentos',
    name: 'Casa 2 Pavimentos (Referência)',
    subtitle: '2 pavimentos · modelo de referência para casas de dois andares',
    floors: [
      FloorDef('Térreo', kPlanCasa2pTerreo),
      FloorDef('1º Andar', kPlanCasa2pAndar),
    ],
  ),
  ProjectDef(
    id: 'planta_01',
    name: 'Planta 01 — Apartamento 3 Quartos',
    subtitle: '1 pavimento · desenho provisório (aguardando planta_01.png)',
    floors: [FloorDef('Térreo', kPlanta01)],
  ),
  ProjectDef(
    id: 'planta_02',
    name: 'Planta 02 — Apartamento Open Space',
    subtitle: '1 pavimento · desenho provisório (aguardando planta_02.png)',
    floors: [FloorDef('Térreo', kPlanta02)],
  ),
  ProjectDef(
    id: 'planta_03',
    name: 'Planta 03 — Apartamento com Terraço',
    subtitle: '1 pavimento · desenho provisório (aguardando planta_03.png)',
    floors: [FloorDef('Térreo', kPlanta03)],
  ),
  ProjectDef(
    id: 'planta_04',
    name: 'Planta 04 — Apartamento 3 Suítes',
    subtitle: '1 pavimento · desenho provisório (aguardando planta_04.png)',
    floors: [FloorDef('Térreo', kPlanta04)],
  ),
  ProjectDef(
    id: 'edificio',
    name: 'Edifício Corporativo',
    subtitle: '3 pavimentos · Open Space · Reunião · Diretoria · Copa',
    floors: [
      FloorDef('Térreo', kPlanEscritorio),
      FloorDef('1º Andar', kPlanEscritorio),
      FloorDef('2º Andar', kPlanEscritorio),
    ],
  ),
];


/// Plantas embutidas no app (para reabrir projetos salvos ou importados).
const List<FloorPlanDef> kBuiltInPlans = [
  kPlanCasa2q,
  kPlanCasa2pTerreo,
  kPlanCasa2pAndar,
  kPlanta01,
  kPlanta02,
  kPlanta03,
  kPlanta04,
  kPlanEscritorio,
];

FloorPlanDef? builtInPlanById(String id) {
  for (final p in kBuiltInPlans) {
    if (p.id == id) return p;
  }
  return null;
}
