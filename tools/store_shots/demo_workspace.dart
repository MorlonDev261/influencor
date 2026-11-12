// Workspace for the Play Store screenshots.
//
// When build/store_shots/phone/Pôma Original exists (a copy of the phone's
// workspace, see docs/developer/release/play-store.md), the screenshots use
// that real workspace, copied again to a temporary folder so the app never
// touches it; only a few favorites and a Degany conversation are added.
// Otherwise a made-up creator's workspace is used (photos from
// tools/store_shots/make_photos.mjs).
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class DemoWorkspace {
  DemoWorkspace._(this.root, this.support);

  final String root;
  final String support;

  String path(String rel) => p.joinAll([root, ...rel.split('/')]);

  static String featuredNote = 'Légende lancement collection.md';
  static String featuredFolder = 'Campagne Été 2026';

  static const phoneFavorites = [
    'iPhone 15 Pro Max/message.md',
    'iPhone 15 Pro Max/iphone_15_pro_max_05_hero_marketing.jpg',
    'iPhone 14 Pro/iphone_14_pro_01_collection.jpg',
    'iPhone 13 Pro Max/iphone_13_pro_max_03_flat_lay_luxe.jpg',
    'Mirianno.md',
    'OFFICIAL.png',
    'iPhone 15/iphone_15_02_lifestyle_main_montre.jpg',
  ];

  static const notes = <String, String>{
    'Légende lancement collection.md': '''Elle est enfin là ! 🌺 Notre nouvelle collection Nosy Be sort ce vendredi à 18 h.

✨ Tissus légers, cousus à Antananarivo
🎨 6 couleurs inspirées des plages du Nord
🚚 Livraison offerte jusqu'à dimanche

👉 Le lien est dans la bio pour découvrir toutes les pièces.

#ModeMalagasy #Été2026 #NosyBe #CréateurLocal''',
    'Idées de Reels.md': '''1. Avant / après : la table du petit-déjeuner
2. 3 façons de porter le lamba
3. Les coulisses du shooting à Ambohimanga
4. Question du jour : votre plage préférée ?
5. Tuto : retoucher une photo en 30 secondes''',
    'Hashtags favoris.md': '''#Madagascar #Antananarivo #MadeInMada
#ModeMalagasy #CuisineMalgache #VoyageMadagascar
#NosyBe #Baobab #CréateurDeContenu''',
  };

  /// Workspace-relative path -> photo in build/store_shots/photos.
  static const photos = <String, String>{
    'Campagne Été 2026/Coucher de soleil.jpg': 'sunset.jpg',
    'Campagne Été 2026/Tissu lamba.jpg': 'fashion.jpg',
    'Campagne Été 2026/Look plage.jpg': 'look.jpg',
    'Campagne Été 2026/Savon vanille.jpg': 'product.jpg',
    'Campagne Été 2026/Lagon de Nosy Be.jpg': 'lagoon.jpg',
    'Recettes/Romazava.jpg': 'food.jpg',
    'Recettes/Mofo gasy.jpg': 'pastry.jpg',
    'Allée des baobabs.jpg': 'baobab.jpg',
    'Café du matin.jpg': 'coffee.jpg',
    'Plage de Nosy Be.jpg': 'lagoon.jpg',
    'Shooting savon vanille.jpg': 'product.jpg',
  };

  static const favorites = [
    'Légende lancement collection.md',
    'Idées de Reels.md',
    'Allée des baobabs.jpg',
    'Plage de Nosy Be.jpg',
    'Campagne Été 2026/Tissu lamba.jpg',
    'Campagne Été 2026/Coucher de soleil.jpg',
    'Recettes/Romazava.jpg',
  ];

  static void _copyTree(Directory from, Directory to) {
    to.createSync(recursive: true);
    for (final e in from.listSync(followLinks: false)) {
      final target = p.join(to.path, p.basename(e.path));
      if (e is Directory) {
        _copyTree(e, Directory(target));
      } else if (e is File) {
        e.copySync(target);
        File(target).setLastModifiedSync(e.lastModifiedSync());
      }
    }
  }

  static Future<DemoWorkspace> create(String base,
      {required String photosDir, String? phoneDir}) async {
    final support = p.join(base, 'support');
    Directory(support).createSync(recursive: true);
    if (phoneDir != null && Directory(phoneDir).existsSync()) {
      final root = p.join(base, p.basename(phoneDir));
      _copyTree(Directory(phoneDir), Directory(root));
      final ws = DemoWorkspace._(root, support);
      featuredNote = 'iPhone 15 Pro Max/message.md';
      featuredFolder = 'iPhone 15 Pro Max';
      final metaFile = File(ws.path('.clipboard/metadata.json'));
      final meta = metaFile.existsSync()
          ? (jsonDecode(metaFile.readAsStringSync()) as Map).cast<String, dynamic>()
          : <String, dynamic>{};
      for (final f in phoneFavorites) {
        if (!File(ws.path(f)).existsSync()) continue;
        final m = (meta[f] as Map?)?.cast<String, dynamic>() ?? {'tags': <String>[]};
        meta[f] = {...m, 'favorite': true};
      }
      metaFile
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(jsonEncode(meta));
      ws._writeSupport(pomaChat: true);
      return ws;
    }

    final root = p.join(base, 'Influencor');
    final ws = DemoWorkspace._(root, support);
    Directory(root).createSync(recursive: true);
    final now = DateTime.now();

    for (final f in ['Campagne Été 2026', 'Recettes']) {
      Directory(ws.path(f)).createSync(recursive: true);
    }
    notes.forEach((name, body) => File(ws.path(name)).writeAsStringSync(body));
    File(ws.path('Campagne Été 2026/Planning publications.md')).writeAsStringSync(
        'Lundi : teaser\nMercredi : Reel coulisses\nVendredi : lancement');
    File(ws.path('Recettes/Liste de courses.md'))
        .writeAsStringSync('- Brèdes mafana\n- Zébu\n- Gingembre\n- Riz');

    var i = 0;
    photos.forEach((rel, src) {
      final from = File(p.join(photosDir, src));
      if (!from.existsSync()) return;
      final to = File(ws.path(rel));
      from.copySync(to.path);
      to.setLastModifiedSync(now.subtract(Duration(hours: i++ * 5)));
    });

    void json(String rel, Object data) {
      final f = File(p.isAbsolute(rel) ? rel : ws.path(rel));
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(jsonEncode(data));
    }

    json('.clipboard/metadata.json', {
      for (final f in favorites) f: {'favorite': true, 'tags': <String>[]},
    });

    // Accounting: the current month, mobile money and cash.
    final start = DateTime(now.year, now.month, 1);
    DateTime day(int d, int h) => start.add(Duration(days: d, hours: h));
    var n = 0;
    Map<String, Object> entry(DateTime date, int amount, String account,
            String type, String direction, String note) =>
        {
          'id': 'e${n++}',
          'date': date.toIso8601String(),
          'amount': amount,
          'account': account,
          'type': type,
          'direction': direction,
          'note': note,
          'sheet': 's1',
        };
    json('.clipboard/accounting.json', {
      'version': 2,
      'sheets': [
        {'id': 's1', 'start': start.toIso8601String()},
      ],
      'entries': [
        entry(day(0, 9), 450000, 'mvola', 'sale', 'credit', 'Partenariat savons vanille'),
        entry(day(1, 15), 85000, 'orangeMoney', 'expense', 'debit', 'Forfait internet'),
        entry(day(2, 11), 320000, 'airtelMoney', 'sale', 'credit', 'Reel Hôtel Nosy Be'),
        entry(day(3, 10), 120000, 'cash', 'purchase', 'debit', 'Tissus pour le shooting'),
        entry(day(4, 16), 600000, 'orangeMoney', 'sale', 'credit', 'Campagne mode été'),
        entry(day(5, 8), 45000, 'mvola', 'expense', 'debit', 'Transport Ambohimanga'),
        entry(day(6, 14), 180000, 'cash', 'sale', 'credit', 'Vente photos'),
      ],
    });

    // Tasks.
    var t = 0;
    Map<String, Object> task(String title, List<(String, bool)> items, int hoursAgo) {
      final id = 't${t++}';
      final at = now.subtract(Duration(hours: hoursAgo)).toIso8601String();
      return {
        'id': id,
        'title': title,
        'createdAt': at,
        'updatedAt': at,
        'blocks': [
          {
            'id': '${id}b',
            'type': 'checklist',
            'text': '',
            'items': [
              for (final (k, (text, done)) in items.indexed)
                {'id': '$id$k', 'text': text, 'done': done},
            ],
          },
        ],
      };
    }

    for (final doc in [
      task('Lancement collection Nosy Be', [
        ('Shooting photo à la plage', true),
        ('Écrire les légendes', true),
        ('Monter le Reel coulisses', false),
        ('Programmer la publication', false),
      ], 2),
      task('Partenariat savons vanille', [
        ('Envoyer le devis', true),
        ('Recevoir les produits', true),
        ('Story déballage', false),
      ], 20),
      task('Vlog marché d\'Analakely', [
        ('Préparer le script', true),
        ('Tournage samedi matin', false),
        ('Sous-titres FR / MG', false),
      ], 50),
    ]) {
      json('.clipboard/tasks/${doc['id']}.json', doc);
    }

    ws._writeSupport(pomaChat: false);
    return ws;
  }

  void _json(String file, Object data) {
    final f = File(file);
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(jsonEncode(data));
  }

  /// Settings, workspace choice and Degany (app support directory).
  void _writeSupport({required bool pomaChat}) {
    // Settings and workspace (app support directory).
    _json(p.join(support, 'clipboard_config.json'), {'rootPath': root});
    _json(p.join(support, 'clipboard_settings.json'), {
      'themeMode': 'light',
      'viewMode': 'grid',
      'languageCode': 'fr',
      'reseller': false,
      'appMode': 'clipboard',
    });

    // Degany: a configured provider (demo key, never used: nothing is sent)
    // and one saved conversation.
    _json(p.join(support, 'assistant_settings.json'), {
      'provider': 'openai',
      'providers': {
        'openai': {'apiKey': 'demo', 'model': 'gpt-5', 'baseUrl': ''},
      },
    });
    final now = DateTime.now();
    final t0 = now.subtract(const Duration(minutes: 3));
    String at(int s) => t0.add(Duration(seconds: s)).toIso8601String();
    if (pomaChat) {
      _json(p.join(support, 'assistant_chats', 'c1.json'), {
        'version': 2,
        'title': 'Annonce iPhone 15 Pro Max',
        'createdAt': at(0),
        'updatedAt': at(20),
        'items': [
          {
            'kind': 'user',
            'text': 'Prépare une annonce courte pour l\'iPhone 15 Pro Max à partir '
                'de son message, avec les prix, et mets-la en favori.',
          },
          {
            'kind': 'tool',
            'toolName': 'read_note',
            'text': 'Lecture de « iPhone 15 Pro Max / message »',
            'args': {'path': 'iPhone 15 Pro Max/message.md'},
            'result': 'Note lue',
            'status': 'done',
            'startedAt': at(2),
            'endedAt': at(3),
          },
          {
            'kind': 'tool',
            'toolName': 'set_favorite',
            'text': 'Ajout aux favoris',
            'args': {'path': 'iPhone 15 Pro Max/message.md', 'favorite': true},
            'result': 'Favori ajouté',
            'status': 'done',
            'startedAt': at(6),
            'endedAt': at(7),
          },
          {
            'kind': 'assistant',
            'text': 'Voici ton annonce, prête à copier :\n\n'
                '> **iPhone 15 Pro Max** — état impeccable\n'
                '> Batterie originale +80 % · Face ID OK\n'
                '> Sous carton, avec facture · Garantie 2 semaines\n'
                '> Disponible dès maintenant chez Pôma Original !\n\n'
                'La note est aussi dans tes **favoris**. Je la partage sur '
                'WhatsApp ?',
          },
        ],
        'history': [],
      });
      _json(p.join(support, 'assistant_chats', 'current.json'), {'id': 'c1'});
      return;
    }
    _json(p.join(support, 'assistant_chats', 'c1.json'), {
      'version': 2,
      'title': 'Légende pour la photo de Nosy Be',
      'createdAt': at(0),
      'updatedAt': at(20),
      'items': [
        {
          'kind': 'user',
          'text': 'Écris une légende Instagram pour ma photo de la plage de Nosy Be '
              'et range-la dans « Campagne Été 2026 ».',
        },
        {
          'kind': 'tool',
          'toolName': 'search_library',
          'text': 'Recherche « Plage de Nosy Be »',
          'args': {'query': 'Plage de Nosy Be'},
          'result': '1 résultat',
          'status': 'done',
          'startedAt': at(2),
          'endedAt': at(3),
        },
        {
          'kind': 'tool',
          'toolName': 'create_note',
          'text': 'Création de la note « Légende Nosy Be »',
          'args': {'name': 'Légende Nosy Be', 'folder': 'Campagne Été 2026'},
          'result': 'Note créée',
          'status': 'done',
          'startedAt': at(8),
          'endedAt': at(9),
        },
        {
          'kind': 'assistant',
          'text': 'C\'est fait ! La note **Légende Nosy Be** est dans '
              '*Campagne Été 2026* :\n\n'
              '> Eau turquoise, sable chaud et voile au vent… 🌊 Nosy Be, '
              'c\'est le paradis à deux pas de chez nous. Qui part avec moi ? ⛵\n'
              '> \n> #NosyBe #Madagascar #Été2026\n\n'
              'Tu veux une version plus courte pour les stories ?',
        },
      ],
      'history': [],
    });
    _json(p.join(support, 'assistant_chats', 'current.json'), {'id': 'c1'});
  }
}
