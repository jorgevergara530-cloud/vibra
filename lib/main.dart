import 'dart:convert';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

// Crea tu client_id gratis en https://devportal.jamendo.com
// Se inyecta al compilar: --dart-define=JAMENDO_CLIENT_ID=xxxx
const kClientId = String.fromEnvironment('JAMENDO_CLIENT_ID');
const kGreen = Color(0xFF1DB954);

// ---------------- Modelo y API ----------------

class Track {
  final String id, name, artist, image, audio;
  final bool isLocal; // true = archivo guardado en el celular

  Track.fromJson(Map<String, dynamic> j)
      : id = j['id'].toString(),
        name = j['name'] ?? '',
        artist = j['artist_name'] ?? '',
        image = j['image'] ?? '',
        audio = j['audio'] ?? '',
        isLocal = false;

  Track.local(Map m)
      : id = '${m['id']}',
        name = '${m['title']}',
        artist = '${m['artist']}',
        image = '${m['art']}',
        audio = '${m['uri']}',
        isLocal = true;
}

// ---------------- Música del celular (canal nativo, ver MainActivity.kt) ----------------

class LocalMusic {
  static const _ch = MethodChannel('vibra/local_music');
  static final _artFutures = <String, Future<Uint8List?>>{};
  static final _artCache = <String, Uint8List?>{};

  static Future<bool> hasPermission() async =>
      await _ch.invokeMethod<bool>('hasPermission') ?? false;

  static Future<bool> requestPermission() async =>
      await _ch.invokeMethod<bool>('requestPermission') ?? false;

  static Future<void> openSettings() => _ch.invokeMethod('openSettings');

  static Future<List<Track>> songs() async {
    final list = await _ch.invokeListMethod<Map>('getSongs') ?? const [];
    return list.map(Track.local).toList();
  }

  static Uint8List? cachedArt(String id) => _artCache[id];

  static Future<Uint8List?> art(String id) => _artFutures.putIfAbsent(id, () async {
        try {
          final b = await _ch.invokeMethod<Uint8List>('getArt', {'id': id});
          return _artCache[id] = b;
        } catch (_) {
          return _artCache[id] = null;
        }
      });
}

class Api {
  // Secciones de Inicio ya cargadas (evita volver a pedirlas al hacer scroll).
  static final _sections = <String, Future<List<Track>>>{};

  static Future<List<Track>> section(String? tag) {
    final key = tag ?? '';
    return _sections.putIfAbsent(key, () async {
      try {
        final list = await tracks(tag: tag);
        if (list.isEmpty) _sections.remove(key); // permitir reintentar
        return list;
      } catch (_) {
        _sections.remove(key);
        rethrow;
      }
    });
  }

  // Jamendo a veces responde "success" con 0 resultados de forma
  // intermitente; reintentamos antes de darlo por vacío.
  static Future<List<Track>> tracks(
      {String? search, String? tag, int limit = 20}) async {
    for (var attempt = 0;; attempt++) {
      final list = await _fetch(search: search, tag: tag, limit: limit);
      if (list.isNotEmpty || attempt >= 2) return list;
      await Future.delayed(Duration(milliseconds: 500 * (attempt + 1)));
    }
  }

  static Future<List<Track>> _fetch(
      {String? search, String? tag, required int limit}) async {
    final params = {
      'client_id': kClientId,
      'format': 'json',
      'limit': '$limit',
      'imagesize': '300',
      'audioformat': 'mp32',
      'order': 'popularity_week',
      if (search != null && search.isNotEmpty) 'search': search,
      if (tag != null) 'tags': tag,
    };
    final uri = Uri.https('api.jamendo.com', '/v3.0/tracks/', params);
    final res = await http.get(uri).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw Exception('Error ${res.statusCode}');
    final data = jsonDecode(res.body);
    return (data['results'] as List)
        .map((e) => Track.fromJson(e))
        .where((t) => t.audio.isNotEmpty)
        .toList();
  }
}

// ---------------- Reproductor ----------------

class PlayerController extends ChangeNotifier {
  final player = AudioPlayer();
  List<Track> queue = [];
  int index = -1;

  Track? get current =>
      index >= 0 && index < queue.length ? queue[index] : null;

  PlayerController() {
    player.playerStateStream.listen((_) => notifyListeners());
    // La cola la maneja just_audio (avanza sola y también desde la
    // notificación / pantalla de bloqueo); aquí solo seguimos el índice.
    player.currentIndexStream.listen((i) {
      if (i != null && i != index) {
        index = i;
        notifyListeners();
      }
    });
  }

  static AudioSource _source(Track t) => AudioSource.uri(
        Uri.parse(t.audio),
        tag: MediaItem(
          id: t.audio,
          title: t.name,
          artist: t.artist,
          artUri: t.image.isEmpty ? null : Uri.parse(t.image),
        ),
      );

  Future<void> playList(List<Track> list, int i) async {
    queue = list;
    index = i;
    notifyListeners();
    try {
      await player.setAudioSources(list.map(_source).toList(),
          initialIndex: i);
      player.play();
    } catch (e) {
      debugPrint('Error al reproducir: $e');
    }
  }

  Future<void> next() => player.seekToNext();

  Future<void> prev() async {
    if (player.position.inSeconds > 3 || !player.hasPrevious) {
      await player.seek(Duration.zero);
    } else {
      await player.seekToPrevious();
    }
  }

  void toggle() {
    if (player.playing) {
      player.pause();
    } else {
      // Si la lista terminó, vuelve a empezar la canción actual.
      if (player.processingState == ProcessingState.completed) {
        player.seek(Duration.zero, index: player.currentIndex);
      }
      player.play();
    }
  }
}

final pc = PlayerController();

// ---------------- App ----------------

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Notificación multimedia + controles en pantalla de bloqueo.
  // Debe ejecutarse antes de crear el AudioPlayer (pc se crea al primer uso).
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.vibra.vibra.channel.audio',
    androidNotificationChannelName: 'Reproducción de música',
    androidNotificationOngoing: true,
    androidNotificationIcon: 'drawable/ic_stat_vibra',
  );
  runApp(const MusicApp());
}

class MusicApp extends StatelessWidget {
  const MusicApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Vibra',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true).copyWith(
          scaffoldBackgroundColor: Colors.black,
          colorScheme: ColorScheme.dark(primary: kGreen),
          navigationBarTheme: const NavigationBarThemeData(
            backgroundColor: Colors.black,
            indicatorColor: Colors.white12,
          ),
        ),
        home: const Shell(),
      );
}

Widget _artPlaceholder(double size) => Container(
      width: size,
      height: size,
      color: Colors.grey[850],
      child: Icon(Icons.music_note, size: size * 0.4, color: Colors.white54),
    );

Widget cover(Track t, double size) => ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: t.isLocal
          ? FutureBuilder<Uint8List?>(
              future: LocalMusic.art(t.id),
              initialData: LocalMusic.cachedArt(t.id),
              builder: (_, s) => s.data == null
                  ? _artPlaceholder(size)
                  : Image.memory(s.data!,
                      width: size,
                      height: size,
                      fit: BoxFit.cover,
                      gaplessPlayback: true),
            )
          : CachedNetworkImage(
              imageUrl: t.image,
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorWidget: (_, __, ___) => _artPlaceholder(size),
            ),
    );

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int tab = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: IndexedStack(
            index: tab,
            children: const [HomePage(), SearchPage(), LibraryPage()],
          ),
        ),
        bottomNavigationBar: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const MiniPlayer(),
            NavigationBar(
              selectedIndex: tab,
              onDestinationSelected: (i) => setState(() => tab = i),
              destinations: const [
                NavigationDestination(
                    icon: Icon(Icons.home_outlined),
                    selectedIcon: Icon(Icons.home),
                    label: 'Inicio'),
                NavigationDestination(
                    icon: Icon(Icons.search), label: 'Buscar'),
                NavigationDestination(
                    icon: Icon(Icons.library_music_outlined),
                    selectedIcon: Icon(Icons.library_music),
                    label: 'Mis canciones'),
              ],
            ),
          ],
        ),
      );
}

// ---------------- Inicio ----------------

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.only(top: 16, bottom: 16),
        children: const [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text('¡A escuchar!',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
          ),
          Section(title: 'Populares esta semana'),
          Section(title: 'Reggaetón', tag: 'reggaeton'),
          Section(title: 'Trap', tag: 'trap'),
          Section(title: 'Urbano', tag: 'urban'),
          Section(title: 'Dancehall', tag: 'dancehall'),
          Section(title: 'Rock', tag: 'rock'),
          Section(title: 'Pop', tag: 'pop'),
          Section(title: 'Electrónica', tag: 'electronic'),
          Section(title: 'Hip hop', tag: 'hiphop'),
          Section(title: 'Jazz', tag: 'jazz'),
        ],
      );
}

class Section extends StatefulWidget {
  final String title;
  final String? tag;
  const Section({super.key, required this.title, this.tag});
  @override
  State<Section> createState() => _SectionState();
}

class _SectionState extends State<Section> {
  late Future<List<Track>> future = Api.section(widget.tag);

  void _retry() => setState(() => future = Api.section(widget.tag));

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 10),
          child: Text(widget.title,
              style:
                  const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        ),
        SizedBox(
          height: 190,
          child: FutureBuilder<List<Track>>(
            future: future,
            builder: (c, s) {
              if (s.connectionState != ConnectionState.done) {
                return const Center(
                    child: CircularProgressIndicator(color: kGreen));
              }
              if (s.hasError || s.data == null || s.data!.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('No se pudo cargar',
                          style: TextStyle(color: Colors.grey)),
                      TextButton.icon(
                        onPressed: _retry,
                        icon: const Icon(Icons.refresh, color: kGreen),
                        label: const Text('Reintentar',
                            style: TextStyle(color: kGreen)),
                      ),
                    ],
                  ),
                );
              }
              final list = s.data!;
              return ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: list.length,
                separatorBuilder: (_, __) => const SizedBox(width: 12),
                itemBuilder: (_, i) => GestureDetector(
                  onTap: () => pc.playList(list, i),
                  child: SizedBox(
                    width: 130,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        cover(list[i], 130),
                        const SizedBox(height: 6),
                        Text(list[i].name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                        Text(list[i].artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.grey, fontSize: 12)),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ---------------- Buscar ----------------

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});
  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  Future<List<Track>>? future;

  void search(String q) {
    if (q.trim().isEmpty) return;
    setState(() => future = Api.tracks(search: q.trim(), limit: 30));
  }

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              onSubmitted: search,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: '¿Qué quieres escuchar?',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: Colors.white12,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Expanded(
            child: future == null
                ? const Center(
                    child: Text('Busca canciones, artistas o álbumes'))
                : FutureBuilder<List<Track>>(
                    future: future,
                    builder: (c, s) {
                      if (s.connectionState != ConnectionState.done) {
                        return const Center(
                            child: CircularProgressIndicator(color: kGreen));
                      }
                      if (s.hasError || s.data == null) {
                        return const Center(child: Text('No se pudo buscar'));
                      }
                      final list = s.data!;
                      if (list.isEmpty) {
                        return const Center(child: Text('Sin resultados'));
                      }
                      return ListView.builder(
                        itemCount: list.length,
                        itemBuilder: (_, i) => ListTile(
                          leading: cover(list[i], 50),
                          title: Text(list[i].name,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(list[i].artist,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          onTap: () => pc.playList(list, i),
                        ),
                      );
                    },
                  ),
          ),
        ],
      );
}

// ---------------- Mis canciones (música del celular) ----------------

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});
  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage>
    with WidgetsBindingObserver {
  bool? granted; // null = comprobando
  bool asked = false;
  List<Track>? songs;
  String? error;
  String filter = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check(); // no pide permiso al abrir la app; solo comprueba
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Al volver de Ajustes, vuelve a comprobar el permiso.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && granted != true) _check();
  }

  Future<void> _check() async {
    final ok = await LocalMusic.hasPermission();
    if (!mounted) return;
    setState(() => granted = ok);
    if (ok && songs == null) _load();
  }

  Future<void> _ask() async {
    final ok = await LocalMusic.requestPermission();
    if (!mounted) return;
    setState(() {
      granted = ok;
      asked = true;
    });
    if (ok) _load();
  }

  Future<void> _load() async {
    try {
      final s = await LocalMusic.songs();
      if (mounted) {
        setState(() {
          songs = s;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Widget _message(IconData icon, String text, List<Widget> actions) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 64, color: Colors.white38),
              const SizedBox(height: 16),
              Text(text,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 16)),
              const SizedBox(height: 20),
              ...actions,
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (granted == null) {
      return const Center(child: CircularProgressIndicator(color: kGreen));
    }
    if (granted == false) {
      return _message(
        Icons.library_music,
        'Escucha la música que tienes guardada en tu celular',
        [
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: kGreen, foregroundColor: Colors.black),
            onPressed: _ask,
            child: const Text('Permitir acceso a mi música'),
          ),
          if (asked)
            TextButton(
              onPressed: LocalMusic.openSettings,
              child: const Text('Abrir ajustes de la app'),
            ),
        ],
      );
    }
    if (error != null) {
      return _message(Icons.error_outline, 'No se pudo leer tu música',
          [TextButton(onPressed: _load, child: const Text('Reintentar'))]);
    }
    final all = songs;
    if (all == null) {
      return const Center(child: CircularProgressIndicator(color: kGreen));
    }
    if (all.isEmpty) {
      return _message(Icons.music_off, 'No encontramos canciones en tu celular',
          [TextButton(onPressed: _load, child: const Text('Buscar de nuevo'))]);
    }

    final q = filter.toLowerCase();
    final list = q.isEmpty
        ? all
        : all
            .where((t) =>
                t.name.toLowerCase().contains(q) ||
                t.artist.toLowerCase().contains(q))
            .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Mis canciones',
                        style: TextStyle(
                            fontSize: 26, fontWeight: FontWeight.bold)),
                    Text('${all.length} canciones',
                        style: const TextStyle(color: Colors.grey)),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Aleatorio',
                icon: const Icon(Icons.shuffle),
                onPressed: () => pc.playList([...list]..shuffle(), 0),
              ),
              IconButton.filled(
                tooltip: 'Reproducir todo',
                style: IconButton.styleFrom(
                    backgroundColor: kGreen, foregroundColor: Colors.black),
                icon: const Icon(Icons.play_arrow),
                onPressed: () => pc.playList(list, 0),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: TextField(
            onChanged: (v) => setState(() => filter = v.trim()),
            decoration: InputDecoration(
              hintText: 'Filtrar por canción o artista',
              prefixIcon: const Icon(Icons.filter_list),
              isDense: true,
              filled: true,
              fillColor: Colors.white12,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            color: kGreen,
            onRefresh: _load,
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: list.length,
              itemBuilder: (_, i) => ListTile(
                leading: cover(list[i], 50),
                title: Text(list[i].name,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(list[i].artist,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: () => pc.playList(list, i),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------- Mini player ----------------

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: pc,
        builder: (context, _) {
          final t = pc.current;
          if (t == null) return const SizedBox.shrink();
          return GestureDetector(
            onTap: () => showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              useSafeArea: true,
              backgroundColor: const Color(0xFF181818),
              builder: (_) => const FullPlayer(),
            ),
            child: Container(
              margin: const EdgeInsets.fromLTRB(8, 0, 8, 4),
              decoration: BoxDecoration(
                color: const Color(0xFF2A2A2A),
                borderRadius: BorderRadius.circular(8),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  ListTile(
                    dense: true,
                    leading: cover(t, 44),
                    title: Text(t.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(t.artist,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: IconButton(
                      icon: Icon(
                          pc.player.playing ? Icons.pause : Icons.play_arrow),
                      onPressed: pc.toggle,
                    ),
                  ),
                  StreamBuilder<Duration>(
                    stream: pc.player.positionStream,
                    builder: (_, s) {
                      final total = pc.player.duration?.inMilliseconds ?? 1;
                      final pos = s.data?.inMilliseconds ?? 0;
                      return LinearProgressIndicator(
                        value: (pos / total).clamp(0.0, 1.0),
                        minHeight: 2,
                        color: Colors.white,
                        backgroundColor: Colors.white24,
                      );
                    },
                  ),
                ],
              ),
            ),
          );
        },
      );
}

// ---------------- Reproductor completo ----------------

class FullPlayer extends StatelessWidget {
  const FullPlayer({super.key});

  String fmt(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: pc,
        builder: (context, _) {
          final t = pc.current;
          if (t == null) return const SizedBox.shrink();
          final side = (MediaQuery.of(context).size.width - 48).clamp(0.0, 320.0);
          return SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(
                    icon: const Icon(Icons.keyboard_arrow_down, size: 32),
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
                const SizedBox(height: 12),
                cover(t, side),
                const SizedBox(height: 24),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(t.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 22, fontWeight: FontWeight.bold)),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(t.artist,
                      style: const TextStyle(color: Colors.grey)),
                ),
                const SizedBox(height: 8),
                StreamBuilder<Duration>(
                  stream: pc.player.positionStream,
                  builder: (_, s) {
                    final total = pc.player.duration ?? Duration.zero;
                    final pos = s.data ?? Duration.zero;
                    final max = total.inMilliseconds;
                    return Column(
                      children: [
                        Slider(
                          value: pos.inMilliseconds.clamp(0, max).toDouble(),
                          max: max > 0 ? max.toDouble() : 1,
                          activeColor: Colors.white,
                          onChanged: (v) =>
                              pc.player.seek(Duration(milliseconds: v.toInt())),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [Text(fmt(pos)), Text(fmt(total))],
                        ),
                      ],
                    );
                  },
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                        iconSize: 40,
                        icon: const Icon(Icons.skip_previous),
                        onPressed: pc.prev),
                    IconButton(
                      iconSize: 72,
                      color: Colors.white,
                      icon: Icon(pc.player.playing
                          ? Icons.pause_circle_filled
                          : Icons.play_circle_fill),
                      onPressed: pc.toggle,
                    ),
                    IconButton(
                        iconSize: 40,
                        icon: const Icon(Icons.skip_next),
                        onPressed: pc.next),
                  ],
                ),
              ],
            ),
          );
        },
      );
}
