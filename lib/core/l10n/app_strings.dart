import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/cleaner/domain/clean_report.dart';
import '../providers/settings_providers.dart';

/// Lightweight, dependency-free localisation for the MVP. Easily replaceable
/// by flutter_localizations / ARB later.
class AppStrings {
  const AppStrings(this.locale);

  final Locale locale;

  bool get _isMg => locale.languageCode == 'mg';
  bool get _isEn => locale.languageCode == 'en';
  String _t(String fr, String en, {String? mg}) =>
      _isMg ? mg ?? fr : (_isEn ? en : fr);

  String get appName => 'Influencor';

  // Navigation
  String get home => _t('Accueil', 'Home', mg: 'Fandraisana');
  String get search => _t('Recherche', 'Search', mg: 'Karoka');
  String get trash => _t('Corbeille', 'Trash', mg: 'Fako');
  String get settings => _t('Réglages', 'Settings', mg: 'Parametra');
  String get favorites => _t('Favoris', 'Favorites', mg: 'Tiana');
  String get library => _t('Bibliothèque', 'Library', mg: 'Tahiry');

  /// The AI agent's name (tab, chat, settings).
  String get assistant => 'Degany';

  // Assistant (chat)
  String get assistantIntro => _t(
        'Demandez-moi de chercher, ranger, créer des notes ou des tableaux, '
            'nettoyer des photos avec Deganeo, gérer vos tâches et votre '
            'comptabilité…',
        'Ask me to search, organise, write notes or tables, clean photos with '
            'Deganeo, manage your tasks and accounting…',
        mg: 'Angataho aho hikaroka, handamina, hanoratra naoty na tabilao, '
            'hanadio sary amin\'ny Deganeo, hitantana ny asa sy ny kaonty…',
      );
  String get assistantHint =>
      _t('Écrivez un message…', 'Write a message…', mg: 'Manorata hafatra…');
  String get assistantNotConfigured => _t(
        'Connectez votre IA préférée (ChatGPT, Claude, Gemini, DeepSeek…) '
            'avec votre propre clé API pour activer Degany.',
        'Connect your favourite AI (ChatGPT, Claude, Gemini, DeepSeek…) with '
            'your own API key to enable Degany.',
        mg: 'Ampifandraiso ny IA tianao (ChatGPT, Claude, Gemini, DeepSeek…) '
            'amin\'ny lakile API anao.',
      );
  String get assistantConnect =>
      _t('Connecter une IA', 'Connect an AI', mg: 'Hampifandray IA');
  String get assistantSettings =>
      _t('Degany (IA)', 'Degany (AI)', mg: 'Degany (IA)');
  String get assistantSettingsHint => _t(
        'Fournisseur, clé API, modèle',
        'Provider, API key, model',
        mg: 'Mpamatsy, lakile API, modely',
      );
  String get newConversation =>
      _t('Nouvelle conversation', 'New conversation', mg: 'Resaka vaovao');
  String get stop => _t('Arrêter', 'Stop', mg: 'Atsaharo');
  String get thinking => _t('Réflexion', 'Thinking', mg: 'Fisainana');
  String get attach => _t('Joindre', 'Attach', mg: 'Ampiarahina');
  String get attachMedia =>
      _t('Photos et vidéos', 'Photos and videos', mg: 'Sary sy horonan-tsary');
  String get attachFiles => _t('Fichiers', 'Files', mg: 'Rakitra');
  String get answerHint =>
      _t('Votre réponse…', 'Your answer…', mg: 'Ny valinao…');
  String get attachedFiles =>
      _t('Fichiers joints', 'Attached files', mg: 'Rakitra miaraka');

  // Degany — messages and errors
  String get deganyNotConfigured => _t(
        "Connectez d'abord un modèle d'IA dans les réglages de Degany "
            '(fournisseur, clé API, modèle).',
        'First connect an AI model in Degany’s settings (provider, API key, '
            'model).',
        mg: 'Ampifandraiso aloha ny modely IA ao amin’ny parametr’i Degany '
            '(mpamatsy, lakile API, modely).',
      );
  String get deganyTooManySteps => _t(
        "Arrêt : trop d'étapes pour une seule demande. Envoyez « continue » "
            'pour poursuivre.',
        'Stopped: too many steps for one request. Send “continue” to go on.',
        mg: 'Nijanona: be loatra ny dingana. Alefaso « continue » raha hanohy.',
      );
  String get deganyRefused => _t(
        'Le modèle a refusé de traiter cette demande. Reformulez-la ou '
            'essayez un autre modèle.',
        'The model declined this request. Rephrase it or try another model.',
        mg: 'Nolavin’ny modely ity fangatahana ity. Avereno amin’ny teny hafa '
            'na andramo modely hafa.',
      );
  String get deganyStopped => _t('Arrêté.', 'Stopped.', mg: 'Natsahatra.');
  String deganyError(Object e) =>
      _t('Erreur : $e', 'Error: $e', mg: 'Hadisoana: $e');
  String get deganyContextTrimmed => _t(
        'Conversation longue : les plus anciens échanges ne sont plus envoyés '
            'au modèle.',
        'Long conversation: the oldest exchanges are no longer sent to the '
            'model.',
        mg: 'Resaka lava: tsy alefa amin’ny modely intsony ny fifanakalozana '
            'taloha indrindra.',
      );
  String get llmInsecureUrl => _t(
      'Adresse refusée : la clé API et la conversation passeraient en clair '
          'sur le réseau. Utilisez https:// (http:// seulement pour un modèle '
          'local : localhost, 127.0.0.1).',
      'Address refused: the API key and the conversation would travel '
          'unencrypted. Use https:// (http:// only for a local model: '
          'localhost, 127.0.0.1).',
      mg: 'Adiresy nolavina: handeha tsy voaaro amin’ny tambajotra ny lakile '
          'API sy ny resaka. Ampiasao https:// (http:// ho an’ny modely eo '
          'an-toerana ihany: localhost, 127.0.0.1).');
  String get keysInPlainTextTitle =>
      _t('Clé API non protégée', 'API key not protected',
          mg: 'Lakile API tsy voaaro');
  String get keysInPlainTextMessage => _t(
      'Le coffre sécurisé du système est indisponible sur cet appareil : la '
          'clé est enregistrée en clair dans les fichiers de l’app (jamais '
          'dans votre dossier de travail). Elle sera déplacée dans le coffre '
          'dès qu’il fonctionnera.',
      'The system’s secure storage is unavailable on this device: the key is '
          'saved in clear in the app’s files (never in your workspace). It '
          'moves to the secure storage as soon as that works.',
      mg: 'Tsy misy ny fitahirizana voaaro an’ny rafitra amin’ity fitaovana '
          'ity: voatahiry tsy miafina ao amin’ny rakitry ny app ny lakile '
          '(tsy ao amin’ny dossier fiasanao mihitsy).');
  String get llmTimeout => _t('Le service ne répond pas (délai dépassé).',
      'The service is not responding (timed out).',
      mg: 'Tsy mamaly ny service (lany fotoana).');
  String llmConnection(String detail) =>
      _t('Connexion impossible : $detail', 'Cannot connect: $detail',
          mg: 'Tsy afaka mifandray: $detail');
  String llmInterrupted(String detail) =>
      _t('Connexion interrompue : $detail', 'Connection lost: $detail',
          mg: 'Tapaka ny fifandraisana: $detail');
  String get llmStalled => _t('Le service a cessé de répondre (délai dépassé).',
      'The service stopped responding (timed out).',
      mg: 'Nitsahatra namaly ny service (lany fotoana).');
  String get llmEmptyReply =>
      _t('Réponse vide du modèle.', 'Empty reply from the model.',
          mg: 'Valiny foana avy amin’ny modely.');
  String get llmUnexpectedReply =>
      _t('Réponse inattendue du service.', 'Unexpected reply from the service.',
          mg: 'Valiny tsy nampoizina avy amin’ny service.');
  String get llmServiceError =>
      _t('Erreur du service.', 'Service error.', mg: 'Hadisoan’ny service.');
  String get llmHintAuth => _t(
      'Vérifiez la clé API dans les réglages de Degany.',
      'Check the API key in Degany’s settings.',
      mg: 'Hamarino ny lakile API ao amin’ny parametr’i Degany.');
  String get llmHintNotFound => _t(
      'Vérifiez le nom du modèle et l’adresse du service.',
      'Check the model name and the service URL.',
      mg: 'Hamarino ny anaran’ny modely sy ny adiresin’ny service.');
  String get llmHintRateLimit => _t(
      'Quota ou limite de débit atteint : réessayez plus tard.',
      'Quota or rate limit reached: try again later.',
      mg: 'Tratra ny fetra: andramo indray any aoriana.');

  // Degany — one-line action results
  String toolResults(Object? n) =>
      _t('$n résultat(s)', '$n result(s)', mg: 'Valiny $n');
  String toolItems(Object? n) =>
      _t('$n élément(s)', '$n item(s)', mg: 'Singa $n');
  String toolFields(Object? n) => _t('$n champ(s)', '$n field(s)', mg: '$n');
  String get toolCreated => _t('Créé', 'Created', mg: 'Noforonina');
  String get toolSaved => _t('Enregistré', 'Saved', mg: 'Voatahiry');
  String get toolRenamed => _t('Renommé', 'Renamed', mg: 'Novana anarana');
  String get toolCopy => _t('Copie', 'Copy', mg: 'Dika');
  String get toolOpened => _t('Ouvert', 'Opened', mg: 'Nosokafana');
  String get toolDeleted => _t('Supprimé', 'Deleted', mg: 'Voafafa');
  String get toolDenied => _t('Refusé', 'Denied', mg: 'Nolavina');
  String toolMoved(Object? n) =>
      _t('$n déplacé(s)', '$n moved', mg: '$n nafindra');
  String toolTrashed(Object? n) =>
      _t('$n à la corbeille', '$n moved to trash', mg: '$n tany am-pako');
  String toolRestored(Object? n) =>
      _t('$n restauré(s)', '$n restored', mg: '$n naverina');
  String toolImported(Object? n) =>
      _t('$n importé(s)', '$n imported', mg: '$n nampidirina');
  String toolSettingsChanged(Object? n) =>
      _t('$n réglage(s) modifié(s)', '$n setting(s) changed',
          mg: 'Parametra $n novaina');
  String toolSensitive(Object? n) =>
      _t('$n métadonnée(s) sensible(s)', '$n sensitive metadata item(s)',
          mg: 'Metadata saro-pady $n');
  String toolCharacters(Object? n) =>
      _t('$n caractères', '$n characters', mg: 'Litera $n');
  String toolRows(Object? n) =>
      _t('$n ligne(s)', '$n row(s)', mg: 'Andalana $n');
  String toolNet(Object? n) =>
      _t('Résultat net : $n Ar', 'Net result: $n Ar', mg: 'Vokatra: $n Ar');
  String toolCheapest(Object? op, Object? fee) =>
      _t('Le moins cher : $op ($fee Ar)', 'Cheapest: $op ($fee Ar)',
          mg: 'Mora indrindra: $op ($fee Ar)');
  String get assistantWorking =>
      _t('Je travaille…', 'Working…', mg: 'Miasa aho…');
  String get llmProvider => _t('Fournisseur', 'Provider', mg: 'Mpamatsy');
  String get apiKey => _t('Clé API', 'API key', mg: 'Lakile API');
  String get apiKeyLocal => _t(
        'Enregistrée uniquement sur cet appareil. Les messages sont envoyés '
            'directement au fournisseur choisi.',
        'Stored on this device only. Messages go straight to the chosen '
            'provider.',
        mg: 'Voatahiry eto amin\'ity fitaovana ity ihany.',
      );
  String get getApiKey => _t('Obtenir une clé', 'Get a key', mg: 'Haka lakile');
  String get llmModel => _t('Modèle', 'Model', mg: 'Modely');
  String get llmBaseUrl =>
      _t('Adresse du service', 'Service URL', mg: 'Adiresin\'ny service');
  String get llmBaseUrlHint => _t(
        'Laisser vide pour l’adresse par défaut',
        'Leave empty for the default URL',
        mg: 'Avelao ho foana raha adiresy mahazatra',
      );
  String get loadModels =>
      _t('Charger les modèles', 'Load models', mg: 'Hampiditra modely');
  String get testConnection => _t('Tester la connexion', 'Test connection',
      mg: 'Andramo ny fifandraisana');
  String get connectionOk =>
      _t('Connexion réussie ✓', 'Connection works ✓', mg: 'Mandeha ✓');
  String get confirmDestructive => _t(
        'Demander avant de supprimer ou remplacer',
        'Ask before deleting or replacing',
        mg: 'Manontany alohan\'ny hamafana',
      );
  String get confirmDestructiveHint => _t(
        'Corbeille, suppression définitive, remplacement d’un original…',
        'Trash, permanent deletion, replacing an original…',
        mg: 'Fako, famafana tanteraka…',
      );
  String get allow => _t('Autoriser', 'Allow', mg: 'Avela');
  String get deny => _t('Refuser', 'Deny', mg: 'Lavina');
  String get copyPath =>
      _t('Copier le chemin', 'Copy path', mg: 'Adikao ny lalana');
  String get pathCopied =>
      _t('Chemin copié', 'Path copied', mg: 'Voadika ny lalana');
  String get itemNotFound =>
      _t('Élément introuvable', 'Item not found', mg: 'Tsy hita');
  List<String> get assistantSuggestions => _isEn
      ? const [
          'What is in my library?',
          'Find my notes about prices',
          'Clean the metadata of my latest photos',
          'This month’s accounting summary',
        ]
      : _isMg
          ? const [
              'Inona no ao amin\'ny tahiriko?',
              'Tadiavo ny naoty momba ny vidiny',
              'Diovy ny metadata amin\'ny sary farany',
              'Tatitra kaonty amin\'ity volana ity',
            ]
          : const [
              'Qu’y a-t-il dans ma bibliothèque ?',
              'Trouve mes notes sur les prix',
              'Nettoie les métadonnées de mes dernières photos',
              'Bilan comptable de ce mois',
            ];
  String get removeExif => _t('Deganeo', 'Deganeo', mg: 'Deganeo');
  String get cleanMediaCta => _t(
        'Nettoyer pour publier',
        'Clean for publishing',
        mg: 'Diovy alohan\'ny famoahana',
      );
  String get chooseAnotherFile => _t(
        'Choisir un autre fichier',
        'Choose another file',
        mg: 'Misafidiana rakitra hafa',
      );

  // Deganeo — multi-file queue
  String get addFiles =>
      _t('Ajouter des fichiers', 'Add files', mg: 'Hanampy rakitra');
  String get cleanAll => _t('Tout nettoyer', 'Clean all', mg: 'Diovy daholo');
  String get downloadAll =>
      _t('Tout télécharger', 'Download all', mg: 'Alaina daholo');
  String get removeFromList => _t('Retirer de la liste', 'Remove from list',
      mg: "Esory amin'ny lisitra");
  String get searchMetadata =>
      _t('Rechercher une balise (GPS, Date…)', 'Search a tag (GPS, Date…)',
          mg: 'Karohy tag (GPS, Daty…)');
  String get inspectingFile =>
      _t('Lecture des métadonnées…', 'Reading metadata…',
          mg: 'Famakiana ny metadata…');
  String get noMetadataFound => _t(
      'Aucune métadonnée sensible détectée.', 'No sensitive metadata detected.',
      mg: 'Tsy hita metadata saro-pady.');
  String metadataFoundCount(int n) => _t(
        '$n métadonnée(s) détectée(s)',
        '$n metadata item(s) found',
        mg: 'Metadata hita: $n',
      );
  String tooManyFiles(int max) => _t(
        'Maximum $max fichiers à la fois : les suivants ont été ignorés.',
        'Maximum $max files at a time: the rest were ignored.',
        mg: 'Rakitra $max no azo ampiasaina indray mandeha: nafoy ny sisa.',
      );
  String filesSaved(int n) => _t(
        '$n fichier(s) enregistré(s)',
        '$n file(s) saved',
        mg: 'Rakitra voatahiry: $n',
      );
  String get chooseDestinationFolder =>
      _t('Choisir le dossier de destination', 'Choose the destination folder',
          mg: 'Misafidiana ny lahatahiry');

  // Deganeo — library flow (one image at a time)
  String get deganeoReplaceOriginal => _t(
        "Remplacer l'original",
        'Replace original',
        mg: 'Soloina ny tany am-boalohany',
      );
  String get deganeoKeepCopy =>
      _t('Garder une copie', 'Keep a copy', mg: 'Tehirizo kopia');
  String get deganeoSkip => _t('Ignorer', 'Skip', mg: 'Avelao');
  String deganeoProgress(int i, int n) => _t(
        'Image $i sur $n',
        'Image $i of $n',
        mg: "Sary $i amin'ny $n",
      );
  String deganeoSummary(int replaced, int copied) => _t(
        '$replaced remplacée(s), $copied copie(s) créée(s)',
        '$replaced replaced, $copied copy(ies) created',
        mg: 'Voasolo: $replaced, kopia noforonina: $copied',
      );

  // Metadata cleaner report
  String cleanStatusTitle(CleanStatus status) => switch (status) {
        CleanStatus.verifiedClean => _t(
            'Nettoyage vérifié',
            'Cleaning verified',
            mg: 'Voamarina ny fanadiovana',
          ),
        CleanStatus.cleanedWithCaveats => _t(
            'Nettoyé, avec réserves',
            'Cleaned, with caveats',
            mg: 'Voadio, misy fepetra',
          ),
        CleanStatus.residualFound => _t(
            'Nettoyage partiel : des métadonnées peuvent subsister',
            'Partial cleaning: some metadata may remain',
            mg: 'Fanadiovana ampahany: mety mbola misy metadata',
          ),
        CleanStatus.unsupported => _t(
            'Format non pris en charge',
            'Unsupported format',
            mg: 'Tsy tohanana ny karazana rakitra',
          ),
        CleanStatus.failed => _t(
            'Échec du nettoyage',
            'Cleaning failed',
            mg: 'Tsy nahomby ny fanadiovana',
          ),
      };

  String cleanStatusDetail(CleanStatus status) => switch (status) {
        CleanStatus.verifiedClean => _t(
            'Une nouvelle analyse indépendante du fichier nettoyé ne détecte '
                'plus de métadonnées sensibles.',
            'An independent re-scan of the cleaned file finds no more '
                'sensitive metadata.',
            mg: 'Ny fandinihana vaovao ny rakitra voadio dia tsy mahita '
                'metadata saro-pady intsony.',
          ),
        CleanStatus.cleanedWithCaveats => _t(
            'Aucune métadonnée sensible détectée après nettoyage, mais '
                'certaines limites s’appliquent (voir ci-dessous).',
            'No sensitive metadata detected after cleaning, but some limits '
                'apply (see below).',
            mg: 'Tsy misy metadata saro-pady hita aorian’ny fanadiovana, '
                'saingy misy fetra (jereo etsy ambany).',
          ),
        CleanStatus.residualFound => _t(
            'N’utilisez pas ce fichier pour une publication sensible. '
                'Convertissez-le en JPEG/PNG puis nettoyez-le à nouveau.',
            'Do not use this file for anything sensitive. Convert it to '
                'JPEG/PNG and clean it again.',
            mg: 'Aza ampiasaina amin’ny zavatra saro-pady ity rakitra ity. '
                'Ovay ho JPEG/PNG dia diovy indray.',
          ),
        CleanStatus.unsupported => _t(
            'Ce fichier ne peut pas être nettoyé sans risque de l’abîmer '
                '(format inconnu, RAW ou fichier chiffré). Il n’a pas été '
                'modifié. Exportez-le en JPEG, PNG, MP4 ou PDF non chiffré.',
            'This file cannot be cleaned without risking damage (unknown '
                'format, RAW or encrypted). It was not modified. Export it as '
                'JPEG, PNG, MP4 or an unencrypted PDF.',
            mg: 'Tsy azo diovina tsy hisy fahasimbana ity rakitra ity '
                '(karazana tsy fantatra, RAW na voafeno). Tsy novana izy. '
                'Avoahy ho JPEG, PNG, MP4 na PDF tsy voafeno.',
          ),
        CleanStatus.failed => _t(
            'Le fichier est peut-être corrompu. Il n’a pas été modifié.',
            'The file may be corrupt. It was not modified.',
            mg: 'Mety simba ny rakitra. Tsy novana izy.',
          ),
      };

  String cleanRemovedCount(int n) => _t(
        '$n type(s) de métadonnées supprimé(s)',
        '$n kind(s) of metadata removed',
        mg: '$n karazana metadata voafafa',
      );
  String get cleanTotalHeading => _t('Total', 'Total', mg: 'Rehetra');
  String get cleanHideValues => _t(
        'Masquer les valeurs',
        'Hide values',
        mg: 'Afeno ny soatoavina',
      );
  String get cleanShowValues => _t(
        'Afficher les valeurs',
        'Show values',
        mg: 'Asehoy ny soatoavina',
      );
  String get cleanRemovedHeading => _t('Supprimé', 'Removed', mg: 'Voafafa');
  String get cleanRemainingHeading =>
      _t('Encore présent', 'Still present', mg: 'Mbola eo');
  String get cleanKeptHeading => _t(
        'Conservé volontairement',
        'Kept on purpose',
        mg: 'Notehirizina an-tsitrapo',
      );
  String get cleanNothingFound => _t(
        'Aucune métadonnée détectée dans le fichier d’origine.',
        'No metadata detected in the original file.',
        mg: 'Tsy nahita metadata tao amin’ny rakitra tany am-boalohany.',
      );

  String metadataCategory(MetadataCategory c) => switch (c) {
        MetadataCategory.gps =>
          _t('Position GPS', 'GPS location', mg: 'Toerana GPS'),
        MetadataCategory.device => _t(
            'Appareil / logiciel',
            'Device / software',
            mg: 'Fitaovana / rindrambaiko',
          ),
        MetadataCategory.dateTime =>
          _t('Dates et heures', 'Dates and times', mg: 'Daty sy ora'),
        MetadataCategory.exif => _t(
            'Autres champs EXIF',
            'Other EXIF fields',
            mg: 'Saha EXIF hafa',
          ),
        MetadataCategory.xmp => 'XMP',
        MetadataCategory.iptc => _t(
            'IPTC (légende, auteur)',
            'IPTC (caption, author)',
            mg: 'IPTC (lahatsoratra, mpamorona)',
          ),
        MetadataCategory.comment => _t(
            'Commentaires / texte',
            'Comments / text',
            mg: 'Fanamarihana / lahatsoratra',
          ),
        MetadataCategory.thumbnail => _t(
            'Miniatures intégrées',
            'Embedded thumbnails',
            mg: 'Sary kely tafiditra',
          ),
        MetadataCategory.provenance => _t(
            'Provenance (C2PA)',
            'Provenance (C2PA)',
            mg: 'Niandohan’ny rakitra (C2PA)',
          ),
        MetadataCategory.timedTrack => _t(
            'Piste de métadonnées (GPS, capteurs)',
            'Metadata track (GPS, sensors)',
            mg: 'Lalana metadata (GPS, sensor)',
          ),
        MetadataCategory.container => _t(
            'Blocs de métadonnées',
            'Metadata blocks',
            mg: 'Sakana metadata',
          ),
        MetadataCategory.trailingData => _t(
            'Données cachées / anciennes révisions',
            'Hidden data / old revisions',
            mg: 'Angona miafina / dikan-teny taloha',
          ),
        MetadataCategory.colorProfile =>
          _t('Profil couleur', 'Colour profile', mg: 'Mombamomba ny loko'),
        MetadataCategory.orientation =>
          _t('Orientation', 'Orientation', mg: 'Fitodika'),
      };

  String cleanCaveat(CleanCaveat c) => switch (c) {
        CleanCaveat.unsupportedCodecStream => _t(
            'Le codec de cette vidéo ne permet pas de vérifier les textes '
                'd’encodeur incrustés dans le flux (seuls H.264 et HEVC sont '
                'inspectés). Les métadonnées du conteneur sont nettoyées.',
            'This video’s codec does not allow checking encoder text embedded '
                'in the stream (only H.264 and HEVC are inspected). Container '
                'metadata is cleaned.',
            mg: 'Tsy azo hamarinina ny lahatsoratra encoder ao anaty '
                'horonan-tsary amin’ity codec ity (H.264 sy HEVC ihany no '
                'hojerena). Voadio ny metadata ivelany.',
          ),
        CleanCaveat.attachmentsKept => _t(
            'Des pièces jointes (polices, jaquette) sont conservées car les '
                'sous-titres peuvent en dépendre.',
            'Attachments (fonts, cover art) are kept because subtitles may '
                'depend on them.',
            mg: 'Notehirizina ny rakitra miaraka (endri-tsoratra, sary) '
                'satria mety miankina aminy ny subtitle.',
          ),
        CleanCaveat.orientationFlagKept => _t(
            'La rotation n’a pas pu être appliquée aux pixels de cette photo : '
                'un indicateur d’orientation minimal, sans donnée personnelle, '
                'est conservé pour qu’elle ne s’affiche pas de travers.',
            'The rotation could not be applied to this photo’s pixels: a '
                'minimal orientation flag, with no personal data, is kept so '
                'it does not show up sideways.',
            mg: 'Tsy afaka nampiharina tamin’ny pixel ny fihodinana: '
                'notehirizina ny marika fitodika kely indrindra, tsy misy '
                'angona manokana, mba tsy hiolakolaka ny sary.',
          ),
      };

  // About page & reseller access
  String get aboutTitle => _t('À propos', 'About', mg: 'Momba ny app');
  String get aboutTagline => _t(
        'Tout votre contenu prêt à publier, prêt à envoyer, prêt à vendre.',
        'All your content ready to publish, ready to send, ready to sell.',
        mg: 'Ny votoatinao rehetra vonona hamoaka, handefa ary hivarotra.',
      );
  String aboutVersion(String v) =>
      _t('Version $v', 'Version $v', mg: 'Dikan-teny $v');
  String get aboutWhatTitle =>
      _t('Qu’est-ce qu’Influencor ?', 'What is Influencor?',
          mg: 'Inona no atao hoe Influencor?');
  String get aboutWhatBody => _t(
        'Influencor est une bibliothèque personnelle pour les créateurs, '
            'community managers et vendeurs en ligne. Vos notes, images, '
            'vidéos et tableaux vivent dans un dossier de votre appareil, '
            'bien rangés, faciles à retrouver et prêts à partager.',
        'Influencor is a personal library for creators, community managers '
            'and online sellers. Your notes, images, videos and tables live '
            'in a folder on your device, neatly organised, easy to find and '
            'ready to share.',
        mg: 'Influencor dia tahirin-kevitra manokana ho an’ny mpamorona, '
            'community manager ary mpivarotra an-tserasera. Ny naoty, sary, '
            'horonantsary ary tabilao dia ao anaty lahatahiry iray ao amin’ny '
            'fitaovanao, voalamina tsara ary mora hita.',
      );
  String get aboutFeaturesTitle =>
      _t('Ce que vous pouvez faire', 'What you can do', mg: 'Izay azonao atao');
  String get aboutFeatureLibraryTitle =>
      _t('Une bibliothèque claire', 'A clear library', mg: 'Tahiry voalamina');
  String get aboutFeatureLibraryBody => _t(
        'Créez des dossiers, écrivez des notes, ajoutez des images et des '
            'vidéos, importez ou déplacez des fichiers, glissez-déposez sur '
            'ordinateur et collez des images depuis le presse-papiers.',
        'Create folders, write notes, add images and videos, import or move '
            'files, drag and drop on desktop and paste images from the '
            'clipboard.',
        mg: 'Mamoròna lahatahiry, manoratra naoty, manampy sary sy '
            'horonantsary, mampiditra na mamindra rakitra.',
      );
  String get aboutFeatureFindTitle =>
      _t('Retrouver vite', 'Find things fast', mg: 'Hitady haingana');
  String get aboutFeatureFindBody => _t(
        'Recherche insensible aux accents, filtres par type, favoris pour '
            'garder l’essentiel sous la main, corbeille pour restaurer un '
            'élément supprimé.',
        'Accent-insensitive search, filters by type, favorites to keep the '
            'essentials at hand, and a trash to restore anything you deleted.',
        mg: 'Fikarohana tsy miankina amin’ny tsipika, sivana araka ny '
            'karazana, tiana, ary fako hamerenana ny voafafa.',
      );
  String get aboutFeatureShareTitle =>
      _t('Partager et copier', 'Share and copy', mg: 'Mizara sy mandika');
  String get aboutFeatureShareBody => _t(
        'Partagez une légende avec ses images en un geste, copiez vos notes '
            'avec la mise en forme (gras, italique…) pour les coller où '
            'vous publiez.',
        'Share a caption together with its images in one tap, and copy your '
            'notes with formatting (bold, italic…) to paste wherever you '
            'publish.',
        mg: 'Zarao miaraka amin’ny sary ny lahatsoratra, ary adikao miaraka '
            'amin’ny endrika (matevina, mitsangana…).',
      );
  String get aboutFeatureCleanerTitle =>
      _t('Deganeo : nettoyer les métadonnées', 'Deganeo: clean metadata',
          mg: 'Deganeo: manadio metadata');
  String get aboutFeatureCleanerBody => _t(
        'Avant de publier, supprimez ce que vos photos, vidéos et PDF '
            'révèlent à votre insu : position GPS, appareil, dates, auteur, '
            'commentaires. Un rapport montre ce qui a été trouvé et supprimé, '
            'puis vérifie le résultat.',
        'Before publishing, remove what your photos, videos and PDFs reveal '
            'without you knowing: GPS position, device, dates, author, '
            'comments. A report shows what was found and removed, then '
            'verifies the result.',
        mg: 'Alohan’ny famoahana, fafao izay aseho tsy fantatrao amin’ny '
            'sary, horonantsary ary PDF: toerana GPS, fitaovana, daty, '
            'mpamorona, fanamarihana.',
      );
  String get aboutFeatureAssistantTitle =>
      _t('Degany, votre IA', 'Degany, your AI', mg: 'Degany, IA-nao');
  String get aboutFeatureAssistantBody => _t(
        'Connectez l’IA de votre choix (ChatGPT, Claude, Gemini, '
            'DeepSeek…) : Degany cherche, range, écrit vos notes, nettoie '
            'vos photos avec Deganeo et gère tâches et comptabilité.',
        'Connect the AI of your choice (ChatGPT, Claude, Gemini, '
            'DeepSeek…): Degany searches, organises, writes your notes, '
            'cleans your photos with Deganeo and manages tasks and accounting.',
        mg: 'Ampifandraiso ny IA tianao (ChatGPT, Claude, Gemini, '
            'DeepSeek…): Degany mikaroka, mandamina, manoratra naoty, '
            'manadio sary amin\'ny Deganeo ary mitantana asa sy kaonty.',
      );
  String get aboutPrivacyTitle =>
      _t('Vos données restent chez vous', 'Your data stays with you',
          mg: 'Mijanona aminao ny angonao');
  String get aboutPrivacyBody => _t(
        'Votre bibliothèque est un simple dossier sur votre appareil. '
            'Le nettoyage de métadonnées se fait entièrement en local : '
            'aucun fichier n’est envoyé sur un serveur.',
        'Your library is a plain folder on your device. Metadata cleaning '
            'runs entirely locally: no file is uploaded to any server.',
        mg: 'Lahatahiry tsotra ao amin’ny fitaovanao ny tahirinao. Atao ao '
            'an-toerana avokoa ny fanadiovana metadata: tsy misy rakitra '
            'alefa any amin’ny serveur.',
      );
  String get aboutCleanerFormatsTitle =>
      _t('Formats nettoyés par Deganeo', 'Formats cleaned by Deganeo',
          mg: 'Karazana rakitra diovin’i Deganeo');
  String get aboutCleanerFormatsBody => _t(
        'Images : JPEG, PNG, WebP, GIF, TIFF, HEIC/AVIF. Vidéos : '
            'MP4, MOV, M4V, MKV, WebM, AVI. Documents : PDF non chiffré. '
            'Le fichier d’origine n’est jamais modifié : vous obtenez une '
            'copie nettoyée.',
        'Images: JPEG, PNG, WebP, GIF, TIFF, HEIC/AVIF. Videos: MP4, MOV, '
            'M4V, MKV, WebM, AVI. Documents: unencrypted PDF. The original '
            'file is never modified: you get a cleaned copy.',
        mg: 'Sary: JPEG, PNG, WebP, GIF, TIFF, HEIC/AVIF. Horonantsary: MP4, '
            'MOV, M4V, MKV, WebM, AVI. Antontan-taratasy: PDF tsy voafeno. '
            'Tsy novana mihitsy ny rakitra tany am-boalohany.',
      );
  String get aboutLimitsTitle =>
      _t('Les limites, en toute honnêteté', 'The limits, honestly',
          mg: 'Ny fetra, amin’ny fahatsorana');
  String get aboutLimitsBody => _t(
        'Deganeo ne supprime pas un filigrane visible ni une information '
            'cachée dans les pixels eux-mêmes. Les fichiers RAW/DNG et les '
            'PDF chiffrés sont refusés plutôt qu’abîmés. Le rapport indique '
            'toujours si le nettoyage est vérifié, avec réserves ou partiel : '
            'jamais de promesse « 100 % » qui ne serait pas vérifiable.',
        'Deganeo does not remove a visible watermark or information hidden '
            'in the pixels themselves. RAW/DNG files and encrypted PDFs are '
            'refused rather than damaged. The report always says whether '
            'cleaning is verified, has caveats or is partial: never a "100 %" '
            'promise that could not be verified.',
        mg: 'Tsy mamafa filigrane hita maso na fampahalalana miafina ao '
            'anatin’ny pixel i Deganeo. Lavina aloha ny rakitra RAW/DNG sy '
            'PDF voafeno toy izay ho simba.',
      );
  String get aboutLanguagesTitle => _t('Langues', 'Languages', mg: 'Fiteny');
  String get aboutLanguagesBody => _t(
        'Français, English et Malagasy. Changez de langue dans Réglages.',
        'Français, English and Malagasy. Change language in Settings.',
        mg: 'Frantsay, anglisy ary malagasy. Ovay ao amin’ny Parametra.',
      );
  String get aboutProTitle => _t('Espace professionnel', 'Professional space',
      mg: 'Toerana mpandraharaha');
  String get aboutProBody => _t(
        'Revendeur Pôma Original ? Connectez-vous pour accéder à votre '
            'espace revendeur directement dans Influencor.',
        'Pôma Original reseller? Sign in to open your reseller space right '
            'inside Influencor.',
        mg: 'Mpivarotra Pôma Original ve ianao? Hiditra mba hanokatra ny '
            'toeranao ao anatin’i Influencor.',
      );
  String get accessPro =>
      _t('Accès professionnel', 'Professional access', mg: 'Fidirana pro');
  String get resellerSessionCreated => _t(
        'Session créée : espace reseller activé.',
        'Session created: reseller space enabled.',
        mg: 'Voaforona ny session: mandeha ny toerana reseller.',
      );
  String get resellerOfflineTitle =>
      _t('Connexion impossible', 'Cannot connect', mg: 'Tsy afaka mifandray');
  String get resellerOfflineBody => _t(
        'Vérifiez votre connexion internet puis réessayez.',
        'Check your internet connection and try again.',
        mg: 'Jereo ny fifandraisanao amin’ny internet dia andramo indray.',
      );
  String get resellerSignOut => _t('Se déconnecter', 'Sign out', mg: 'Hiala');
  String get resellerSignOutTitle => _t(
        'Quitter l’espace reseller ?',
        'Leave the reseller space?',
        mg: 'Hiala amin’ny toerana reseller ve?',
      );
  String get resellerSignOutBody => _t(
        'Votre session sera fermée sur cet appareil et vous reviendrez à '
            'clipboard.',
        'Your session will be closed on this device and you will return to '
            'clipboard.',
        mg: 'Hosarahina ny session amin’ity fitaovana ity ary hiverina any '
            'amin’ny clipboard ianao.',
      );
  String get retry => _t('Réessayer', 'Retry', mg: 'Avereno');
  String get resellerUnsupportedBody => _t(
        'L’espace professionnel s’affiche dans l’application sur Android '
            'et iOS. Sur cet appareil, il s’ouvre dans votre navigateur.',
        'The professional space is shown inside the app on Android and iOS. '
            'On this device it opens in your browser.',
        mg: 'Aseho ao anatin’ny app ny toerana pro amin’ny Android sy iOS. '
            'Amin’ity fitaovana ity dia misokatra ao amin’ny navigateur.',
      );
  String get resellerOpenInBrowser =>
      _t('Ouvrir dans le navigateur', 'Open in browser',
          mg: 'Sokafy ao amin’ny navigateur');

  String get eraseCleanCopy => _t(
        'Effacer la copie nettoyée',
        'Erase clean copy',
        mg: 'Fafao ny kopia nodiovina',
      );
  String get cleanCopyErased => _t(
        'Copie nettoyée effacée.',
        'Clean copy erased.',
        mg: 'Voafafa ny kopia nodiovina.',
      );
  String get visibleWatermarkNotRemoved => _t(
        'Ne supprime pas les watermarks visibles dans l’image.',
        'Does not remove visible watermarks in the image.',
        mg: 'Tsy mamafa watermark hita maso ao amin’ny sary.',
      );
  String get uploadMedia =>
      _t('Choisir une image ou une vidéo', 'Choose an image or video',
          mg: 'Ampidiro sary na lahatsary');
  String get today => _t("Aujourd'hui", 'Today', mg: 'Androany');
  String get yesterday => _t('Hier', 'Yesterday', mg: 'Omaly');
  String get noMedia => _t('Aucun média', 'No media', mg: 'Tsy misy media');

  // Generic actions
  String get add => _t('Ajouter', 'Add', mg: 'Ampio');
  String get open => _t('Ouvrir', 'Open', mg: 'Sokafy');
  String get copy => _t('Copier', 'Copy', mg: 'Adikao');
  String get share => _t('Partager', 'Share', mg: 'Zarao');
  String get download => _t('Télécharger', 'Download', mg: 'Sintomy');
  String get replace => _t('Remplacer', 'Replace', mg: 'Soloina');
  String get delete => _t('Supprimer', 'Delete', mg: 'Fafao');
  String get restore => _t('Restaurer', 'Restore', mg: 'Avereno');
  String get rename => _t('Renommer', 'Rename', mg: 'Ovay anarana');
  String get cancel => _t('Annuler', 'Cancel', mg: 'Foano');
  String get clear => _t('Effacer', 'Clear', mg: 'Diovy');
  String get create => _t('Créer', 'Create', mg: 'Forony');
  String get save => _t('Enregistrer', 'Save', mg: 'Tehirizo');
  String get edit => _t('Modifier', 'Edit', mg: 'Ovay');
  String get fees =>
      _t('Frais mobile money', 'Mobile money fees', mg: 'Sarany mobile money');
  String get feeWithdraw => _t('Retrait', 'Withdrawal', mg: 'Fanesorana');
  String get feeTransfer => _t('Transfert', 'Transfer', mg: 'Famindrana');
  String get feeOperator => _t('Opérateur', 'Operator', mg: 'Operatera');
  String get feeTo => _t('Vers', 'To', mg: 'Mankany');
  String get feeChannelUssd => _t('USSD #144#', 'USSD #144#', mg: 'USSD #144#');
  String get feeChannelApp =>
      _t('Appli (−50 %)', 'App (−50%)', mg: 'Appli (−50 %)');
  String get feeEstimated => _t(
      'Airtel : grille non publiée, tarifs estimés (comme Orange).',
      'Airtel: grid not published, tariffs estimated (same as Orange).',
      mg: 'Airtel: tsy navoaka ny sarany, tombanana (mitovy amin\'ny Orange).');
  String get feeBest =>
      _t('Le plus économique', 'Cheapest', mg: 'Mora indrindra');
  String get feeDirect => _t('Direct', 'Direct', mg: 'Mivantana');
  String get feeSplit => _t('Séparé', 'Split', mg: 'Zarazara');
  String get feeTotal => _t('Frais', 'Fees', mg: 'Sarany');
  String get feeNoPlan => _t('Montant non couvert par ces tarifs',
      'Amount not covered by these tariffs',
      mg: 'Tsy ampy ireo sarany ireo ny vola');
  String get feeTariffs => _t('Tarifs mobile money', 'Mobile money tariffs',
      mg: 'Sarany mobile money');
  String get feeTariffsHint => _t(
      'Modifier les grilles de frais ou ajouter un opérateur',
      'Edit fee grids or add an operator',
      mg: 'Ovay ny sarany na ampio operatera');
  String get feeAddOperator =>
      _t('Ajouter un opérateur', 'Add an operator', mg: 'Ampio operatera');
  String get feeOperatorName =>
      _t('Nom de l’opérateur', 'Operator name', mg: 'Anaran’ny operatera');
  String get feeTabWithdraw => _t('Retrait', 'Withdraw', mg: 'Esory');
  String get feeTabSame => _t('Même', 'Same', mg: 'Mitovy');
  String get feeTabOther => _t('Autre', 'Other', mg: 'Hafa');
  String get feeTabApp => _t('Appli', 'App', mg: 'Appli');
  String get feeGridWithdraw => _t('Retrait', 'Withdrawal', mg: 'Fanesorana');
  String get feeGridSame =>
      _t('Transfert : même opérateur', 'Transfer: same operator',
          mg: 'Famindrana: mitovy operatera');
  String get feeGridOther =>
      _t('Transfert : autre opérateur', 'Transfer: other operator',
          mg: 'Famindrana: operatera hafa');
  String get feeGridApp => _t('Transfert via l’appli', 'Transfer via app',
      mg: 'Famindrana amin’ny appli');
  String example(String v) => _t('Ex : $v', 'e.g. $v', mg: 'Ohatra: $v');
  String get feeEstimatedTag => _t('estimé', 'estimated', mg: 'tombanana');
  String get feeRestoreOfficial =>
      _t('Revenir au tarif officiel', 'Back to the official tariff',
          mg: 'Hiverina amin’ny sarany ofisialy');
  String get feeRestoreOfficialConfirm => _t(
      'Vos modifications de cet opérateur seront remplacées par la grille fournie avec l’app.',
      'Your changes to this operator will be replaced by the grid shipped with the app.',
      mg: 'Soloina ny fanovanao amin’ity operatera ity.');
  String get feeAddBracket =>
      _t('Ajouter une tranche', 'Add a bracket', mg: 'Ampio sokajy');
  String get feeBracketFrom =>
      _t('De (Ar)', 'From (Ar)', mg: 'Hatramin’ny (Ar)');
  String get feeBracketTo => _t('À (Ar)', 'To (Ar)', mg: 'Hatramin’ny (Ar)');
  String get feeBracketFee => _t('Frais (Ar)', 'Fee (Ar)', mg: 'Sarany (Ar)');
  String get feeBracketInvalid => _t(
      'Vérifiez : « De » doit être ≤ « À », frais ≥ 0.',
      'Check: "From" must be ≤ "To", fee ≥ 0.',
      mg: 'Hamarino: "Hatramin’ny" ≤ "Hatramin’ny", sarany ≥ 0.');
  String get feeBracketOverlap =>
      _t('Des tranches se chevauchent.', 'Some brackets overlap.',
          mg: 'Misy sokajy mifandona.');
  String get feeGridEmpty =>
      _t('Aucune tranche', 'No brackets yet', mg: 'Tsy mbola misy sokajy');
  String get feeGridOptional => _t(
      'Facultatif : vide = grille « même opérateur ».',
      'Optional: empty = "same operator" grid.',
      mg: 'Tsy voatery: foana = grille mitovy operatera.');
  String get feeVerifiedSwitch =>
      _t('Tarif vérifié (officiel)', 'Verified (official) tariff',
          mg: 'Sarany voamarina');
  String get feeResetDefaults =>
      _t('Rétablir les tarifs par défaut', 'Restore default tariffs',
          mg: 'Averina ny sarany voalohany');
  String get feeResetConfirm => _t(
      'Remplacer tous vos tarifs par ceux fournis avec l’app ?',
      'Replace all your tariffs with the ones shipped with the app?',
      mg: 'Soloina ny sarany rehetra amin’ny avy amin’ny app?');
  String get feeDeleteOperator =>
      _t('Supprimer cet opérateur ?', 'Delete this operator?',
          mg: 'Fafana ity operatera ity?');
  String get feeNameTaken =>
      _t('Ce nom existe déjà.', 'This name already exists.',
          mg: 'Efa misy io anarana io.');
  String get feeNeedGrids => _t(
      'Retrait et transfert (même opérateur) doivent avoir au moins une tranche.',
      'Withdrawal and same-operator transfer need at least one bracket.',
      mg: 'Ilaina ny sokajy iray farafahakeliny.');
  String get feeUnverified => _t(
      'Grilles officielles MVola et Orange (Orange : en vigueur depuis févr. 2025). À confirmer avant une grosse opération.',
      'Official MVola and Orange grids (Orange: in force since Feb 2025). Confirm before large operations.',
      mg: 'Sarany ofisialy MVola sy Orange. Hamarino alohan\'ny asa lehibe.');
  String feeSaves(String v) =>
      _t('Économie : $v', 'You save: $v', mg: 'Voatahiry: $v');
  String feeOps(int n) =>
      _t('$n opérations', '$n operations', mg: 'fampiasana $n');
  String get closeAction => _t('Fermer', 'Close', mg: 'Akatona');
  String get refresh => _t('Actualiser', 'Refresh', mg: 'Havaozy');
  String get more => _t('Plus', 'More', mg: 'Bebe kokoa');

  // Workspace
  String get storageDenied => _t(
        'Accès au stockage refusé : ce dossier ne peut pas être utilisé.',
        'Storage access denied: this folder cannot be used.',
        mg: 'Nolavina ny fidirana amin’ny fitahirizana: tsy azo ampiasaina ity '
            'lahatahiry ity.',
      );
  String get useAppFolder => _t(
        'Dossier de l’app',
        'App folder',
        mg: 'Lahatahiry an’ny app',
      );
  String get chooseWorkspace =>
      _t('Choisir le dossier de travail', 'Choose the working folder',
          mg: 'Safidio ny dossier fiasana');
  String get workspaceIntro => _t(
        'Influencor travaille directement dans un dossier de votre disque. '
            'Choisissez-le pour commencer.',
        'Influencor works directly inside a folder on your disk. '
            'Choose one to get started.',
        mg: 'Influencor dia miasa mivantana ao anaty dossier iray amin\'ny '
            'kapilanao. Safidio izany hanombohana.',
      );
  String get changeWorkspace =>
      _t('Changer de dossier de travail', 'Change working folder',
          mg: 'Hanova dossier fiasana');
  String get workspaceFolder =>
      _t('Dossier de travail', 'Working folder', mg: 'Dossier fiasana');

  // Add menu
  String get newFolder =>
      _t('Nouveau dossier', 'New folder', mg: 'Dossier vaovao');
  String get newNote => _t('Nouvelle note', 'New note', mg: 'Naoty vaovao');
  String get importFiles =>
      _t('Importer des fichiers', 'Import files', mg: 'Hampiditra rakitra');
  String get moveFilesIn =>
      _t('Déplacer des fichiers', 'Move files in', mg: 'Hamindra rakitra');

  // Content categories
  String get folders => _t('Dossiers', 'Folders', mg: 'Dossier');
  String get images => _t('Images', 'Images', mg: 'Sary');
  String get videos => _t('Vidéos', 'Videos', mg: 'Lahatsary');
  String get notes => _t('Notes', 'Notes', mg: 'Naoty');
  String get tables => _t('Tableaux', 'Tables', mg: 'Tabilao');
  String get files => _t('Fichiers', 'Files', mg: 'Rakitra');
  String get contents => _t('Contenus', 'Contents', mg: 'Votoaty');

  // Notes
  String get noteTitle => _t('Titre', 'Title', mg: 'Lohateny');
  String get noteTitleHint =>
      _t('Titre de la note (nom du fichier .md)', 'Note title (.md file name)',
          mg: 'Lohatenin\'ny naoty (anaran\'ny rakitra .md)');
  String get noteContent =>
      _t('Contenu (Markdown)', 'Content (Markdown)', mg: 'Votoaty (Markdown)');
  String get newNoteTitle =>
      _t('Nouvelle note', 'New note', mg: 'Naoty vaovao');
  String get editNoteTitle =>
      _t('Modifier la note', 'Edit note', mg: 'Hanova naoty');
  String get emptyNoteError =>
      _t('La note ne peut pas être vide.', 'The note cannot be empty.',
          mg: 'Tsy azo atao foana ny naoty.');
  String get attachPhoto =>
      _t('Joindre un média', 'Attach media', mg: 'Ampidiro media');
  String get attachments =>
      _t('Pièces jointes', 'Attachments', mg: 'Rakitra miraikitra');
  String photosAttached(int n) =>
      _t('$n média(s) joint(s).', '$n media file(s) attached.',
          mg: '$n media nampidirina.');
  String selectedAttachments(int n) =>
      _t('$n pièce(s) sélectionnée(s)', '$n attachment(s) selected',
          mg: '$n rakitra voafantina');
  String get deleteAttachmentTitle =>
      _t('Supprimer cette pièce jointe ?', 'Delete this attachment?',
          mg: 'Fafana ity rakitra miraikitra ity?');
  String get deleteAttachmentMessage => _t(
        'Elle sera retirée de la note et supprimée du dossier des pièces jointes.',
        'It will be removed from the note and deleted from the attachments folder.',
        mg: 'Hesorina amin\'ny naoty izy ary hofafana ao amin\'ny dossier '
            'rakitra miraikitra.',
      );
  String get attachmentDeleted =>
      _t('Pièce jointe supprimée.', 'Attachment deleted.',
          mg: 'Voafafa ny rakitra miraikitra.');

  // Tables
  String get addTableRow =>
      _t('Ajouter une ligne', 'Add row', mg: 'Ampio andalana');
  String get addTableColumn =>
      _t('Ajouter une colonne', 'Add column', mg: 'Ampio tsanganana');
  String get columnName => _t('Colonne', 'Column', mg: 'Tsanganana');
  String get insert => _t('Insérer', 'Insert', mg: 'Ampidiro');
  String get emptyTable =>
      _t('Tableau vide', 'Empty table', mg: 'Tabilao foana');
  String get incompatibleTable => _t(
      'Ce fichier JSON n’est pas un tableau compatible.',
      'This JSON file is not a compatible table.',
      mg: 'Ity rakitra JSON ity dia tsy tabilao mifanaraka.');
  String get showHiddenColumns =>
      _t('Afficher les colonnes masquées', 'Show hidden columns',
          mg: 'Asehoy ireo tsanganana nafenina');
  String get hideHiddenColumns =>
      _t('Masquer les colonnes masquées', 'Hide masked columns',
          mg: 'Afeno ireo tsanganana');
  String get allColumnsHidden => _t('Toutes les colonnes sont masquées ([...])',
      'All columns are hidden ([...])',
      mg: 'Nafenina daholo ny tsanganana rehetra ([...])');
  String get longPressToToggleColumns => _t(
      'Appui long sur Modifier pour afficher / masquer',
      'Long press on Edit to show / hide',
      mg: 'Tsindrio ela ny Hanova hanehoana / hanafenana');
  String get deleteTableColumn =>
      _t('Supprimer la colonne', 'Delete column', mg: 'Fafao ny tsanganana');
  String get deleteTableRow =>
      _t('Supprimer la ligne', 'Delete row', mg: 'Fafao ny andalana');
  String get tableColumnDeleted =>
      _t('Colonne supprimée.', 'Column deleted.', mg: 'Voafafa ny tsanganana.');
  String get tableRowDeleted =>
      _t('Ligne supprimée.', 'Row deleted.', mg: 'Voafafa ny andalana.');
  String get tableKeepsOneColumn => _t('Un tableau garde au moins une colonne.',
      'A table keeps at least one column.',
      mg: 'Tsy maintsy misy tsanganana iray farafahakeliny ny tabilao.');
  String get dragToMove =>
      _t('Maintenir et glisser pour déplacer', 'Hold and drag to move',
          mg: 'Tazony ary sintony hamindrana');
  String get defaultVisibleColumns =>
      _t('Colonnes affichées par défaut', 'Columns shown by default',
          mg: 'Tsanganana aseho foana');
  String get longPressSaveForColumns => _t(
      'Appui long : colonnes affichées par défaut',
      'Long press: columns shown by default',
      mg: 'Tsindrio ela: tsanganana aseho foana');
  String get undo => _t('Annuler', 'Undo', mg: 'Averina');
  String get done => _t('Terminé', 'Done', mg: 'Vita');
  String get formulaPickHint => _t(
      'Touchez une case pour l’ajouter à la formule',
      'Tap a cell to add it to the formula',
      mg: 'Tsindrio ny sela iray hampidirana azy ao amin’ny formule');
  String get formulaColumn =>
      _t('Colonne calculée', 'Calculated column', mg: 'Tsanganana kajy');

  // Rich-text formatting toolbar
  String get bold => _t('Gras', 'Bold', mg: 'Matevina');
  String get italic => _t('Italique', 'Italic', mg: 'Mitongilana');
  String get underline => _t('Souligné', 'Underline', mg: 'Tsipihina');
  String get strikethrough => _t('Barré', 'Strikethrough', mg: 'Voatsipika');
  String get monospace =>
      _t('Code / chasse fixe', 'Code / monospace', mg: 'Code / monospace');
  String get bulletList =>
      _t('Liste à puces', 'Bullet list', mg: 'Lisitra teboka');
  String get numberedList =>
      _t('Liste numérotée', 'Numbered list', mg: 'Lisitra laharana');
  String get clearFormatting =>
      _t('Effacer la mise en forme', 'Clear formatting',
          mg: 'Esory ny endrika');
  String get preview => _t('Aperçu', 'Preview', mg: 'Topimaso');
  String get sent => _t('Envoyé', 'Sent', mg: 'Nalefa');

  // Copy modes
  String get copyForSocial =>
      _t('Copier la note', 'Copy note', mg: 'Adikao ny naoty');
  String get copyPlainText =>
      _t('Copier note + médias joints', 'Copy note + attached media',
          mg: 'Adikao ny naoty + media miaraka');
  String get copyFailed => _t('Échec de la copie dans le presse-papiers.',
      'Failed to copy to clipboard.',
      mg: 'Tsy nahomby ny fandikana ao amin\'ny clipboard.');

  // Dialogs
  String get nameLabel => _t('Nom', 'Name', mg: 'Anarana');
  String get folderNameLabel =>
      _t('Nom du dossier', 'Folder name', mg: 'Anaran\'ny dossier');
  String get newFolderTitle =>
      _t('Nouveau dossier', 'New folder', mg: 'Dossier vaovao');
  String get renameTitle => _t('Renommer', 'Rename', mg: 'Ovay anarana');
  String get deleteTitle => _t('Supprimer cet élément ?', 'Delete this item?',
      mg: 'Fafana ity zavatra ity?');
  String get deleteMessage => _t(
        'Il sera déplacé vers la corbeille.',
        'It will be moved to the trash.',
        mg: 'Hafindra any amin\'ny fako izy.',
      );
  String get emptyTrashTitle => _t('Vider la corbeille ?', 'Empty the trash?',
      mg: 'Hofongorana ny fako?');
  String get emptyTrashMessage => _t(
        'Tous les éléments seront supprimés définitivement.',
        'All items will be permanently deleted.',
        mg: 'Ho voafafa tanteraka ny zavatra rehetra.',
      );
  String get emptyTrash =>
      _t('Vider la corbeille', 'Empty trash', mg: 'Foano ny fako');
  String get deletePermanently =>
      _t('Supprimer définitivement', 'Delete permanently',
          mg: 'Fafao tanteraka');

  // Drag & drop
  String get dropToImport => _t('Relâchez pour importer', 'Release to import',
      mg: 'Avoahy hampidirana');

  // Empty states
  String get emptyFolderTitle =>
      _t('Dossier vide', 'Empty folder', mg: 'Dossier foana');
  String get emptyFolderMessage => _t(
        'Créez un dossier, une note, ou glissez-déposez des fichiers ici.',
        'Create a folder, a note, or drag & drop files here.',
        mg: 'Mamorona dossier, naoty, na sintomy eto ny rakitra.',
      );
  String get noContents =>
      _t('Aucun contenu', 'No content yet', mg: 'Tsy misy votoaty');
  String get trashEmpty =>
      _t('La corbeille est vide', 'The trash is empty', mg: 'Foana ny fako');

  // Favorites
  String get addToFavorites =>
      _t('Ajouter aux favoris', 'Add to favorites', mg: 'Ampio amin\'ny tiana');
  String get removeFromFavorites =>
      _t('Retirer des favoris', 'Remove from favorites',
          mg: 'Esory amin\'ny tiana');

  // Feedback / errors
  String get shareNothingToShare => _t(
        'Ajoutez un texte ou au moins un média avant de partager.',
        'Add some text or at least one media before sharing.',
        mg: 'Ampio lahatsoratra na media iray farafahakeliny alohan\'ny hizara.',
      );
  String get shareNoValidFiles => _t(
        "Aucun fichier valide n'a été trouvé pour le partage.",
        'No valid file was found to share.',
        mg: 'Tsy nahitana rakitra mety hozaraina.',
      );
  String get shareSomeMediaSkipped => _t(
        'Certains médias ne sont plus disponibles et ont été ignorés.',
        'Some media are no longer available and were skipped.',
        mg: 'Tsy misy intsony ny media sasany ary nasaintsika.',
      );
  String get shareCancelled =>
      _t('Partage annulé.', 'Sharing cancelled.', mg: 'Nofoanana ny fizarana.');
  String get shareFailed => _t(
        "Impossible d'ouvrir le partage. Réessayez.",
        'Could not open sharing. Try again.',
        mg: 'Tsy afaka nanokatra ny fizarana. Andramo indray.',
      );
  String get shareMixedExplanation => _t(
        'Certaines applications ne prennent pas correctement en charge le '
            "partage simultané d'images et de vidéos avec un texte.",
        'Some apps do not properly support sharing images and videos together '
            'with a text.',
        mg: 'Tsy mahazaka fizarana sary sy video miaraka amin\'ny lahatsoratra '
            'ny app sasany.',
      );
  String get shareOnlyImages => _t(
        'Partager uniquement les images avec le texte',
        'Share only the images with the text',
        mg: 'Zarao ny sary fotsiny miaraka amin\'ny lahatsoratra',
      );
  String get shareOnlyVideos => _t(
        'Partager uniquement les vidéos avec le texte',
        'Share only the videos with the text',
        mg: 'Zarao ny video fotsiny miaraka amin\'ny lahatsoratra',
      );
  String get shareMixedSeparately => _t(
        'Les images et les vidéos seront partagées séparément selon votre choix.',
        'Images and videos will be shared separately, as you chose.',
        mg: 'Hozaraina misaraka ny sary sy ny video araka ny safidinao.',
      );
  String get genericError =>
      _t('Une erreur est survenue.', 'Something went wrong.',
          mg: 'Nisy olana nitranga.');
  String get copiedToClipboard =>
      _t('Copié dans le presse-papiers', 'Copied to clipboard',
          mg: 'Vo adika ao amin\'ny clipboard');
  String copiedWithFiles(int n) => _t(
        'Texte et $n fichier(s) copiés',
        'Text and $n file(s) copied',
        mg: 'Lahatsoratra sy rakitra $n voadika',
      );
  String get noteSaved =>
      _t('Note enregistrée.', 'Note saved.', mg: 'Voatahiry ny naoty.');
  String get fileDownloaded =>
      _t('Fichier nettoyé téléchargé.', 'Clean file downloaded.',
          mg: 'Voasintona ny rakitra nodiovina.');
  String get fileReplaced =>
      _t('Fichier original remplacé.', 'Original file replaced.',
          mg: 'Voasolo ny rakitra tany am-boalohany.');
  String folderCreated(String name) =>
      _t('Dossier « $name » créé.', 'Folder "$name" created.',
          mg: 'Dossier "$name" voaforona.');
  String importReport(int ok, int failed) => failed == 0
      ? _t('$ok élément(s) importé(s).', '$ok item(s) imported.',
          mg: '$ok zavatra nampidirina.')
      : _t('$ok importé(s), $failed échec(s).', '$ok imported, $failed failed.',
          mg: '$ok nampidirina, $failed tsy nahomby.');
  String moveInReport(int ok, int failed) => failed == 0
      ? _t('$ok élément(s) déplacé(s).', '$ok item(s) moved.',
          mg: '$ok zavatra nafindra.')
      : _t('$ok déplacé(s), $failed échec(s).', '$ok moved, $failed failed.',
          mg: '$ok nafindra, $failed tsy nahomby.');

  // Search
  String get searchHint =>
      _t('Rechercher dans la bibliothèque…', 'Search the library…',
          mg: 'Karohy ao amin\'ny tahiry…');
  String get searchPrompt => _t(
        'Tapez pour rechercher par nom ou tag.',
        'Type to search by name or tag.',
        mg: 'Soraty ny anarana na tag ho karohina.',
      );
  String get noResults =>
      _t('Aucun résultat', 'No results', mg: 'Tsy misy valiny');
  String get all => _t('Tous', 'All', mg: 'Rehetra');

  // Sort
  String get sortBy => _t('Trier par', 'Sort by', mg: 'Alaharo araka');
  String get sortNameAsc => _t('Nom (A→Z)', 'Name (A→Z)', mg: 'Anarana (A→Z)');
  String get sortNameDesc => _t('Nom (Z→A)', 'Name (Z→A)', mg: 'Anarana (Z→A)');
  String get sortNewest => _t('Plus récent', 'Newest', mg: 'Vaovao indrindra');
  String get sortOldest =>
      _t('Plus ancien', 'Oldest', mg: 'Tranainy indrindra');
  String get sortSizeAsc =>
      _t('Taille croissante', 'Size ascending', mg: 'Habe miakatra');
  String get sortSizeDesc =>
      _t('Taille décroissante', 'Size descending', mg: 'Habe midina');

  // Tags
  String get tags => _t('Tags', 'Tags');
  String get editTags => _t('Modifier les tags', 'Edit tags', mg: 'Hanova tag');
  String get tagsHint =>
      _t('Tags séparés par des virgules', 'Comma-separated tags',
          mg: 'Tag sarahina amin\'ny faingo');

  // Move / duplicate
  String get move => _t('Déplacer', 'Move', mg: 'Afindrao');
  String get duplicate => _t('Dupliquer', 'Duplicate', mg: 'Adika mitovy');
  String get chooseDestination =>
      _t('Choisir le dossier de destination', 'Choose destination folder',
          mg: 'Safidio ny dossier aleha');

  // Favorites
  String get favoritesEmpty =>
      _t('Aucun favori', 'No favorites yet', mg: 'Tsy mbola misy tiana');
  String get inFolder => _t('dans', 'in', mg: 'ao');

  // Settings
  String get appearance => _t('Apparence', 'Appearance', mg: 'Endrika');
  String get theme => _t('Thème', 'Theme', mg: 'Lohahevitra');
  String get themeSystem => _t('Système', 'System', mg: 'Rafitra');
  String get themeLight => _t('Clair', 'Light', mg: 'Mazava');
  String get themeDark => _t('Sombre', 'Dark', mg: 'Maizina');
  String get language => _t('Langue', 'Language', mg: 'Fiteny');
  String get malagasy => _t('Malagasy', 'Malagasy', mg: 'Malagasy');
  String get french => _t('Français', 'French', mg: 'Frantsay');
  String get english => _t('Anglais', 'English', mg: 'Anglisy');
  String get defaultView =>
      _t('Vue par défaut', 'Default view', mg: 'Fijery default');
  String get viewGrid => _t('Grille', 'Grid', mg: 'Grille');
  String get viewList => _t('Liste', 'List', mg: 'Lisitra');
  String get noteSeparator =>
      _t('Séparateur des notes', 'Note separator', mg: 'Mpanasaraka naoty');
  String get customSeparator =>
      _t('Séparateur personnalisé', 'Custom separator',
          mg: 'Mpanasaraka namboarina');
  String get defaultSeparator =>
      _t('Ligne vide', 'Blank line', mg: 'Andalana banga');
  String get noteSeparatorInherited => _t(
        'Utilise le séparateur global',
        'Uses the global separator',
        mg: 'Mampiasa ny mpanasaraka global',
      );
  String get noteSeparatorOverride => _t(
        'Séparateur de cette note',
        'This note separator',
        mg: 'Mpanasaraka an\'ity naoty ity',
      );

  // In-app file picker
  String get selectFilesTitle =>
      _t('Sélectionner des fichiers', 'Select files', mg: 'Safidio rakitra');
  String get selectImagesTitle =>
      _t('Sélectionner des photos', 'Select photos', mg: 'Safidio sary');
  String get selectMediaTitle =>
      _t('Sélectionner des médias', 'Select media', mg: 'Safidio media');
  String get multipleSelection =>
      _t('Sélection multiple', 'Multiple selection', mg: 'Safidy maro');
  String get chooseThisFolder => _t('Choisir ce dossier', 'Choose this folder',
      mg: 'Safidio ity dossier ity');
  String get parentFolder =>
      _t('Dossier parent', 'Parent folder', mg: 'Dossier ambony');
  String get importAction => _t('Importer', 'Import', mg: 'Ampidiro');
  String get selectAction => _t('Sélectionner', 'Select', mg: 'Safidio');
  String get folderAccessError => _t(
        'Impossible d\'accéder à ce dossier.',
        'Cannot access this folder.',
        mg: 'Tsy afaka miditra amin\'ity dossier ity.',
      );
  String get fileNotAccepted =>
      _t('Ce fichier n’est pas accepté.', 'This file is not accepted.',
          mg: 'Tsy ekena ity rakitra ity.');
  String filesNotAccepted(int n) => _t(
        '$n fichier(s) non accepté(s) ignoré(s).',
        '$n unsupported file(s) skipped.',
        mg: '$n rakitra tsy ekena nodiavina.',
      );
  String get locationHome => _t('Dossier personnel', 'Home', mg: 'Fandraisana');
  String get locationDesktop => _t('Bureau', 'Desktop', mg: 'Birao');
  String get locationDocuments =>
      _t('Documents', 'Documents', mg: 'Antontan-taratasy');
  String get locationDownloads =>
      _t('Téléchargements', 'Downloads', mg: 'Fisintonana');
  String nSelected(int n) =>
      _t('$n sélectionné(s)', '$n selected', mg: '$n voafantina');
  String get selectAll =>
      _t('Tout sélectionner', 'Select all', mg: 'Safidio rehetra');
  String get deselectAction =>
      _t('Désélectionner', 'Deselect', mg: 'Aza fidiana');
  String get previous => _t('Précédent', 'Previous', mg: 'Teo aloha');
  String get next => _t('Suivant', 'Next', mg: 'Manaraka');
  String get moveHere => _t('Déplacer ici', 'Move here', mg: 'Afindrao eto');
  String nMoved(int n) => _t('$n élément(s) déplacé(s)', '$n item(s) moved',
      mg: '$n zavatra nafindra');
  String nDeleted(int n) =>
      _t('$n élément(s) supprimé(s)', '$n item(s) deleted',
          mg: '$n zavatra voafafa');

  // Menu / accounting / tasks
  String get menu => _t('Menu', 'Menu', mg: 'Menio');
  String get accounting => _t('Comptabilité', 'Accounting', mg: 'Kaonty');
  String get tasks => _t('Tâches', 'Tasks', mg: 'Andraikitra');
  String get editMode => _t('Mode édition', 'Edit mode', mg: 'Fomba fanovana');
  String get normalMode =>
      _t('Mode normal', 'Normal mode', mg: 'Fomba mahazatra');
  String get availableBalance =>
      _t('Solde disponible', 'Available balance', mg: 'Sola misy');
  String get credit => _t('Crédit', 'Credit', mg: 'Fidirana');
  String get debit => _t('Débit', 'Debit', mg: 'Fanindraham-bola');
  String get purchase => _t('Achat', 'Purchase', mg: 'Fividianana');
  String get sale => _t('Vente', 'Sale', mg: 'Varotra');
  String get expense => _t('Dépense', 'Expense', mg: 'Lany');
  String get account => _t('Compte', 'Account', mg: 'Kaonty');
  String get cash => _t('Espèces (Cash)', 'Cash', mg: 'Vola ao am-paosy');
  String get amount => _t('Montant', 'Amount', mg: 'Habetsahana');
  String get date => _t('Date', 'Date', mg: 'Daty');
  String get note => _t('Note', 'Note', mg: 'Naoty');
  String get type => _t('Type', 'Type', mg: 'Karazana');
  String get newTransaction =>
      _t('Nouvelle opération', 'New transaction', mg: 'Fihetsika vaovao');
  String get editTransaction =>
      _t("Modifier l'opération", 'Edit transaction', mg: 'Ovay ny fihetsika');
  String get noTransactions =>
      _t('Aucune opération pour le moment', 'No transactions yet',
          mg: 'Tsy mbola misy fihetsika');
  String get invalidAmount =>
      _t('Montant invalide', 'Invalid amount', mg: 'Tsy mety ny habetsahana');
  String get currentSheet =>
      _t('Feuille en cours', 'Current sheet', mg: 'Takelaka ankehitriny');
  String get closedSheet =>
      _t('Feuille clôturée', 'Closed sheet', mg: 'Takelaka voakatona');
  String get sheetHistory => _t('Historique des feuilles', 'Sheet history',
      mg: "Tantaran'ny takelaka");
  String sheetSince(String date) =>
      _t('Depuis le $date', 'Since $date', mg: 'Nanomboka ny $date');
  String sheetPeriod(String from, String to) =>
      _t('Du $from au $to', 'From $from to $to',
          mg: "Tamin'ny $from hatramin'ny $to");
  String sheetEntries(int n) =>
      _t('$n opération(s)', '$n transaction(s)', mg: '$n fihetsika');
  String get closeSheet =>
      _t('Clôturer la feuille', 'Close sheet', mg: 'Hikatona ny takelaka');
  String get closeSheetShort => _t('Clôturer', 'Close', mg: 'Hikatona');
  String get closeSheetNeedsEntry => _t(
      'Ajoutez une opération avant de clôturer',
      'Add a transaction before closing',
      mg: 'Manampia fihetsika aloha vao manakatona');
  String get closeSheetTitle => _t('Clôturer la feuille ?', 'Close this sheet?',
      mg: 'Hikatona ity takelaka ity?');
  String closeSheetMessage(String start, String now, String balance) => _t(
      'La feuille commencée le $start sera clôturée maintenant ($now) et '
          'passera en lecture seule. Une nouvelle feuille démarre aussitôt, '
          'avec le solde reporté ($balance).',
      'The sheet started on $start will be closed now ($now) and become '
          'read-only. A new sheet starts right away, with the balance carried '
          'over ($balance).',
      mg: 'Hokatonina izao ($now) ny takelaka nanomboka ny $start ary tsy '
          'azo ovaina intsony. Misy takelaka vaovao manomboka avy hatrany, '
          "miaraka amin'ny sola nafindra ($balance).");
  String get sheetClosed => _t('Feuille clôturée, nouvelle feuille démarrée',
      'Sheet closed, a new sheet has started',
      mg: 'Voakatona ny takelaka, nanomboka ny takelaka vaovao');
  String get sheetReadOnly =>
      _t('Feuille clôturée : lecture seule', 'Closed sheet: read-only',
          mg: 'Takelaka voakatona: vakiana ihany');
  String get closingBalance =>
      _t('Solde de clôture', 'Closing balance', mg: "Sola tamin'ny fikatonana");
  String get openingBalance =>
      _t('Solde reporté', 'Balance brought forward', mg: 'Sola nafindra');
  String get ledgerTrend => _t('Évolution', 'Trend', mg: 'Fivoarana');
  String get perDay => _t('Par jour', 'Per day', mg: "Isan'andro");
  String get perWeek => _t('Par semaine', 'Per week', mg: 'Isan-kerinandro');
  String get perMonth => _t('Par mois', 'Per month', mg: 'Isam-bolana');
  String weekOf(String date) => _t('Semaine du $date', 'Week of $date',
      mg: 'Herinandro nanomboka ny $date');
  String ledgerChartLabel(String credit, String debit) => _t(
      'Graphique des crédits ($credit) et des débits ($debit)',
      'Chart of credits ($credit) and debits ($debit)',
      mg: "Sarisary fidirana ($credit) sy fivoahan'ny vola ($debit)");
  String get newTask =>
      _t('Nouvelle tâche', 'New task', mg: 'Andraikitra vaovao');
  String get noTasks => _t('Aucune tâche pour le moment', 'No tasks yet',
      mg: 'Tsy mbola misy andraikitra');
  String get taskTitle => _t('Titre', 'Title', mg: 'Lohateny');
  String get untitledTask => _t('Tâche sans titre', 'Untitled task',
      mg: 'Andraikitra tsy misy anarana');
  String get addTextBlock =>
      _t('Bloc de texte', 'Text block', mg: 'Sakana lahatsoratra');
  String get addChecklist =>
      _t('Checklist', 'Checklist', mg: 'Lisitra fanamarinana');
  String get addItem =>
      _t('Ajouter un élément', 'Add item', mg: 'Hampiana zavatra');
  String get textHint => _t('Écrivez ici…', 'Write here…', mg: 'Soraty eto…');
  String get checklistTitleHint =>
      _t('Titre de la checklist', 'Checklist title',
          mg: 'Lohatenin\'ny lisitra');
  String get itemHint => _t('Élément', 'Item', mg: 'Zavatra');
  String get deleteTaskQuestion =>
      _t('Supprimer cette tâche ?', 'Delete this task?',
          mg: 'Fafana ve ity andraikitra ity?');
  String get deleteBlock =>
      _t('Supprimer le bloc', 'Delete block', mg: 'Fafao ny sakana');
  String get needWorkspace => _t(
      "Choisissez d'abord un dossier de travail (Accueil).",
      'Choose a workspace folder first (Home).',
      mg: 'Misafidiana laharana ho an\'ny asa aloha (Fandraisana).');
}

/// Current app strings, following the concrete language chosen in settings.
final appStringsProvider = Provider<AppStrings>((ref) {
  final code = ref.watch(settingsProvider).languageCode;
  return AppStrings(Locale(code));
});
